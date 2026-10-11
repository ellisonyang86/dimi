/// 黑名单管理：查看已拉黑用户，可移出黑名单（§8.1 可逆可撤原则）。
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../widgets/common/dimi_section.dart';
import '../widgets/dimi_avatar.dart';
import '../theme.dart';

class BlacklistScreen extends StatefulWidget {
  const BlacklistScreen({super.key});

  static const routeName = '/blacklist';

  @override
  State<BlacklistScreen> createState() => _BlacklistScreenState();
}

class _BlacklistScreenState extends State<BlacklistScreen> {
  bool _loading = true;
  String? _error;
  List<UserBrief> _items = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final items = await context.read<DimiApi>().blockedUsers();
      if (mounted) setState(() => _items = items);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _unblock(UserBrief u) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('移出黑名单：${u.nickname ?? '该用户'}？'),
        content: const Text('解除后你们可以重新检索到对方、发起好友申请。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('移出')),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    try {
      await context.read<DimiApi>().unblockFriend(u.userId);
      _load();
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('黑名单')),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: kDimiPrimary))
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_error!),
                      TextButton(onPressed: _load, child: const Text('重试')),
                    ],
                  ),
                )
              : _items.isEmpty
                  ? const Center(
                      child:
                          Text('黑名单为空', style: TextStyle(color: kDimiGray66)))
                  // 微信式分组排版：整块白底 + 组内发丝分隔线
                  : ListView(
                      padding: const EdgeInsets.symmetric(vertical: 7),
                      children: [
                        DimiSection(
                          dividerIndent: kDimiSectionDividerIndentTile,
                          children: [
                            for (final u in _items)
                              ListTile(
                                leading: DimiAvatar(
                                    name: u.nickname,
                                    avatarUrl: u.avatarUrl,
                                    seed: u.userId),
                                title: Text(u.nickname ?? '未命名',
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w600)),
                                subtitle: const Text('已双向断联',
                                    style: TextStyle(
                                        fontSize: 14, color: kDimiGray66)),
                                trailing: TextButton(
                                  onPressed: () => _unblock(u),
                                  child: const Text('移出'),
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
    );
  }
}
