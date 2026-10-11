/// 家乡页投稿流（M1，对齐《家乡页与共建体系设计_V1》§11.2）：
/// 相册选图（≤9，单张 ≤2MB，复用朋友圈上传通道 scene=moment）
/// → 分类四选（风光/特产/手艺/故事）→ 标题（≤60 字）+ 说明（≤20000 字，
/// 按分类给模板引导语 placeholder）→ 原创承诺勾选（必勾）→ 提交。
/// 全程无价格、无联系方式输入框；45001 内容拦截直接 toast 服务端文案。
/// 图片允许 0 张（产品确认项：故事类可无图投稿），media 传空数组，保持现状不改。
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../theme.dart';
import '../widgets/article_reader.dart';
import '../widgets/common/dimi_button.dart';

class HometownComposeScreen extends StatefulWidget {
  const HometownComposeScreen({
    super.key,
    required this.regionCode,
    this.townName = '',
  });

  /// 投稿归属镇（服务端按本人籍贯校验资格）
  final String regionCode;

  /// 镇名（标题栏展示用）
  final String townName;

  @override
  State<HometownComposeScreen> createState() => _HometownComposeScreenState();
}

class _HometownComposeScreenState extends State<HometownComposeScreen> {
  final _titleCtrl = TextEditingController();
  final _bodyCtrl = TextEditingController();
  final _picker = ImagePicker();

  String _category = 'scenery';
  bool _agreedOriginal = false;
  bool _submitting = false;

  /// 上传进度提示文案（非空时替换提交按钮文字）
  String? _progressText;

  /// 已选图片字节与扩展名（并行数组，按下标对应）
  final List<Uint8List> _images = [];
  final List<String> _exts = [];

  static const _maxImages = 9;
  static const _maxBytes = 2 * 1024 * 1024;
  static const _allowedExts = {'jpg', 'jpeg', 'png', 'webp'};

  /// 分类四选：图标 + 文案 + 说明模板引导语（特产=产地/工艺/吃法故事；风光=位置/最佳时节）
  static const _categories = <String, (IconData, String, String)>{
    'scenery': (
      Icons.landscape_outlined,
      '风光',
      '写写位置和最佳时节，比如：村口的古槐，清晨雾起时最美…',
    ),
    'product': (
      Icons.storefront_outlined,
      '特产',
      '写写产地、工艺和吃法故事，比如：镇上老作坊的红薯粉条，霜降后开工…',
    ),
    'craft': (
      Icons.handyman_outlined,
      '手艺',
      '写写手艺人和工序，比如：王师傅编竹器四十年，一把椅子要劈篾三天…',
    ),
    'story': (
      Icons.auto_stories_outlined,
      '故事',
      '写写家乡的人和事，比如：九十年代镇上赶集，最热闹的是腊月初八…',
    ),
  };

  @override
  void dispose() {
    _titleCtrl.dispose();
    _bodyCtrl.dispose();
    super.dispose();
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// 追加多选图片：总上限 9 张，单张 ≤2MB，格式 jpg/jpeg/png/webp。
  /// 选图即压缩（1920×1920 / q85）：客户端压缩兜底 2MB 上限，
  /// 压缩后 1080p JPEG q85 约 300-600KB，原图再大的情况已极少触发 2MB 拦截。
  Future<void> _pickImages() async {
    final remain = _maxImages - _images.length;
    if (remain <= 0) {
      _toast('最多 9 张图片');
      return;
    }
    final List<XFile> picked;
    try {
      picked = await _picker.pickMultiImage(
        maxWidth: 1920,
        maxHeight: 1920,
        imageQuality: 85,
      );
    } on Exception {
      _toast('无法访问相册');
      return;
    }
    if (picked.isEmpty) return;
    var overflow = false;
    for (final f in picked) {
      if (_images.length >= _maxImages) {
        overflow = true;
        break;
      }
      final ext =
          f.name.contains('.') ? f.name.split('.').last.toLowerCase() : 'jpg';
      if (!_allowedExts.contains(ext)) {
        _toast('仅支持 jpg / jpeg / png / webp 图片');
        continue;
      }
      final Uint8List bytes;
      try {
        bytes = await f.readAsBytes();
      } on Exception {
        _toast('「${f.name}」读取失败，已跳过');
        continue;
      }
      if (bytes.length > _maxBytes) {
        _toast('「${f.name}」超过 2MB，已跳过');
        continue;
      }
      _images.add(bytes);
      _exts.add(ext);
    }
    if (overflow) _toast('最多 9 张图片');
    if (mounted) setState(() {});
  }

  void _removeImage(int index) {
    setState(() {
      _bodyCtrl.text = removeArticleImage(_bodyCtrl.text, index);
      _images.removeAt(index);
      _exts.removeAt(index);
    });
  }

  /// 提交：未勾原创承诺禁用；先逐张上传收 url 再投稿
  Future<void> _submit() async {
    final title = _titleCtrl.text.trim();
    final body = _bodyCtrl.text.trim();
    if (title.isEmpty) {
      _toast('给内容起个标题吧');
      return;
    }
    if (title.runes.length > 60 || body.runes.length > 20000) {
      _toast('标题最多 60 字，正文最多 20000 字');
      return;
    }
    if (!_agreedOriginal || _submitting) return;
    setState(() => _submitting = true);
    try {
      final api = context.read<DimiApi>();
      // 先逐张上传，收集 url 后再投稿
      final urls = <String>[];
      for (var i = 0; i < _images.length; i++) {
        // 页面退出即中止上传，不再发出后续请求
        if (!mounted) return;
        setState(() => _progressText = '上传中 ${i + 1}/${_images.length}');
        urls.add(await api.uploadMomentImage(_images[i], _exts[i]));
      }
      // 页面退出不发出投稿
      if (!mounted) return;
      setState(() => _progressText = null);
      await api.createHometownContent(
        regionCode: widget.regionCode,
        category: _category,
        title: title,
        body: body.isEmpty ? null : body,
        media: urls,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已通过初审，同乡可在最新区看到')));
      Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      _toast(e.message);
    } finally {
      if (mounted) {
        setState(() {
          _submitting = false;
          _progressText = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
          title: Text(
              widget.townName.isEmpty ? '分享家乡' : '分享 · ${widget.townName}')),
      body: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _imageGrid(),
                  const SizedBox(height: 16),
                  const Text('选个分类',
                      style:
                          TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  _categoryGrid(),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _titleCtrl,
                    style: const TextStyle(
                        fontSize: 20, fontWeight: FontWeight.w600),
                    maxLength: 60,
                    decoration: const InputDecoration(
                      hintText: '写个标题',
                      counterText: '',
                    ),
                  ),
                  const SizedBox(height: 4),
                  ArticleToolbar(
                      controller: _bodyCtrl,
                      imageCount: _images.length,
                      enabled: !_submitting,
                      onPreview: () => showArticlePreview(context,
                          title: _titleCtrl.text,
                          body: _bodyCtrl.text,
                          images: _images)),
                  TextField(
                    controller: _bodyCtrl,
                    readOnly: _submitting,
                    style: const TextStyle(fontSize: 18, height: 1.7),
                    maxLines: null,
                    minLines: 5,
                    maxLength: 20000,
                    textAlignVertical: TextAlignVertical.top,
                    decoration: InputDecoration(
                      hintText: _categories[_category]!.$3,
                    ),
                  ),
                  const SizedBox(height: 8),
                  _originalPromise(),
                ],
              ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
              child: DimiButton(
                label: _progressText ?? '提交',
                onPressed: _agreedOriginal ? _submit : null,
                loading: _submitting,
                expanded: true,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 分类四宫格：图标 + 文案，选中态雾杏浅底描边（触控区 ≥48dp）
  Widget _categoryGrid() {
    return Row(
      children: _categories.entries.map((e) {
        final selected = e.key == _category;
        return Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Material(
              color: selected ? kDimiApricotSoft : kDimiBg,
              borderRadius: BorderRadius.circular(kDimiRadiusCard),
              child: InkWell(
                borderRadius: BorderRadius.circular(kDimiRadiusCard),
                onTap: () => setState(() => _category = e.key),
                child: Container(
                  height: 72,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(kDimiRadiusCard),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(e.value.$1,
                          size: 24,
                          color: selected ? kDimiApricotDeep : kDimiGray66),
                      const SizedBox(height: 4),
                      Text(
                        e.value.$2,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight:
                              selected ? FontWeight.w600 : FontWeight.w400,
                          color: selected ? kDimiApricotDeep : kDimiGray66,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  /// 原创承诺勾选（必勾，不勾禁用提交）
  Widget _originalPromise() {
    return InkWell(
      borderRadius: BorderRadius.circular(kDimiRadiusInput),
      onTap: () => setState(() => _agreedOriginal = !_agreedOriginal),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizedBox(
              width: 48,
              height: 48,
              child: Checkbox(
                value: _agreedOriginal,
                activeColor: kDimiPrimary,
                onChanged: (v) => setState(() => _agreedOriginal = v ?? false),
              ),
            ),
            const Expanded(
              child: Text(
                '我承诺上传的是原创或已获授权的图片，内容不含价格、联系方式与交易信息',
                style: TextStyle(fontSize: 15, color: kDimiGray66, height: 1.5),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 图片九宫格：已选缩略图（右上角删除）+ 末尾「+」添加格（未满 9 张时）
  Widget _imageGrid() {
    final count = _images.length + (_images.length < _maxImages ? 1 : 0);
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 6,
        crossAxisSpacing: 6,
      ),
      itemCount: count,
      itemBuilder: (ctx, i) {
        if (i >= _images.length) {
          // 「+」添加格
          return GestureDetector(
            onTap: _submitting ? null : _pickImages,
            child: Container(
              decoration: BoxDecoration(
                color: kDimiBg,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: kDimiGrayCC),
              ),
              child: const Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.add_photo_alternate_outlined,
                      size: 32, color: kDimiGrayBB),
                  SizedBox(height: 4),
                  Text('家乡的图',
                      style: TextStyle(fontSize: 14, color: kDimiGrayBB)),
                ],
              ),
            ),
          );
        }
        return Stack(
          fit: StackFit.expand,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child:
                  Image.memory(_images[i], fit: BoxFit.cover, cacheWidth: 400),
            ),
            // 删除钮：视觉 24dp，触控热区扩到 48dp（中老年友好触达区）
            Positioned(
              top: 0,
              right: 0,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _submitting ? null : () => _removeImage(i),
                child: SizedBox(
                  width: 48,
                  height: 48,
                  child: Center(
                    child: Container(
                      width: 24,
                      height: 24,
                      decoration: const BoxDecoration(
                        color: kDimiImageMask,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.close,
                          size: 14, color: Colors.white),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
