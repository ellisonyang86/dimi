/// 联系人（我的好友）：已建立联系的好友/老乡统一入口。
/// 列表展示（署名优先级 备注>真名>昵称，§20.6）+ 备注/删除/拉黑/分组管理。
/// 高隐私分组好友未解锁时不出现在列表（locked_count 报告数量），顶部锁定卡可解锁。
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../state/session.dart';
import '../widgets/common/dimi_section.dart';
import '../widgets/common/dimi_swipe_row.dart';
import '../widgets/dimi_avatar.dart';
import '../widgets/group_unlock.dart';
import '../theme.dart';
import '../widgets/common/dimi_dialog.dart';
import 'blacklist.dart';
import 'groups.dart';
import 'hometown_page.dart';
import 'profile_card.dart';

class FriendsScreen extends StatefulWidget {
  const FriendsScreen({super.key});

  static const routeName = '/friends';

  @override
  State<FriendsScreen> createState() => _FriendsScreenState();
}

class _FriendsScreenState extends State<FriendsScreen>
    with GroupUnlockAware<FriendsScreen> {
  int _loadVersion = 0;

  @override
  void onGroupLocked() {
    setState(() {
      _items = [];
      _unlocked = false;
    });
    _load();
  }

  bool _loading = true;
  final _swipeController = DimiSwipeController();
  bool _acting = false;
  String? _error;
  List<FriendEntry> _items = [];
  bool _unlocked = true;
  int _lockedCount = 0;

  DimiApi get _api => context.read<DimiApi>();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    final version = ++_loadVersion;
    final unlockToken = context.read<Session>().groupUnlockToken;
    _swipeController.close();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final session = context.read<Session>();
      var page = await _api.friends(unlockToken: unlockToken);
      if (!mounted || version != _loadVersion) return;
      final items = [...page.items];
      var lockedCount = page.lockedCount;
      while (page.hasMore) {
        final previous = page.nextCursor;
        page = await _api.friends(cursor: previous, unlockToken: unlockToken);
        if (!mounted || version != _loadVersion) return;
        items.addAll(page.items);
        lockedCount += page.lockedCount;
        if (page.nextCursor == previous) break;
      }
      if (unlockToken != session.groupUnlockToken) return await _load();
      items.sort((a, b) => a.isStarred == b.isStarred
          ? a.displayName.compareTo(b.displayName)
          : a.isStarred
              ? -1
              : 1);
      // 凭证已过期（服务端视角未解锁）时清掉本地内存态
      if (!page.unlocked && unlockToken != null) {
        session.clearGroupUnlockToken();
      }
      if (mounted && version == _loadVersion) {
        setState(() {
          _items = items;
          _unlocked = page.unlocked;
          _lockedCount = lockedCount;
        });
      }
    } on ApiException catch (e) {
      if (mounted && version == _loadVersion) {
        setState(() => _error = e.message);
      }
    } finally {
      if (mounted && version == _loadVersion) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _swipeController.dispose();
    super.dispose();
  }

  Future<void> _unlock() async {
    final ok = await showGroupUnlockDialog(context);
    if (ok && mounted) _load();
  }

  Future<void> _lockNow() async {
    try {
      await _api.lockGroups();
    } on ApiException catch (e) {
      _toast(e.message);
    }
    if (!mounted) return;
    context.read<Session>().clearGroupUnlockToken();
    _load();
  }

  /// 移动到分组：底部弹层列出全部分组 +「未分组」，选定即保存刷新
  Future<void> _moveToGroup(FriendEntry f) async {
    ({bool unlocked, List<ContactGroup> items}) groups;
    try {
      groups = await _api.contactGroups(
          unlockToken: context.read<Session>().groupUnlockToken);
    } on ApiException catch (e) {
      _toast(e.message);
      return;
    }
    if (!mounted) return;
    // -1 表示「未分组」（group_id=null），null 表示取消
    final picked = await showModalBottomSheet<int>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading:
                  const Icon(Icons.folder_off_outlined, color: kDimiGray99),
              title: const Text('未分组'),
              trailing: f.groupId == null
                  ? const Icon(Icons.check, size: 18, color: kDimiPrimary)
                  : null,
              onTap: () => Navigator.pop(ctx, -1),
            ),
            ...groups.items.map(
              (g) => ListTile(
                leading: Icon(
                  g.isHigh ? Icons.lock_outline : Icons.folder_outlined,
                  color: g.isHigh ? kDimiApricotDeep : kDimiPrimary,
                ),
                title: Text(g.name),
                trailing: f.groupId == g.groupId
                    ? const Icon(Icons.check, size: 18, color: kDimiPrimary)
                    : null,
                onTap: () => Navigator.pop(ctx, g.groupId),
              ),
            ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    final gid = picked == -1 ? null : picked;
    final ok = await runWithGroupUnlock(context,
        (token) => _api.moveFriendToGroup(f.userId, gid, unlockToken: token));
    if (ok && mounted) {
      _toast(gid == null ? '已移出分组' : '已移动到分组');
      _load();
    }
  }

  Future<void> _editRemark(FriendEntry f) async {
    final ctrl = TextEditingController(text: f.remarkName ?? '');
    final saved = await showDimiDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('设置备注'),
        content: TextField(
          controller: ctrl,
          maxLength: 32,
          autofocus: true,
          decoration: const InputDecoration(hintText: '备注名（留空清除）'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('保存')),
        ],
      ),
    );
    ctrl.dispose();
    if (saved == null || !mounted) return;
    try {
      await _api.updateFriend(f.userId,
          remarkName: saved.isEmpty ? null : saved, clearRemark: saved.isEmpty);
      _load();
    } on ApiException catch (e) {
      _toast(e.message);
    }
  }

  Future<void> _confirmAction(
      String title, String body, Future<void> Function() act) async {
    final yes = await showDimiDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('确认')),
        ],
      ),
    );
    if (yes != true || !mounted || _acting) return;
    _acting = true;
    try {
      await act();
      await _load();
    } on ApiException catch (e) {
      _toast(e.message);
    } finally {
      _acting = false;
    }
  }

  /// 「TA 的家乡」：FriendEntry（UserBrief）不带家乡字段，点击时拉一次资料卡
  /// （GET /users/{id}，字段可见性由服务端按关系判定）；有镇级 region_code
  /// 直达家乡页，未填写/未公开时 toast 提示
  Future<void> _openFriendHometown(FriendEntry f) async {
    try {
      final card = await _api.userCard(f.userId,
          unlockToken: context.read<Session>().groupUnlockToken);
      if (!mounted) return;
      final code = card.hometownRegionCode;
      if (code == null || code.isEmpty) {
        _toast(card.hometownDisplay == null ? 'TA 还没有填写家乡' : 'TA 的家乡暂未开通家乡页');
        return;
      }
      Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => HometownPageScreen(regionCode: code),
      ));
    } on ApiException catch (e) {
      _toast(e.message);
    }
  }

  void _toast(String msg) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  void _showActions(FriendEntry f) {
    _swipeController.close();
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_note, color: kDimiPrimary),
              title: const Text('设置备注'),
              onTap: () {
                Navigator.pop(ctx);
                _editRemark(f);
              },
            ),
            // 「TA 的家乡」捷径：资料卡已有家乡字段跳转，此处补一条直达入口
            ListTile(
              leading:
                  const Icon(Icons.home_work_outlined, color: kDimiApricotDeep),
              title: const Text('TA 的家乡'),
              subtitle:
                  const Text('查看 TA 的家乡页', style: TextStyle(fontSize: 14)),
              onTap: () {
                Navigator.pop(ctx);
                _openFriendHometown(f);
              },
            ),
            ListTile(
              leading: const Icon(Icons.folder_outlined, color: kDimiPrimary),
              title: const Text('移动到分组'),
              subtitle: Text(
                f.groupId == null ? '当前未分组' : '已在分组中',
                style: const TextStyle(fontSize: 14),
              ),
              onTap: () {
                Navigator.pop(ctx);
                _moveToGroup(f);
              },
            ),
            ListTile(
              leading: Icon(
                  f.isStarred ? Icons.star_rounded : Icons.star_outline_rounded,
                  color: kDimiApricotDeep),
              title: Text(f.isStarred ? '取消星标' : '设为星标'),
              onTap: () async {
                Navigator.pop(ctx);
                try {
                  await _api.updateFriend(f.userId, isStarred: !f.isStarred);
                  _load();
                } on ApiException catch (e) {
                  _toast(e.message);
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.block, color: kDimiDanger),
              title: const Text('拉黑', style: TextStyle(color: kDimiDanger)),
              subtitle: const Text('双向断联：互相不可检索、不可消息',
                  style: TextStyle(fontSize: 14)),
              onTap: () {
                Navigator.pop(ctx);
                _confirmAction(
                    '拉黑 ${f.displayName}？',
                    '拉黑后你们互相不可检索、不可发消息，可在「我的好友 → 黑名单」中解除。',
                    () => _api.blockFriend(f.userId));
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: kDimiDanger),
              title: const Text('删除好友', style: TextStyle(color: kDimiDanger)),
              onTap: () {
                Navigator.pop(ctx);
                _confirmAction('删除 ${f.displayName}？', '删除为单向操作，对方列表中仍有你。',
                    () => _api.deleteFriend(f.userId));
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
      appBar: AppBar(
        title: const Text('我的好友'),
        actions: [
          IconButton(
            icon: const Icon(Icons.folder_outlined),
            tooltip: '分组管理',
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => const GroupsScreen(),
            )),
          ),
          IconButton(
            icon: const Icon(Icons.block_outlined),
            tooltip: '黑名单',
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => const BlacklistScreen(),
            )),
          ),
        ],
      ),
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
              : (_items.isEmpty && _lockedCount == 0)
                  ? const Center(
                      child: Text('还没有好友\n去「城外」找老同学、老乡，打个招呼吧',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: kDimiGray66)))
                  : RefreshIndicator(
                      color: kDimiPrimary,
                      onRefresh: _load,
                      // 微信式分组排版：整块白底 + 组内发丝分隔线
                      child: NotificationListener<ScrollStartNotification>(
                        onNotification: (_) {
                          _swipeController.close();
                          return false;
                        },
                        child: ListView(
                          padding: const EdgeInsets.symmetric(vertical: 7),
                          children: [
                            _groupGateCard(),
                            if (_items.isNotEmpty)
                              DimiSection(
                                dividerIndent: kDimiSectionDividerIndentTile,
                                children: [
                                  for (final f in _items) _friendTile(f),
                                ],
                              ),
                          ],
                        ),
                      ),
                    ),
    );
  }

  Widget _friendTile(FriendEntry f) {
    return DimiSwipeRow(
      key: ValueKey('friend-${f.userId}'),
      id: f.userId,
      controller: _swipeController,
      actions: [
        DimiSwipeAction(
            label: '备注',
            icon: Icons.edit_note,
            onPressed: () => _editRemark(f)),
        DimiSwipeAction(
            label: '更多',
            icon: Icons.more_horiz,
            color: kDimiGray66,
            onPressed: () => _showActions(f)),
        DimiSwipeAction(
            label: '删除',
            icon: Icons.person_remove_outlined,
            color: kDimiDanger,
            onPressed: () => _confirmAction(
                '删除 ${f.displayName}？',
                '删除后，对方将从你的好友列表移除；对方列表中仍保留你。',
                () => _api.deleteFriend(f.userId))),
      ],
      child: ListTile(
        leading: DimiAvatar(
          name: f.displayName,
          avatarUrl: f.brief.avatarUrl,
          seed: f.userId,
        ),
        title: Row(
          children: [
            Flexible(
              child: Text(f.displayName,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis),
            ),
            if (f.isStarred)
              const Padding(
                padding: EdgeInsets.only(left: 4),
                child:
                    Icon(Icons.star_rounded, size: 16, color: kDimiApricotDeep),
              ),
          ],
        ),
        subtitle: f.tags.isNotEmpty
            ? Text(f.tags.join(' · '),
                style: const TextStyle(fontSize: 14, color: kDimiGray66))
            : (f.brief.reason != null
                ? Text(f.brief.reason!,
                    style: const TextStyle(fontSize: 14, color: kDimiGray66))
                : null),
        trailing: IconButton(
          icon: const Icon(Icons.more_horiz, color: kDimiGray66),
          onPressed: () => _showActions(f),
        ),
        onTap: () => ProfileCardScreen.open(context, f.userId),
        onLongPress: () => _showActions(f),
      ),
    );
  }

  /// 列表头部：高隐私分组门禁卡（锁定提示 / 已解锁提示），无分组时为空白占位
  Widget _groupGateCard() {
    final hasToken = context.watch<Session>().groupUnlockToken != null;
    if (!_unlocked && _lockedCount > 0) {
      return Card(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              const Icon(Icons.lock_outline, color: kDimiApricotDeep),
              const SizedBox(width: 10),
              Expanded(
                child: Text('有 $_lockedCount 位联系人在高隐私分组',
                    style: const TextStyle(fontSize: 16, color: kDimiText)),
              ),
              FilledButton(
                onPressed: _unlock,
                style: FilledButton.styleFrom(
                  backgroundColor: kDimiPrimaryFill,
                  foregroundColor: kDimiPrimary,
                  minimumSize: Size.zero,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                ),
                child: const Text('解锁查看', style: TextStyle(fontSize: 15)),
              ),
            ],
          ),
        ),
      );
    }
    if (_unlocked && hasToken) {
      return Card(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          child: Row(
            children: [
              const Icon(Icons.lock_open_outlined,
                  size: 20, color: kDimiPrimary),
              const SizedBox(width: 10),
              const Expanded(
                child: Text('已解锁 · 5 分钟后自动锁定',
                    style: TextStyle(fontSize: 15, color: kDimiGray99)),
              ),
              TextButton(
                onPressed: _lockNow,
                child: const Text('立即锁定',
                    style: TextStyle(fontSize: 15, color: kDimiPrimary)),
              ),
            ],
          ),
        ),
      );
    }
    return const SizedBox.shrink();
  }
}
