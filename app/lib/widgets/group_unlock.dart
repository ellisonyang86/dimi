/// 高隐私分组解锁：密码对话框 → /privacy/groups/unlock → 凭证写入 Session（内存态）。
/// 供好友列表 / 分组管理 / 资料卡门禁三处复用。
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../state/session.dart';
import '../theme.dart';
import 'common/dimi_dialog.dart';

void _toast(BuildContext context, String msg) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
}

/// 弹密码框并解锁；成功返回 true（取消或失败返回 false）。
/// 失败文案直接展示服务端 message（密码错误 40001 / 5 次失败锁定 42901）。
Future<bool> showGroupUnlockDialog(BuildContext context) async {
  final ctrl = TextEditingController();
  final password = await showDimiDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('解锁高隐私分组'),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        obscureText: true,
        maxLength: 64,
        decoration: const InputDecoration(
          hintText: '输入隐私密码',
          counterText: '',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(ctrl.text),
          style: FilledButton.styleFrom(backgroundColor: kDimiPrimaryFill),
          child: const Text('解锁'),
        ),
      ],
    ),
  );
  ctrl.dispose();
  if (password == null || password.isEmpty || !context.mounted) return false;
  final session = context.read<Session>();
  final accountToken = session.accessToken;
  try {
    final result = await context.read<DimiApi>().unlockGroups(password);
    if (!context.mounted || accountToken != session.accessToken) return false;
    session.setGroupUnlockToken(result.token,
        lifetime: Duration(seconds: result.expiresIn));
    return true;
  } on ApiException catch (e) {
    if (context.mounted) _toast(context, e.message);
    return false;
  }
}

/// 到期或主动锁定时立即丢弃页面中的已解锁数据，再按锁定权限刷新。
mixin GroupUnlockAware<T extends StatefulWidget> on State<T> {
  Session? _groupSession;
  String? _previousGroupToken;

  void onGroupLocked();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final session = context.read<Session>();
    if (identical(session, _groupSession)) return;
    _groupSession?.removeListener(_groupSessionChanged);
    _groupSession = session;
    _previousGroupToken = session.groupUnlockToken;
    session.addListener(_groupSessionChanged);
  }

  void _groupSessionChanged() {
    final current = _groupSession?.groupUnlockToken;
    final locked = _previousGroupToken != null && current == null;
    _previousGroupToken = current;
    if (locked && mounted) onGroupLocked();
  }

  @override
  void dispose() {
    _groupSession?.removeListener(_groupSessionChanged);
    super.dispose();
  }
}

/// 执行需要解锁凭证的操作；被门禁拦截（40301 data.locked）时弹解锁框，
/// 解锁成功后用新凭证重试一次。返回操作是否最终成功。
Future<bool> runWithGroupUnlock(
  BuildContext context,
  Future<void> Function(String? unlockToken) action,
) async {
  Future<bool> attempt() async {
    try {
      await action(context.read<Session>().groupUnlockToken);
      return true;
    } on ApiException catch (e) {
      if (context.mounted) _toast(context, e.message);
      return false;
    }
  }

  try {
    await action(context.read<Session>().groupUnlockToken);
    return true;
  } on ApiException catch (e) {
    if (!e.isGroupLocked || !context.mounted) {
      if (context.mounted) _toast(context, e.message);
      return false;
    }
    final ok = await showGroupUnlockDialog(context);
    if (!ok || !context.mounted) return false;
    return attempt();
  }
}
