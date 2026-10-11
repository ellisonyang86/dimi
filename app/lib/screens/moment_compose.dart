/// 发布动态：多行文字（≤2000 字）+ 可选图片九宫格（≤9 张，单张 ≤2MB）+ 可见范围六档。
/// textOnly=true 时为纯文字模式（朋友圈长按相机进入），不显示图片选择区。
/// partial / excluded 本期占位：点击提示「V1.1 开放」，不可选中提交。
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../theme.dart';
import '../widgets/article_reader.dart';

class MomentComposeScreen extends StatefulWidget {
  const MomentComposeScreen(
      {super.key, this.textOnly = false, this.articleMode = false});

  /// 纯文字模式：隐藏图片九宫格（对齐微信长按相机发文字）
  final bool textOnly;
  final bool articleMode;

  @override
  State<MomentComposeScreen> createState() => _MomentComposeScreenState();
}

class _MomentComposeScreenState extends State<MomentComposeScreen> {
  final _ctrl = TextEditingController();
  final _titleCtrl = TextEditingController();
  late bool _articleMode;

  @override
  void initState() {
    super.initState();
    _articleMode = widget.articleMode;
  }

  final _picker = ImagePicker();
  String _visibility = 'public';
  bool _submitting = false;

  /// 上传进度提示文案（非空时替换发布按钮文字）
  String? _progressText;

  /// 已选图片字节与扩展名（并行数组，按下标对应）
  final List<Uint8List> _images = [];
  final List<String> _exts = [];

  static const _maxImages = 9;
  static const _maxBytes = 2 * 1024 * 1024;
  static const _allowedExts = {'jpg', 'jpeg', 'png', 'webp'};

  static const _visibilityOptions = {
    'public': ('公开', '好友可见，并同步到同学圈/老乡圈'),
    'private': ('私密', '仅自己可见'),
    'partial': ('部分可见', '按好友标签选人可见'),
    'excluded': ('不给谁看', '按好友标签排除'),
    'classmates': ('同学圈', '同校同届的同学可见，无需互为好友'),
    'fellows': ('老乡圈', '家乡同市的老乡可见，无需互为好友'),
  };

  /// 本期占位档：依赖好友标签配置，V1.1 开放
  static const _pendingLevels = {'partial', 'excluded'};

  @override
  void dispose() {
    _ctrl.dispose();
    _titleCtrl.dispose();
    super.dispose();
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _pickVisibility() async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: _visibilityOptions.entries
              .map(
                (e) => ListTile(
                  title: Text(e.value.$1),
                  subtitle:
                      Text(e.value.$2, style: const TextStyle(fontSize: 14)),
                  trailing: _visibility == e.key
                      ? const Icon(Icons.check, size: 18, color: kDimiPrimary)
                      : null,
                  onTap: () {
                    if (_pendingLevels.contains(e.key)) {
                      Navigator.pop(ctx);
                      _toast('「${e.value.$1}」需先配置好友标签，V1.1 开放');
                      return;
                    }
                    Navigator.pop(ctx, e.key);
                  },
                ),
              )
              .toList(),
        ),
      ),
    );
    if (!mounted) return;
    if (picked != null) setState(() => _visibility = picked);
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
      _ctrl.text = removeArticleImage(_ctrl.text, index);
      _images.removeAt(index);
      _exts.removeAt(index);
    });
  }

  Future<void> _publish() async {
    if (_submitting) return;
    final text = _ctrl.text.trim();
    if (_articleMode && _titleCtrl.text.trim().isEmpty) {
      _toast('给文章起个标题吧');
      return;
    }
    final content =
        _articleMode ? '# ${_titleCtrl.text.trim()}\n\n$text' : text;
    if (content.runes.length > (_articleMode ? 20000 : 2000)) {
      _toast(_articleMode ? '标题与正文合计不超过 20000 字' : '普通动态不超过 2000 字，可切换长文模式');
      return;
    }
    final hasImages = _images.isNotEmpty;
    if (!hasImages && text.isEmpty) {
      _toast('写点什么吧');
      return;
    }
    if (_pendingLevels.contains(_visibility)) return;
    setState(() => _submitting = true);
    try {
      final api = context.read<DimiApi>();
      if (hasImages) {
        // 先逐张上传，收集 url 后再发图文动态
        final urls = <String>[];
        for (var i = 0; i < _images.length; i++) {
          if (mounted) {
            setState(() => _progressText = '上传中 ${i + 1}/${_images.length}');
          }
          urls.add(await api.uploadMomentImage(_images[i], _exts[i]));
        }
        if (mounted) setState(() => _progressText = null);
        await api.publishMoment(
          content: content.isEmpty ? null : content,
          contentType: _articleMode ? 'article' : 'image',
          mediaIds: urls,
          visibility: _visibility,
        );
      } else {
        await api.publishMoment(
            content: content,
            visibility: _visibility,
            contentType: _articleMode ? 'article' : 'text');
      }
      if (!mounted) return;
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
    final option = _visibilityOptions[_visibility]!;
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: Text(_articleMode ? '写文章' : '发动态'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(
              onPressed: _submitting ? null : _publish,
              style: FilledButton.styleFrom(
                backgroundColor: kDimiPrimaryFill,
                foregroundColor: kDimiPrimary,
                minimumSize: Size.zero,
                padding:
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
              ),
              child: Text(_progressText ?? (_submitting ? '发布中…' : '发布')),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('长文模式'),
                    subtitle: const Text('标题、分段和图文排版'),
                    value: _articleMode,
                    onChanged: _submitting
                        ? null
                        : (value) => setState(() => _articleMode = value),
                  ),
                  if (_articleMode) ...[
                    TextField(
                        controller: _titleCtrl,
                        maxLength: 60,
                        readOnly: _submitting,
                        style: const TextStyle(
                            fontSize: 24, fontWeight: FontWeight.w600),
                        decoration: const InputDecoration(hintText: '文章标题')),
                    ArticleToolbar(
                        controller: _ctrl,
                        imageCount: _images.length,
                        enabled: !_submitting,
                        onPreview: () => showArticlePreview(context,
                            title: _titleCtrl.text,
                            body: _ctrl.text,
                            images: _images)),
                  ],
                  TextField(
                    controller: _ctrl,
                    readOnly: _submitting,
                    style: const TextStyle(fontSize: 18, height: 1.8),
                    maxLines: null,
                    minLines: 6,
                    maxLength: _articleMode ? 20000 : 2000,
                    textAlignVertical: TextAlignVertical.top,
                    decoration: InputDecoration(
                      hintText: widget.textOnly
                          ? '记录此刻，找回走散的人也在看你…'
                          : '这一刻的想法…（可配图片）',
                      border: InputBorder.none,
                    ),
                  ),
                  if (!widget.textOnly || _articleMode) _imageGrid(),
                ],
              ),
            ),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.visibility_outlined, color: kDimiPrimary),
            title: const Text('谁可以看', style: TextStyle(fontSize: 17)),
            subtitle: Text('${option.$1} · ${option.$2} · 发布后不可修改',
                style: const TextStyle(fontSize: 14)),
            trailing: const Icon(Icons.chevron_right, color: kDimiGrayCC),
            onTap: _pickVisibility,
          ),
          const SafeArea(child: SizedBox(height: 4)),
        ],
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
              child: const Icon(Icons.add, size: 36, color: kDimiGrayBB),
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
            Positioned(
              top: 0,
              right: 0,
              // 视觉 20dp，热区 48dp（适老化触控规范）
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _submitting ? null : () => _removeImage(i),
                child: const SizedBox(
                  width: 48,
                  height: 48,
                  child: Align(
                    alignment: Alignment.topRight,
                    child: Padding(
                      padding: EdgeInsets.all(2),
                      child: CircleAvatar(
                        radius: 10,
                        backgroundColor: kDimiImageMask,
                        child: Icon(Icons.close, size: 14, color: Colors.white),
                      ),
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
