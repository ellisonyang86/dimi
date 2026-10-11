/// 二维码使用稳定的 userId；DIMI 号用于不公开手机号的精确找人。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../api/client.dart';
import '../api/models.dart';
import '../state/session.dart';
import '../theme.dart';
import '../widgets/dimi_avatar.dart';
import '../widgets/common/dimi_dialog.dart';
import 'scan.dart';

class MyQrcodeScreen extends StatelessWidget {
  const MyQrcodeScreen({super.key});

  Future<void> _edit(BuildContext context, UserSelf me) async {
    final session = context.read<Session>();
    final updated = await showDimiDialog<UserSelf>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _DimiNoDialog(api: context.read<DimiApi>(), me: me));
    if (updated != null) await session.updateCurrentUser(updated);
  }

  @override
  Widget build(BuildContext context) {
    final me = context.watch<Session>().currentUser;
    return Scaffold(
      appBar: AppBar(title: const Text('我的二维码')),
      body: SafeArea(
          child: Center(
              child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Card(
                    margin: EdgeInsets.zero,
                    child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(children: [
                          DimiAvatar(
                              name: me?.nickname,
                              avatarUrl: me?.avatarUrl,
                              seed: me?.userId,
                              size: 56),
                          const SizedBox(height: 12),
                          Text(me?.nickname ?? '未登录',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                  fontSize: 20, fontWeight: FontWeight.w600)),
                          const SizedBox(height: 20),
                          if (me != null)
                            LayoutBuilder(
                                builder: (_, constraints) => QrImageView(
                                    data: 'dimi://u/${me.userId}',
                                    size: constraints.maxWidth
                                        .clamp(0, 220)
                                        .toDouble(),
                                    backgroundColor: Colors.white,
                                    eyeStyle: const QrEyeStyle(
                                        eyeShape: QrEyeShape.square,
                                        color: kDimiText),
                                    dataModuleStyle: const QrDataModuleStyle(
                                        dataModuleShape:
                                            QrDataModuleShape.square,
                                        color: kDimiText))),
                          const SizedBox(height: 12),
                          const Text('扫一扫，加我好友',
                              style:
                                  TextStyle(fontSize: 16, color: kDimiGray99)),
                          if (me?.dimiNo != null) ...[
                            const SizedBox(height: 20),
                            const Divider(),
                            const SizedBox(height: 8),
                            const Text('DIMI 号',
                                style: TextStyle(
                                    fontSize: 15, color: kDimiGray99)),
                            SelectableText(me!.dimiNo!,
                                textAlign: TextAlign.center,
                                style: const TextStyle(fontSize: 19)),
                            Wrap(
                                alignment: WrapAlignment.center,
                                spacing: 12,
                                children: [
                                  TextButton(
                                      onPressed: () => _edit(context, me),
                                      child: Text(me.dimiNoChangedAt == null
                                          ? '设置 DIMI 号'
                                          : '修改 DIMI 号')),
                                  TextButton(
                                      onPressed: () async {
                                        await Clipboard.setData(
                                            ClipboardData(text: me.dimiNo!));
                                        if (context.mounted) {
                                          ScaffoldMessenger.of(context)
                                              .showSnackBar(const SnackBar(
                                                  content: Text('DIMI 号已复制')));
                                        }
                                      },
                                      child: const Text('复制')),
                                ]),
                          ],
                        ]))),
                const SizedBox(height: 24),
                OutlinedButton.icon(
                    icon: const Icon(Icons.qr_code_scanner, size: 20),
                    label: const Text('扫一扫'),
                    onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                            builder: (_) => const ScanScreen()))),
              ],
            )),
      ))),
    );
  }
}

class _DimiNoDialog extends StatefulWidget {
  const _DimiNoDialog({required this.api, required this.me});
  final DimiApi api;
  final UserSelf me;
  @override
  State<_DimiNoDialog> createState() => _DimiNoDialogState();
}

class _DimiNoDialogState extends State<_DimiNoDialog> {
  late final _ctrl = TextEditingController(
      text: widget.me.dimiNoChangedAt == null ? '' : widget.me.dimiNo);
  bool _saving = false;
  String? _error;
  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    final value = _ctrl.text.trim().toLowerCase();
    if (!RegExp(r'^[a-z][a-z0-9_-]{5,19}$').hasMatch(value) ||
        RegExp(r'^dm\d+$').hasMatch(value)) {
      setState(() => _error = '请填写 6–20 位字母开头的自定义号，DM 纯数字号为系统保留');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final me = await widget.api.updateDimiNo(value);
      if (mounted) Navigator.of(context).pop(me);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final changed = DateTime.tryParse(widget.me.dimiNoChangedAt ?? '');
    final next = changed?.add(const Duration(days: 365)).toLocal();
    final canEdit = next == null || !DateTime.now().isBefore(next);
    return PopScope(
        canPop: !_saving,
        child: AlertDialog(
          title: Text(
              widget.me.dimiNoChangedAt == null ? '设置 DIMI 号' : '修改 DIMI 号'),
          content: SingleChildScrollView(
              child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                const Text('朋友可凭此号找到你，无需提供手机号。'),
                const SizedBox(height: 16),
                TextField(
                    controller: _ctrl,
                    enabled: canEdit && !_saving,
                    autofocus: canEdit,
                    maxLength: 20,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: InputDecoration(
                        labelText: 'DIMI 号',
                        counterText: '',
                        errorText: _error,
                        errorMaxLines: 3),
                    onSubmitted: canEdit ? (_) => _save() : null),
                const SizedBox(height: 12),
                Text(
                    canEdit
                        ? '字母开头，6–20 位字母、数字、_ 或 -。不区分大小写，每 365 天可修改一次。'
                        : '下次可修改：${next.year}/${next.month}/${next.day}',
                    style: const TextStyle(fontSize: 15, color: kDimiGray99)),
              ])),
          actions: [
            TextButton(
                onPressed: _saving ? null : () => Navigator.pop(context),
                child: const Text('取消')),
            if (canEdit)
              FilledButton(
                  onPressed: _saving ? null : _save,
                  child: Text(_saving ? '保存中…' : '保存')),
          ],
        ));
  }
}
