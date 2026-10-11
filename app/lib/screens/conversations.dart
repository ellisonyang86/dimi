/// 会话列表（原型屏⑤，「消息」tab）：
/// 顶部固定「新的朋友」入口 + /conversations 会话分页。
/// V0.9 用 REST 轮询实现；正式版替换为腾讯云 IM SDK（见 V0.9 计划书 §5.3）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../state/session.dart';
import '../widgets/common/dimi_swipe_row.dart';
import '../widgets/common/dimi_empty_state.dart';
import '../widgets/common/dimi_error_view.dart';
import '../widgets/common/dimi_skeleton.dart';
import '../widgets/dimi_avatar.dart';
import 'chat.dart';
import 'friend_requests.dart';
import '../theme.dart';

class ConversationsView extends StatefulWidget {
  const ConversationsView({super.key, this.onGoOut});

  /// 空态「去城外看看」：由 MainShell 注入，切换到「城外」tab
  final VoidCallback? onGoOut;

  @override
  State<ConversationsView> createState() => _ConversationsViewState();
}

class _ConversationsViewState extends State<ConversationsView>
    with WidgetsBindingObserver {
  bool _loading = true;
  final _swipeController = DimiSwipeController();
  bool _updating = false;
  bool _refreshing = false;
  int _revision = 0;
  String? _error;
  List<Conversation> _items = [];
  int _pendingRequests = 0;
  Timer? _pollTimer;
  bool _appForeground = true;

  /// 「不显示该聊天」的本地隐藏集（SharedPreferences 持久化，key 见下）。
  /// 纯本地能力：服务端无会话隐藏/删除端点，会话数据仍在服务端，
  /// 隐藏只是本机列表过滤；隐藏会话有新消息时自动恢复显示（对齐微信）。
  Set<int> _hiddenConvIds = {};

  /// 隐藏时刻的「convId|lastMsgTime|summary」快照（与隐藏集同步持久化），
  /// 轮询/刷新时对比服务端最新值，变化即视为有新消息 → 移出隐藏集
  final Map<int, String> _hiddenSnapshots = {};

  String get _hiddenKey =>
      'hidden_conv_ids.${context.read<Session>().currentUser?.userId}';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initialize();
    // 会话列表低频轮询（10s，仅 App 前台时发起），正式版由 IM SDK 长连接替代
    _pollTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (!_appForeground) return;
      _refreshSilently();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pollTimer?.cancel();
    _swipeController.dispose();
    super.dispose();
  }

  Future<void> _initialize() async {
    await _loadHidden();
    if (mounted) await _load();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appForeground = state == AppLifecycleState.resumed;
  }

  // ==================== 「不显示该聊天」本地隐藏 ====================

  /// 隐藏快照条目：'convId|lastMsgTime|summary'（summary 可能含 '|'，解析时只按前两段切）
  String _hiddenEntry(Conversation c) =>
      '${c.convId}|${c.lastMsgTime ?? ''}|${c.lastMsgSummary ?? ''}';

  /// 读取持久化的隐藏集；读取失败按无隐藏处理（不阻塞列表）
  Future<void> _loadHidden() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final entries = prefs.getStringList(_hiddenKey) ?? const [];
      final ids = <int>{};
      final snaps = <int, String>{};
      for (final e in entries) {
        final sep = e.indexOf('|');
        final id = sep > 0 ? int.tryParse(e.substring(0, sep)) : null;
        if (id == null) continue;
        ids.add(id);
        snaps[id] = e;
      }
      if (!mounted) return;
      setState(() {
        _hiddenConvIds = ids;
        _hiddenSnapshots
          ..clear()
          ..addAll(snaps);
      });
    } on Exception {
      // SharedPreferences 不可用（如测试环境）：隐藏功能退化为本次会话内不生效
    }
  }

  Future<void> _persistHidden() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_hiddenKey, [
        for (final id in _hiddenConvIds) _hiddenSnapshots[id] ?? '$id||',
      ]);
    } on Exception {
      // 持久化失败静默：隐藏仅本次会话内生效
    }
  }

  /// 隐藏会话恢复检查：服务端最新摘要/时间与隐藏快照不一致（来了新消息）
  /// 即移出隐藏集并持久化，返回是否有恢复发生
  bool _restoreHiddenIfChanged(List<Conversation> convs) {
    if (_hiddenConvIds.isEmpty) return false;
    var changed = false;
    for (final c in convs) {
      if (!_hiddenConvIds.contains(c.convId)) continue;
      if (_hiddenEntry(c) != _hiddenSnapshots[c.convId]) {
        _hiddenConvIds.remove(c.convId);
        _hiddenSnapshots.remove(c.convId);
        changed = true;
      }
    }
    if (changed) _persistHidden();
    return changed;
  }

  /// 「不显示该聊天」（微信同款）：仅本地隐藏，无二次确认，可逆
  Future<void> _hideConversation(Conversation c) async {
    setState(() {
      _hiddenConvIds.add(c.convId);
      _hiddenSnapshots[c.convId] = _hiddenEntry(c);
    });
    await _persistHidden();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('已不显示该聊天，收到新消息时会重新显示')));
  }

  /// 删除只影响本人：服务端保存清除位点，旧消息不会重新出现。
  Future<void> _confirmDeleteConversation(Conversation c) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除该聊天？'),
        content: const Text('删除后，将清空该聊天的消息记录（不影响对方）。'
            '有新消息时该聊天会重新出现在列表中。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: kDimiDangerSoft,
                  foregroundColor: kDimiDanger),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    if (_updating) return;
    _updating = true;
    _revision++;
    try {
      await context.read<DimiApi>().deleteConversation(c.convId);
      if (!mounted) return;
      setState(() => _items.removeWhere((item) => item.convId == c.convId));
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已删除该聊天及本人的历史记录')));
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    } finally {
      _updating = false;
    }
  }

  Future<void> _load() async {
    if (!mounted || _updating) return;
    final revision = ++_revision;
    _swipeController.close();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = context.read<DimiApi>();
      final convs = await api.conversations();
      int pending = 0;
      try {
        final reqs = await api.friendRequests(box: 'inbox');
        pending = reqs.where((r) => r.isPending).length;
      } on ApiException {
        // 申请计数失败不阻塞会话列表
      }
      if (!mounted) return;
      if (_updating || revision != _revision) return;
      _restoreHiddenIfChanged(convs); // 隐藏会话有新消息则恢复显示
      setState(() {
        _items = convs;
        _pendingRequests = pending;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _refreshSilently() async {
    if (!mounted || _refreshing || _updating || _loading) return;
    _refreshing = true;
    final revision = _revision;
    try {
      final api = context.read<DimiApi>();
      final convs = await api.conversations();
      var pending = _pendingRequests;
      try {
        pending = (await api.friendRequests(box: 'inbox'))
            .where((r) => r.isPending)
            .length;
      } on ApiException {/* 不影响会话列表 */}
      if (!mounted || _updating || revision != _revision) return;
      // 隐藏会话有新动静（lastMsgTime/摘要变化）时恢复显示，也要触发重绘
      final restored = _restoreHiddenIfChanged(convs);
      // 静默更新：与当前列表逐项比较，无变化不 setState，避免轮询引起闪烁
      if (!restored &&
          _listEquals(_items, convs) &&
          pending == _pendingRequests) {
        return;
      }
      setState(() {
        _items = convs;
        _pendingRequests = pending;
      });
    } on ApiException {
      // 轮询失败静默
    } finally {
      _refreshing = false;
    }
  }

  /// 比较两版会话列表的展示字段是否完全一致
  bool _listEquals(List<Conversation> a, List<Conversation> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      final x = a[i];
      final y = b[i];
      if (x.convId != y.convId ||
          x.title != y.title ||
          x.avatarUrl != y.avatarUrl ||
          x.lastMsgSummary != y.lastMsgSummary ||
          x.lastMsgTime != y.lastMsgTime ||
          x.unreadCount != y.unreadCount ||
          x.isPinned != y.isPinned ||
          x.isMuted != y.isMuted) {
        return false;
      }
    }
    return true;
  }

  // 长按会话：置顶 / 免打扰（契约 PUT /conversations/{id}/settings）
  void _showConvActions(Conversation c) {
    _swipeController.close();
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(
                  c.isPinned ? Icons.push_pin : Icons.push_pin_outlined,
                  color: kDimiPrimary),
              title: Text(c.isPinned ? '取消置顶' : '置顶会话'),
              onTap: () {
                Navigator.pop(ctx);
                _applyConvSetting(c, pinned: !c.isPinned);
              },
            ),
            ListTile(
              leading: Icon(
                  c.isMuted
                      ? Icons.notifications_off_outlined
                      : Icons.notifications_outlined,
                  color: kDimiPrimary),
              title: Text(c.isMuted ? '取消免打扰' : '消息免打扰'),
              onTap: () {
                Navigator.pop(ctx);
                _applyConvSetting(c, muted: !c.isMuted);
              },
            ),
            // 对齐微信会话管理：不显示（可逆，新消息自动恢复）/ 删除（二次确认）
            ListTile(
              leading: const Icon(Icons.visibility_off_outlined,
                  color: kDimiPrimary),
              title: const Text('不显示该聊天'),
              subtitle: const Text('仅在列表中隐藏，收到新消息时会重新显示',
                  style: TextStyle(fontSize: 14)),
              onTap: () {
                Navigator.pop(ctx);
                _hideConversation(c);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: kDimiDanger),
              title: const Text('删除该聊天', style: TextStyle(color: kDimiDanger)),
              onTap: () {
                Navigator.pop(ctx);
                _confirmDeleteConversation(c);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _applyConvSetting(Conversation c,
      {bool? pinned, bool? muted}) async {
    if (_updating) return;
    _updating = true;
    _revision++;
    try {
      await context.read<DimiApi>().updateConversationSettings(c.convId,
          isPinned: pinned, isMuted: muted);
      _updating = false;
      await _refreshSilently();
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    } finally {
      _updating = false;
    }
  }

  String _formatTime(String? iso) {
    if (iso == null || iso.isEmpty) return '';
    final t = DateTime.tryParse(iso)?.toLocal();
    if (t == null) return '';
    final now = DateTime.now();
    if (t.year == now.year && t.month == now.month && t.day == now.day) {
      return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    }
    if (t.year == now.year) return '${t.month}月${t.day}日';
    return '${t.year}/${t.month}/${t.day}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kDimiBg,
      appBar: AppBar(title: const Text('消息')),
      body: RefreshIndicator(
        color: kDimiPrimary,
        onRefresh: _load,
        child: NotificationListener<ScrollStartNotification>(
          onNotification: (_) {
            _swipeController.close();
            return false;
          },
          child: _buildBody(),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      // 首屏骨架屏（列表骨架与真实条目同构：头像 + 两行文案）
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: DimiListSkeleton(itemCount: 6),
      );
    }
    if (_error != null) {
      // 包一层 ListView 保证错误态仍可下拉刷新
      return ListView(
        children: [
          const SizedBox(height: 80),
          DimiErrorView(message: _error!, onRetry: _load),
        ],
      );
    }
    // 列表只展示未隐藏会话；隐藏集见 _hiddenConvIds（新消息自动恢复）
    final visible =
        _items.where((c) => !_hiddenConvIds.contains(c.convId)).toList();
    // 会话数不设上限，改为 builder 惰性构建：index 0 为「新的朋友」入口卡，
    // 之后每个会话一项；空会话时末尾附引导文案
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      itemCount: visible.isEmpty ? 2 : 1 + visible.length,
      itemBuilder: (context, i) {
        if (i == 0) {
          return Card(
            margin: EdgeInsets.zero,
            child: Column(
              children: [
                // 固定入口：新的朋友
                ListTile(
                  leading: Badge(
                    isLabelVisible: _pendingRequests > 0,
                    label: Text('$_pendingRequests'),
                    backgroundColor: kDimiBadge,
                    child: Container(
                      width: 46,
                      height: 46,
                      decoration: BoxDecoration(
                        color: kDimiApricotSoft,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      alignment: Alignment.center,
                      child: const Icon(Icons.person_add_alt,
                          color: kDimiApricotDeep, size: 22),
                    ),
                  ),
                  title: const Text('新的朋友',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text(
                    _pendingRequests > 0
                        ? '有 $_pendingRequests 条申请待处理'
                        : '查看好友申请',
                    style: const TextStyle(fontSize: 14, color: kDimiGray99),
                  ),
                  onTap: () async {
                    await Navigator.of(context).push(MaterialPageRoute<void>(
                      builder: (_) => const FriendRequestsScreen(),
                    ));
                    _refreshSilently();
                  },
                ),
                if (visible.isNotEmpty) const Divider(height: 1, indent: 72),
              ],
            ),
          );
        }
        if (visible.isEmpty) {
          // 空态：统一空状态组件，行动按钮切到「城外」tab
          return DimiEmptyState(
            icon: Icons.forum_outlined,
            title: '还没有消息',
            message: '去城外找到老同学，打个招呼吧',
            actionLabel: '去城外看看',
            onAction: widget.onGoOut,
          );
        }
        final c = visible[i - 1];
        return DimiSwipeRow(
          key: ValueKey('conv-${c.convId}'),
          id: c.convId,
          controller: _swipeController,
          actions: [
            DimiSwipeAction(
                label: c.isPinned ? '取消置顶' : '置顶',
                icon: Icons.push_pin_outlined,
                onPressed: () => _applyConvSetting(c, pinned: !c.isPinned)),
            DimiSwipeAction(
                label: '更多',
                icon: Icons.more_horiz,
                color: kDimiGray66,
                onPressed: () => _showConvActions(c)),
            DimiSwipeAction(
                label: '删除',
                icon: Icons.delete_outline,
                color: kDimiDanger,
                onPressed: () => _confirmDeleteConversation(c)),
          ],
          child: Ink(
            decoration: BoxDecoration(
              color: c.isPinned ? kDimiPrimarySoft : Colors.white,
              border: const Border(bottom: BorderSide(color: kDimiHairline)),
            ),
            child: ListTile(
              leading: Badge(
                isLabelVisible: c.unreadCount > 0 && !c.isMuted,
                label: Text('${c.unreadCount}'),
                backgroundColor: kDimiBadge,
                child: DimiAvatar(
                  name: c.title,
                  avatarUrl: c.avatarUrl,
                  seed: c.peerId ?? c.convId,
                ),
              ),
              title: Row(
                children: [
                  Expanded(
                    child: Text(
                      c.title,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (c.isMuted)
                    const Icon(Icons.notifications_off_outlined,
                        size: 14, color: kDimiGrayCC),
                ],
              ),
              subtitle: Text(
                displayMessageText('', c.lastMsgSummary ?? ''),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 15, color: kDimiGray55),
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _formatTime(c.lastMsgTime),
                    style: const TextStyle(fontSize: 14, color: kDimiGray66),
                  ),
                  // 显性入口：置顶/免打扰（长按手势保留，⋯ 对中老年用户更易发现）
                  IconButton(
                    icon: const Icon(Icons.more_vert,
                        size: 20, color: kDimiGray66),
                    tooltip: '会话设置',
                    onPressed: () => _showConvActions(c),
                  ),
                ],
              ),
              onTap: () async {
                await Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => ChatScreen(conversation: c),
                ));
                _refreshSilently();
              },
              onLongPress: () => _showConvActions(c),
            ),
          ),
        );
      },
    );
  }
}
