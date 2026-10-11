/// 朋友圈时间线（好友 + 自己的动态，倒序分页）。
/// 本屏也复用于同学圈 / 老乡圈聚合页（构造传 title + visibility，整页锁定该圈，
/// 不提供圈切换——发现页已有三个独立入口，圈界清晰）：
/// 圈页按作者关系聚合（同窗=同校同届、同乡=家乡同市，均无需先加好友），
/// 收录其公开动态与对应圈动态，见 moments.js 可见性语义。
/// 下拉刷新 + 滚动到底自动加载下一页；自己的动态可 ⋯ 删除；
/// 点赞本地乐观更新，失败回滚；评论在卡片内就地输入直发（微信式，不跳详情），
/// 发出后拉详情回灌该条，评论即时出现在卡片评论区。45001 内容拦截直接 toast 服务端文案。
/// AppBar 相机：点按弹底部菜单（拍照 / 相册 / 发纯文字），长按为发纯文字快捷方式；
/// 滚动超过一屏后右下角浮出「返回顶部」小按钮。
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../theme.dart';
import '../widgets/common/dimi_empty_state.dart';
import '../widgets/common/dimi_error_view.dart';
import '../widgets/common/dimi_skeleton.dart';
import '../widgets/moment_card.dart';
import '../widgets/gift_sheet.dart';
import '../widgets/report_dialog.dart';
import 'moment_compose.dart';
import 'moment_detail.dart';
import 'profile_card.dart';

class MomentsFeedScreen extends StatefulWidget {
  const MomentsFeedScreen({super.key, this.title = '朋友圈', this.visibility});

  /// AppBar 标题；聚合页复用时传「同学圈」「老乡圈」
  final String title;

  /// 可见范围过滤（classmates / fellows），null 为完整时间线；
  /// 整页锁定该圈，不提供切换（发现页已有独立入口）
  final String? visibility;

  @override
  State<MomentsFeedScreen> createState() => _MomentsFeedScreenState();
}

class _MomentsFeedScreenState extends State<MomentsFeedScreen> {
  final _scrollCtrl = ScrollController();

  List<Moment> _items = [];
  String? _cursor;
  bool _hasMore = false;
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;

  /// 本页锁定的圈子：null=全部（好友时间线）、classmates=同学圈（同窗聚合）、
  /// fellows=老乡圈（同乡聚合）
  String? get _filter => widget.visibility;

  /// 请求代际号：每次 _load 自增，_load/_loadMore 落地前比对，
  /// 不一致（下拉刷新已发起新请求）则丢弃旧响应，防竞态串页
  int _gen = 0;

  /// 滚动超过一屏后显示「返回顶部」浮动按钮
  bool _showBackToTop = false;

  /// 点赞在途门闩（按 momentId）：防连点导致 likeCount 漂移
  final Set<int> _likeBusy = {};

  DimiApi get _api => context.read<DimiApi>();

  @override
  void initState() {
    super.initState();
    _load();
    _scrollCtrl.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollCtrl.hasClients) return;
    // 超过约一屏高度（600px）即显示返回顶部
    final show = _scrollCtrl.position.pixels > 600;
    if (show != _showBackToTop) setState(() => _showBackToTop = show);
  }

  void _toast(String msg) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  Future<void> _load() async {
    final gen = ++_gen;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await _api.momentsFeed(visibility: _filter);
      if (!mounted || gen != _gen) return;
      setState(() {
        _items = page.items;
        _cursor = page.nextCursor;
        _hasMore = page.nextCursor != null && page.nextCursor!.isNotEmpty;
      });
    } on ApiException catch (e) {
      if (mounted && gen == _gen) setState(() => _error = e.message);
    } finally {
      if (mounted && gen == _gen) setState(() => _loading = false);
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore || _cursor == null) return;
    // 捕获当前代际：在途期间若下拉刷新（新代际），本响应直接丢弃
    final gen = _gen;
    setState(() => _loadingMore = true);
    try {
      final page = await _api.momentsFeed(cursor: _cursor, visibility: _filter);
      if (!mounted || gen != _gen) return;
      setState(() {
        _items = [..._items, ...page.items];
        _cursor = page.nextCursor;
        _hasMore = page.nextCursor != null && page.nextCursor!.isNotEmpty;
      });
    } on ApiException catch (e) {
      if (gen == _gen) _toast(e.message);
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  /// 点赞乐观更新：先改本地，失败回滚；_likeBusy 门闩防连点双击漂移
  Future<void> _toggleLike(Moment m) async {
    if (!_likeBusy.add(m.momentId)) return;
    final wasLiked = m.liked;
    setState(() {
      m.liked = !wasLiked;
      m.likeCount += wasLiked ? -1 : 1;
    });
    try {
      if (wasLiked) {
        await _api.unlikeMoment(m.momentId);
      } else {
        await _api.likeMoment(m.momentId);
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        m.liked = wasLiked;
        m.likeCount += wasLiked ? 1 : -1;
      });
      _toast(e.message);
    } finally {
      _likeBusy.remove(m.momentId);
    }
  }

  /// 就地评论：发帖成功后拉详情回灌该条（含服务端过滤后的完整可见评论），
  /// 卡片评论区即时更新；失败 toast 并 rethrow，卡片保留输入文本便于重发
  Future<void> _sendComment(Moment m, String content) async {
    try {
      await _api.commentMoment(m.momentId, content);
      final fresh = await _api.momentDetail(m.momentId);
      if (!mounted) return;
      setState(() {
        final i = _items.indexWhere((e) => e.momentId == m.momentId);
        if (i >= 0) _items[i] = fresh;
      });
    } on ApiException catch (e) {
      _toast(e.message);
      rethrow;
    }
  }

  Future<void> _confirmDelete(Moment m) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这条动态？'),
        content: const Text('删除后不可恢复，好友的时间线中也会消失。'),
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
    try {
      await _api.deleteMoment(m.momentId);
      if (!mounted) return;
      setState(() => _items.removeWhere((e) => e.momentId == m.momentId));
      _toast('已删除');
    } on ApiException catch (e) {
      _toast(e.message);
    }
  }

  Future<void> _compose({bool textOnly = false}) async {
    final published = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
          builder: (_) => MomentComposeScreen(textOnly: textOnly)),
    );
    if (published == true) _load();
  }

  /// 相机短按：底部菜单显性展示三个发布入口（拍照 / 相册 / 纯文字）；
  /// 拍照与相册均进入图文发布页（图片选择在发布页内完成），纯文字直达文字模式。
  Future<void> _showComposeMenu() async {
    final action = await showModalBottomSheet<String>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(kDimiRadiusSheet)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading:
                  const Icon(Icons.photo_camera_outlined, color: kDimiPrimary),
              title: const Text('拍照'),
              onTap: () => Navigator.pop(ctx, 'photo'),
            ),
            ListTile(
              leading:
                  const Icon(Icons.photo_library_outlined, color: kDimiPrimary),
              title: const Text('从相册选择'),
              onTap: () => Navigator.pop(ctx, 'album'),
            ),
            ListTile(
              leading: const Icon(Icons.edit_outlined, color: kDimiPrimary),
              title: const Text('发纯文字'),
              onTap: () => Navigator.pop(ctx, 'text'),
            ),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    _compose(textOnly: action == 'text');
  }

  Future<void> _openDetail(Moment m) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
          builder: (_) => MomentDetailScreen(momentId: m.momentId)),
    );
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kDimiBg,
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          // 相机：短按弹发布菜单（拍照/相册/纯文字），长按直达纯文字（快捷保留）
          Tooltip(
            message: '点按选择发布方式，长按发文字',
            child: GestureDetector(
              onTap: _showComposeMenu,
              onLongPress: () => _compose(textOnly: true),
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Icon(Icons.photo_camera_outlined),
              ),
            ),
          ),
        ],
      ),
      body: Stack(
        children: [
          _buildBody(),
          if (_showBackToTop)
            Positioned(
              right: 16,
              bottom: 24,
              child: _BackToTopButton(
                onTap: () => _scrollCtrl.animateTo(
                  0,
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeOut,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const _MomentsSkeleton();
    }
    if (_error != null) {
      return DimiErrorView(message: _error!, onRetry: _load);
    }
    if (_items.isEmpty) {
      return DimiEmptyState(
        icon: Icons.auto_awesome_outlined,
        title: '还没有动态',
        message: switch (_filter) {
          'classmates' => '同学们还没发动态，你先来第一条',
          'fellows' => '老乡们还没发动态，你先来第一条',
          _ => '发第一条，让好友看看你的近况',
        },
        actionLabel: '发动态',
        onAction: _showComposeMenu,
      );
    }
    return RefreshIndicator(
      color: kDimiPrimary,
      onRefresh: _load,
      child: NotificationListener<ScrollNotification>(
        onNotification: (n) {
          // 滚动接近底部时加载下一页
          if (n.metrics.pixels >= n.metrics.maxScrollExtent - 200) {
            _loadMore();
          }
          return false;
        },
        child: ListView.builder(
          controller: _scrollCtrl,
          padding: const EdgeInsets.only(bottom: 24),
          itemCount: _items.length + (_hasMore || _loadingMore ? 1 : 0),
          itemBuilder: (ctx, i) {
            if (i >= _items.length) {
              return const Padding(
                padding: EdgeInsets.all(12),
                child: Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: kDimiPrimary),
                  ),
                ),
              );
            }
            final m = _items[i];
            return MomentCard(
              // 按 momentId 稳键：下拉刷新/分页后卡片状态（就地输入框展开态）不串位
              key: ValueKey(m.momentId),
              moment: m,
              onTap: () => _openDetail(m),
              onLongPress: m.isOwn
                  ? null
                  : () => showReportDialog(
                        context,
                        targetType: 'moment',
                        targetId: m.momentId,
                      ),
              onToggleLike: () => _toggleLike(m),
              onAuthorTap: m.author == null
                  ? null
                  : () => ProfileCardScreen.open(context, m.author!.userId),
              onSendComment: (content) => _sendComment(m, content),
              onViewAllComments: () => _openDetail(m),
              onDelete: m.isOwn ? () => _confirmDelete(m) : null,
              onGift: m.isOwn
                  ? null
                  : () => showMomentGiftSheet(context, m.momentId),
            );
          },
        ),
      ),
    );
  }
}

/// 加载态骨架：按动态卡形态（头像 + 署名两行 + 正文条 + 图片块）占位
class _MomentsSkeleton extends StatelessWidget {
  const _MomentsSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      physics: const NeverScrollableScrollPhysics(),
      itemCount: 3,
      separatorBuilder: (_, __) => const SizedBox(height: kDimiSpace8),
      itemBuilder: (_, __) => Container(
        color: Colors.white,
        padding: const EdgeInsets.all(kDimiSpace14),
        child: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                DimiSkeleton(width: 46, height: 46, radius: 23),
                SizedBox(width: kDimiSpace10),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    DimiSkeleton(width: 120, height: 14),
                    SizedBox(height: 6),
                    DimiSkeleton(width: 80, height: 12),
                  ],
                ),
              ],
            ),
            SizedBox(height: kDimiSpace10),
            DimiSkeleton(height: 14),
            SizedBox(height: 6),
            DimiSkeleton(width: 220, height: 14),
            SizedBox(height: kDimiSpace10),
            DimiSkeleton(width: 200, height: 110, radius: 6),
          ],
        ),
      ),
    );
  }
}

/// 「返回顶部」浮动小按钮：圆形白底 + 柔和阴影
class _BackToTopButton extends StatelessWidget {
  const _BackToTopButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      shape: const CircleBorder(),
      elevation: 0,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Container(
          width: 48,
          height: 48,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.arrow_upward, size: 22, color: kDimiPrimary),
        ),
      ),
    );
  }
}
