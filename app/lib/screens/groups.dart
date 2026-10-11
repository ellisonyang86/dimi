/// 分组管理：普通/高隐私分组的列表与 CRUD。
/// 高隐私组的改级别/删除须解锁凭证，被 40301 门禁拦截时弹解锁框重试；
/// 未解锁时高隐私组成员数显示「解锁后可见」。
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../state/session.dart';
import '../theme.dart';
import '../widgets/common/dimi_dialog.dart';
import '../widgets/common/dimi_section.dart';
import '../widgets/group_unlock.dart';

class GroupsScreen extends StatefulWidget {
  const GroupsScreen({super.key});

  static const routeName = '/groups';

  @override
  State<GroupsScreen> createState() => _GroupsScreenState();
}

class _GroupsScreenState extends State<GroupsScreen>
    with GroupUnlockAware<GroupsScreen> {
  int _loadVersion = 0;

  @override
  void onGroupLocked() {
    setState(() {
      _items = [];
    });
    _load();
  }

  List<ContactGroup> _items = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _load() async {
    if (!mounted) return;
    final version = ++_loadVersion;
    final unlockToken = context.read<Session>().groupUnlockToken;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final session = context.read<Session>();
      final res =
          await context.read<DimiApi>().contactGroups(unlockToken: unlockToken);
      if (!mounted || version != _loadVersion) return;
      if (unlockToken != session.groupUnlockToken) return await _load();
      // 凭证已过期（服务端视角未解锁）时清掉本地内存态
      if (!res.unlocked && unlockToken != null) {
        session.clearGroupUnlockToken();
      }
      if (version == _loadVersion) setState(() => _items = res.items);
    } on ApiException catch (e) {
      if (!mounted || version != _loadVersion) return;
      setState(() => _error = e.message);
    } finally {
      if (mounted && version == _loadVersion) setState(() => _loading = false);
    }
  }

  Future<void> _createGroup() async {
    final ctrl = TextEditingController();
    var level = 'normal';
    final saved = await showDimiDialog<({String name, String level})>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => AlertDialog(
          title: const Text('新建分组'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: ctrl,
                autofocus: true,
                maxLength: 16,
                decoration: const InputDecoration(
                  hintText: '分组名称（不超过 16 字）',
                  counterText: '',
                ),
              ),
              const SizedBox(height: 12),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'normal', label: Text('普通')),
                  ButtonSegment(value: 'high', label: Text('高隐私')),
                ],
                selected: {level},
                onSelectionChanged: (sel) => setSheet(() => level = sel.first),
              ),
              if (level == 'high')
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text(
                    '高隐私分组中的联系人在好友列表默认隐藏，须隐私密码解锁查看',
                    style: TextStyle(fontSize: 14, color: kDimiGray99),
                  ),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.of(ctx).pop((name: ctrl.text.trim(), level: level)),
              style: FilledButton.styleFrom(backgroundColor: kDimiPrimaryFill),
              child: const Text('创建'),
            ),
          ],
        ),
      ),
    );
    ctrl.dispose();
    if (saved == null || saved.name.isEmpty || !mounted) return;
    try {
      await context
          .read<DimiApi>()
          .createGroup(name: saved.name, privacyLevel: saved.level);
      if (!mounted) return;
      _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      // 建高隐私组未设密码时服务端返回 40001，文案引导先设密码
      _toast(e.message);
    }
  }

  Future<void> _rename(ContactGroup g) async {
    final ctrl = TextEditingController(text: g.name);
    final name = await showDimiDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名分组'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLength: 16,
          decoration: const InputDecoration(counterText: ''),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
            style: FilledButton.styleFrom(backgroundColor: kDimiPrimaryFill),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (name == null || name.isEmpty || name == g.name || !mounted) return;
    final ok = await runWithGroupUnlock(
        context,
        (token) => context
            .read<DimiApi>()
            .updateGroup(g.groupId, name: name, unlockToken: token));
    if (!mounted) return;
    if (ok) _load();
  }

  Future<void> _toggleLevel(ContactGroup g) async {
    final target = g.isHigh ? 'normal' : 'high';
    final ok = await runWithGroupUnlock(
        context,
        (token) => context
            .read<DimiApi>()
            .updateGroup(g.groupId, privacyLevel: target, unlockToken: token));
    if (!mounted) return;
    if (ok) _load();
  }

  Future<void> _delete(ContactGroup g) async {
    final yes = await showDimiDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除分组「${g.name}」？'),
        content: const Text('删除后组内联系人移回未分组，不会被删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(backgroundColor: kDimiPrimaryFill),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    final ok = await runWithGroupUnlock(
        context,
        (token) =>
            context.read<DimiApi>().deleteGroup(g.groupId, unlockToken: token));
    if (!mounted) return;
    if (ok) _load();
  }

  void _showGroupActions(ContactGroup g) {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined, color: kDimiPrimary),
              title: const Text('重命名'),
              onTap: () {
                Navigator.pop(ctx);
                _rename(g);
              },
            ),
            ListTile(
              leading: Icon(
                g.isHigh ? Icons.lock_open_outlined : Icons.lock_outline,
                color: kDimiPrimary,
              ),
              title: Text(g.isHigh ? '改为普通分组' : '改为高隐私分组'),
              onTap: () {
                Navigator.pop(ctx);
                _toggleLevel(g);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: kDimiDanger),
              title: const Text('删除分组', style: TextStyle(color: kDimiDanger)),
              onTap: () {
                Navigator.pop(ctx);
                _delete(g);
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kDimiBg,
      appBar: AppBar(
        title: const Text('分组管理'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: '新建分组',
            onPressed: _createGroup,
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: kDimiPrimary),
      );
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, style: const TextStyle(color: kDimiGray99)),
            const SizedBox(height: 8),
            OutlinedButton(onPressed: _load, child: const Text('重试')),
          ],
        ),
      );
    }
    if (_items.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('还没有分组', style: TextStyle(color: kDimiGray99)),
            const SizedBox(height: 8),
            OutlinedButton(onPressed: _createGroup, child: const Text('新建分组')),
          ],
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 7),
      children: [
        // 微信式分组排版：整块白底 + 组内发丝分隔线
        DimiSection(
          dividerIndent: kDimiSectionDividerIndentTile,
          children: [for (final g in _items) _groupTile(g)],
        ),
        const Padding(
          padding: EdgeInsets.all(10),
          child: Text(
            '高隐私分组中的联系人在好友列表默认隐藏，须隐私密码解锁查看；长按或点 ⋯ 管理分组。',
            style: TextStyle(fontSize: 14, color: kDimiGray99, height: 1.6),
          ),
        ),
      ],
    );
  }

  Widget _groupTile(ContactGroup g) {
    return ListTile(
      leading: Icon(
        g.isHigh ? Icons.lock_outline : Icons.folder_outlined,
        color: g.isHigh ? kDimiApricotDeep : kDimiPrimary,
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(g.name,
                style: const TextStyle(fontSize: 17, color: kDimiText),
                overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: g.isHigh ? kDimiApricotSoft : kDimiPrimarySoft,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              g.isHigh ? '高隐私' : '普通',
              // 12pt 下限 + 深雾杏：浅底标签文字过 WCAG 4.5:1
              style: TextStyle(
                fontSize: 14,
                color: g.isHigh ? kDimiApricotDeep : kDimiPrimary,
              ),
            ),
          ),
        ],
      ),
      subtitle: Text(
        g.memberCount == null ? '成员数：解锁后可见' : '${g.memberCount} 位成员',
        style: const TextStyle(fontSize: 14),
      ),
      trailing: IconButton(
        icon: const Icon(Icons.more_horiz, color: kDimiGray99),
        onPressed: () => _showGroupActions(g),
      ),
      onLongPress: () => _showGroupActions(g),
    );
  }
}
