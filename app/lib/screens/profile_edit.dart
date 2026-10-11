library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../state/session.dart';
import '../widgets/dimi_avatar.dart';
import '../theme.dart';
import '../api/config.dart';
import '../widgets/common/dimi_button.dart';
import '../widgets/common/dimi_section.dart';

class ProfileEditScreen extends StatefulWidget {
  const ProfileEditScreen({super.key});

  @override
  State<ProfileEditScreen> createState() => _ProfileEditScreenState();
}

class _ProfileEditScreenState extends State<ProfileEditScreen> {
  final _nicknameCtrl = TextEditingController();
  final _birthYearCtrl = TextEditingController();
  final _signatureCtrl = TextEditingController();
  final _picker = ImagePicker();

  int _gender = 0;
  bool _saving = false;
  bool _uploadingAvatar = false;
  bool _uploadingCover = false;

  /// 本次会话内新换上的头像 url（保存时一并提交）
  String? _avatarUrl;
  String? _momentCover;
  bool get _busy => _saving || _uploadingAvatar || _uploadingCover;

  static const _allowedExts = {'jpg', 'jpeg', 'png', 'webp'};

  @override
  void initState() {
    super.initState();
    final me = context.read<Session>().currentUser;
    _nicknameCtrl.text = me?.nickname ?? '';
    _birthYearCtrl.text = me?.birthYear?.toString() ?? '';
    _signatureCtrl.text = me?.signature ?? '';
    _gender = me?.gender ?? 0;
  }

  @override
  void dispose() {
    _nicknameCtrl.dispose();
    _birthYearCtrl.dispose();
    _signatureCtrl.dispose();
    super.dispose();
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// 封面缺省兜底：雾杏渐变块（与服务端 moment_cover 为空时的相册页一致）
  Widget _coverFallback() {
    return Container(
      decoration: const BoxDecoration(
        color: kDimiApricotSoft,
      ),
      child: const Center(
        child:
            Icon(Icons.landscape_outlined, size: 20, color: kDimiApricotDeep),
      ),
    );
  }

  Future<void> _pickImage({required bool cover}) async {
    if (_busy) return;
    setState(() {
      if (cover) {
        _uploadingCover = true;
      } else {
        _uploadingAvatar = true;
      }
    });
    try {
      final file = await _picker.pickImage(
          source: ImageSource.gallery,
          maxWidth: cover ? 1920 : 1080,
          maxHeight: cover ? 1920 : 1080,
          imageQuality: 85);
      if (file == null || !mounted) return;
      final ext = file.name.contains('.')
          ? file.name.split('.').last.toLowerCase()
          : 'jpg';
      if (!_allowedExts.contains(ext)) {
        _toast('请选择 JPG、PNG 或 WebP 图片');
        return;
      }
      final bytes = await file.readAsBytes();
      if (!mounted) return;
      if (bytes.length > 2 * 1024 * 1024) {
        _toast('图片超过 2MB，请换一张');
        return;
      }
      final result = await context
          .read<DimiApi>()
          .uploadImage(cover ? 'moment' : 'avatar', bytes, ext);
      if (!mounted) return;
      setState(() {
        if (cover) {
          _momentCover = result['url'];
        } else {
          _avatarUrl = result['url'];
        }
      });
    } on ApiException catch (e) {
      _toast(e.message);
    } on Exception {
      _toast('图片选取失败，请重试');
    } finally {
      if (mounted) {
        setState(() {
          _uploadingAvatar = false;
          _uploadingCover = false;
        });
      }
    }
  }

  Future<void> _save() async {
    if (_busy) return;
    final nickname = _nicknameCtrl.text.trim();
    if (nickname.isEmpty) {
      _toast('昵称不能为空');
      return;
    }
    final birthYearText = _birthYearCtrl.text.trim();
    final birthYear =
        birthYearText.isEmpty ? null : int.tryParse(birthYearText);
    if (birthYearText.isNotEmpty &&
        (birthYear == null ||
            birthYear < 1900 ||
            birthYear > DateTime.now().year)) {
      _toast('出生年份格式不正确');
      return;
    }
    if (birthYear != null && DateTime.now().year - birthYear < 18) {
      _toast('暂不支持未满 18 周岁的用户');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() => _saving = true);
    try {
      final api = context.read<DimiApi>();
      await api.updateMe(
        nickname: nickname,
        gender: _gender,
        birthYear: birthYear,
        clearBirthYear: birthYearText.isEmpty,
        momentCover: _momentCover,
        signature: _signatureCtrl.text.trim(),
        avatarUrl: _avatarUrl,
      );
      if (!mounted) return;
      // 刷新 Session 当前用户
      final fresh = await api.me();
      if (!mounted) return;
      await context.read<Session>().updateCurrentUser(fresh);
      if (!mounted) return;
      _toast('资料已保存');
      Navigator.of(context).pop();
    } on ApiException catch (e) {
      _toast(e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = context.watch<Session>().currentUser;
    final cover = _momentCover ?? me?.momentCover;
    return Scaffold(
      appBar: AppBar(title: const Text('编辑资料'), actions: [
        IconButton(
            tooltip: '资料说明',
            icon: const Icon(Icons.info_outline),
            onPressed: () => showDialog<void>(
                context: context,
                builder: (ctx) => AlertDialog(
                      title: const Text('资料说明'),
                      content: Text(
                          '真名：${me?.realName ?? '未设置'}\n真名的可见范围可在隐私设置中调整。\n\n头像、封面和资料在保存后一起生效。'),
                      actions: [
                        TextButton(
                            onPressed: () => Navigator.pop(ctx),
                            child: const Text('知道了'))
                      ],
                    ))),
      ]),
      body: ListView(
          padding: const EdgeInsets.all(16),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          children: [
            DimiSection(margin: EdgeInsets.zero, dividerIndent: 16, children: [
              ListTile(
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  title: const Text('头像'),
                  trailing: _uploadingAvatar
                      ? const SizedBox(
                          width: 32,
                          height: 32,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : DimiAvatar(
                          name: me?.nickname,
                          avatarUrl: _avatarUrl ?? me?.avatarUrl,
                          size: 48,
                          seed: me?.userId),
                  onTap: _busy ? null : () => _pickImage(cover: false)),
              ListTile(
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  title: const Text('朋友圈封面'),
                  trailing: _uploadingCover
                      ? const SizedBox(
                          width: 32,
                          height: 32,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: SizedBox(
                              width: 72,
                              height: 44,
                              child: cover == null
                                  ? _coverFallback()
                                  : Image.network(
                                      ApiConfig.resolveMediaUrl(cover),
                                      fit: BoxFit.cover,
                                      errorBuilder: (_, __, ___) =>
                                          _coverFallback()))),
                  onTap: _busy ? null : () => _pickImage(cover: true)),
            ]),
            const SizedBox(height: 16),
            Card(
                margin: EdgeInsets.zero,
                child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(children: [
                      TextField(
                          controller: _nicknameCtrl,
                          enabled: !_saving,
                          maxLength: 32,
                          decoration: const InputDecoration(
                              labelText: '昵称', counterText: '')),
                      const SizedBox(height: 16),
                      DropdownButtonFormField<int>(
                          initialValue: _gender,
                          decoration: const InputDecoration(labelText: '性别'),
                          items: const [
                            DropdownMenuItem(value: 0, child: Text('未设置')),
                            DropdownMenuItem(value: 1, child: Text('男')),
                            DropdownMenuItem(value: 2, child: Text('女'))
                          ],
                          onChanged: _saving
                              ? null
                              : (value) =>
                                  setState(() => _gender = value ?? 0)),
                      const SizedBox(height: 16),
                      TextField(
                          controller: _birthYearCtrl,
                          enabled: !_saving,
                          maxLength: 4,
                          keyboardType: TextInputType.number,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly
                          ],
                          decoration: const InputDecoration(
                              labelText: '出生年份',
                              hintText: '选填',
                              counterText: '')),
                      const SizedBox(height: 16),
                      TextField(
                          controller: _signatureCtrl,
                          enabled: !_saving,
                          maxLength: 60,
                          minLines: 2,
                          maxLines: 3,
                          decoration: const InputDecoration(
                              labelText: '签名',
                              hintText: '一句话介绍自己',
                              counterText: '')),
                    ]))),
            const SizedBox(height: 24),
            DimiButton(
                label: '保存',
                loading: _saving,
                expanded: true,
                onPressed: _busy ? null : _save),
            const SizedBox(height: 16),
          ]),
    );
  }
}
