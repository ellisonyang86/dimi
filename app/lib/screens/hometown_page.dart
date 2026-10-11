/// 家乡页（M1，对齐《家乡页与共建体系设计_V1》§3/§11.1）：
/// 封面（16:9，空封面走雾杏渐变+镇名）+ 镇名全路径 +「N 人关注」+ 关注按钮
/// + 简介折叠区 + 分类 Tab（风光/特产/手艺/故事）+ 内容卡列表
/// （下拉刷新 + 滚动分页 + 骨架屏/空态/错误态）+ rolled_up 县页兜底提示
/// + 底部老乡群入口卡 + 右下角「分享家乡」浮动投稿按钮。
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../theme.dart';
import '../widgets/common/dimi_empty_state.dart';
import '../widgets/common/dimi_error_view.dart';
import '../widgets/common/dimi_skeleton.dart';
import '../widgets/dimi_avatar.dart';
import 'chat.dart';
import 'followed_hometowns.dart';
import 'hometown_compose.dart';
import 'hometown_content_detail.dart';
import 'profile_card.dart';

class HometownPageScreen extends StatefulWidget {
  const HometownPageScreen({super.key, required this.regionCode});

  /// 镇级 region_code
  final String regionCode;

  @override
  State<HometownPageScreen> createState() => _HometownPageScreenState();
}

class _HometownPageScreenState extends State<HometownPageScreen> {
  final _scrollCtrl = ScrollController();

  HometownPage? _page;
  bool _pageLoading = true;
  String? _pageError;

  /// 分类 Tab：风光/特产/手艺/故事，默认风光
  static const _categories = <String, String>{
    'scenery': '风光',
    'product': '特产',
    'craft': '手艺',
    'story': '故事',
  };
  String _category = 'scenery';

  final List<HometownContent> _items = [];
  bool _rolledUp = false;
  List<HometownContent> _rollupItems = const [];
  String? _cursor;
  bool _hasMore = false;
  bool _listLoading = true;
  bool _loadingMore = false;
  String? _listError;

  bool _followBusy = false;
  bool _joiningGroup = false;
  bool _introExpanded = false;

  /// 请求代际号（照抄 moments_feed 的 _gen 模式）：首屏/刷新/切分类自增，
  /// _loadContents 首屏/_loadMore/_switchCategory 三路径落地前比对，
  /// 不一致（已有新请求在途）则丢弃旧响应，防竞态串页
  int _gen = 0;

  /// 41001 页面不存在为终态：渲染锁定提示，不给重试按钮
  bool _pageGone = false;

  DimiApi get _api => context.read<DimiApi>();

  @override
  void initState() {
    super.initState();
    _scrollCtrl.addListener(_maybeLoadMore);
    _loadPage();
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _toast(String msg) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  /// 滚动近底自动加载下一页
  void _maybeLoadMore() {
    if (!_hasMore || _loadingMore || _listLoading || _listError != null) return;
    if (_scrollCtrl.position.pixels >
        _scrollCtrl.position.maxScrollExtent - 200) {
      _loadContents(cursor: _cursor);
    }
  }

  Future<void> _loadPage() async {
    setState(() {
      _pageLoading = true;
      _pageError = null;
      _pageGone = false;
    });
    try {
      final p = await _api.hometownPage(widget.regionCode);
      if (!mounted) return;
      setState(() => _page = p);
      // 页面信息与内容列表互不阻塞；页面加载失败（含 41001）不再触发列表请求
      _loadContents();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _pageError = e.message;
        _pageGone = e.code == ApiException.notFound;
      });
    } finally {
      if (mounted) setState(() => _pageLoading = false);
    }
  }

  /// 内容列表：cursor 为 null 时为首屏/刷新（重置列表，开启新代际）
  Future<void> _loadContents({String? cursor}) async {
    // 首屏/刷新/切分类开启新代际；加载更多捕获当前代际，
    // 在途期间若已发起新首屏请求，旧响应落地前比对 gen 直接丢弃
    final gen = cursor == null ? ++_gen : _gen;
    if (cursor == null) {
      setState(() {
        _listLoading = true;
        _listError = null;
      });
    } else {
      setState(() => _loadingMore = true);
    }
    try {
      final page = await _api.hometownPageContents(
        widget.regionCode,
        category: _category,
        cursor: cursor,
      );
      if (!mounted || gen != _gen) return;
      setState(() {
        if (cursor == null) {
          _items
            ..clear()
            ..addAll(page.items);
        } else {
          _items.addAll(page.items);
        }
        _cursor = page.nextCursor;
        _hasMore = page.hasMore;
        _rolledUp = page.rolledUp;
        _rollupItems = page.rollupItems;
      });
    } on ApiException catch (e) {
      if (!mounted || gen != _gen) return;
      // 加载更多失败只提示，不推翻已有列表
      if (cursor == null) {
        setState(() => _listError = e.message);
      } else {
        _toast(e.message);
      }
    } finally {
      if (mounted && gen == _gen) {
        setState(() {
          _listLoading = false;
          _loadingMore = false;
        });
      }
    }
  }

  /// 下拉刷新：页面信息 + 当前分类首屏
  Future<void> _refresh() async {
    try {
      final p = await _api.hometownPage(widget.regionCode);
      if (mounted) setState(() => _page = p);
    } on ApiException {
      // 页面信息刷新失败静默，不打断列表刷新
    }
    await _loadContents();
  }

  /// 切换分类：重置列表回到首屏
  void _switchCategory(String category) {
    if (category == _category) return;
    setState(() {
      _category = category;
      _items.clear();
      _rollupItems = const [];
      _rolledUp = false;
      _cursor = null;
      _hasMore = false;
    });
    _loadContents();
  }

  /// 关注 / 取消关注（乐观更新，失败回滚）
  Future<void> _toggleFollow() async {
    final p = _page;
    if (p == null || _followBusy) return;
    final wasFollowing = p.isFollowing;
    setState(() {
      _followBusy = true;
      p.isFollowing = !wasFollowing;
      p.followerCount += wasFollowing ? -1 : 1;
    });
    try {
      if (wasFollowing) {
        await _api.unfollowHometownPage(p.regionCode);
      } else {
        await _api.followHometownPage(p.regionCode);
      }
      // 同步本机关注集合（服务端关注列表端点待补，见 followed_hometowns.dart）
      if (wasFollowing) {
        await FollowedHometownsStore.unfollow(p.regionCode);
      } else {
        await FollowedHometownsStore.follow(p.regionCode, p.displayPath);
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        p.isFollowing = wasFollowing;
        p.followerCount += wasFollowing ? 1 : -1;
      });
      _toast(e.message);
    } finally {
      if (mounted) setState(() => _followBusy = false);
    }
  }

  /// 老乡群入口：未加入（含群未建）先 join（服务端按我的家乡定位单元，幂等），
  /// 再进聊天页——复用 home.dart _openHometownGroup 的模式
  Future<void> _openGroup() async {
    if (_joiningGroup) return;
    final p = _page;
    if (p == null) return;
    if (!p.canPost) {
      _toast('只有当地老乡才能加入该老乡群');
      return;
    }
    setState(() => _joiningGroup = true);
    try {
      final g = await _api.joinHometownGroup(regionCode: p.regionCode);
      if (!mounted) return;
      // convId 是进聊天页的必需字段，接口缺失时 fromJson 兜底 0，视为异常不进页
      if (g.convId <= 0) {
        _toast('老乡群信息异常，请稍后重试');
        return;
      }
      await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => ChatScreen(
          conversation: Conversation(
            convId: g.convId,
            convType: 'group',
            groupKind: 'hometown',
            title: g.title ?? '老乡群',
            memberCount: g.memberCount,
          ),
        ),
      ));
    } on ApiException catch (e) {
      _toast(e.message);
    } finally {
      if (mounted) setState(() => _joiningGroup = false);
    }
  }

  /// 「分享家乡」投稿：can_post=false（非当地老乡）时点击仅提示
  Future<void> _openCompose() async {
    final p = _page;
    if (p == null) return;
    if (!p.canPost) {
      _toast('只有当地老乡才能投稿');
      return;
    }
    final created =
        await Navigator.of(context).push<bool>(MaterialPageRoute<bool>(
      builder: (_) => HometownComposeScreen(
        regionCode: p.regionCode,
        townName: p.townName,
      ),
    ));
    // 投稿成功回页面刷新列表（服务端初审后进最新区）
    if (created == true && mounted) _refresh();
  }

  Future<void> _openDetail(HometownContent item) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => HometownContentDetailScreen(contentId: item.contentId),
    ));
    if (mounted) await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final townName = _page?.townName ?? '家乡页';
    return Scaffold(
      backgroundColor: kDimiBg,
      appBar: AppBar(title: Text(townName)),
      body: _buildBody(),
      floatingActionButton: _page == null
          ? null
          : FloatingActionButton.extended(
              onPressed: _openCompose,
              backgroundColor: kDimiApricotSoft,
              foregroundColor: kDimiApricotDeep,
              icon: const Icon(Icons.add_a_photo_outlined),
              label: const Text('分享家乡'),
            ),
    );
  }

  Widget _buildBody() {
    if (_pageLoading && _page == null) {
      // 首屏骨架屏，替代转圈加载
      return ListView(
        padding: const EdgeInsets.all(12),
        children: const [
          DimiSkeleton(height: 200, radius: kDimiRadiusCard),
          SizedBox(height: 10),
          DimiSkeleton(height: 72, radius: kDimiRadiusCard),
          SizedBox(height: 10),
          DimiSkeleton(height: 120, radius: kDimiRadiusCard),
        ],
      );
    }
    if (_pageError != null && _page == null) {
      // 41001 页面不存在为终态（重试无意义），对齐 profile_card 锁定态：
      // 图标 + 提示文案，不给重试按钮
      if (_pageGone) {
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.home_work_outlined,
                  size: 48, color: kDimiGrayCC),
              const SizedBox(height: 12),
              Text(_pageError!, style: const TextStyle(color: kDimiGray99)),
            ],
          ),
        );
      }
      return DimiErrorView(message: _pageError!, onRetry: _loadPage);
    }
    final p = _page!;
    return RefreshIndicator(
      color: kDimiPrimary,
      onRefresh: _refresh,
      child: ListView(
        controller: _scrollCtrl,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(bottom: 96),
        children: [
          _coverHeader(p),
          if (p.intro.isNotEmpty) _introSection(p),
          _categoryTabs(),
          _contentList(),
          if (p.group != null) _groupEntry(p),
          _disclaimer(),
        ],
      ),
    );
  }

  /// 封面区：16:9 封面图；空封面走雾杏渐变 + 镇名；
  /// 下方叠镇名全路径 +「N 人关注」+ 关注按钮
  Widget _coverHeader(HometownPage p) {
    final cover = p.coverMedia;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AspectRatio(
          aspectRatio: cover == null || cover.isEmpty ? 3.2 : 16 / 9,
          child: cover != null && cover.isNotEmpty
              ? CachedNetworkImage(
                  imageUrl: cover,
                  fit: BoxFit.cover,
                  // 列表/封面图限制解码宽度 800，防大图占内存
                  memCacheWidth: 800,
                  placeholder: (_, __) => _coverFallback(p, showName: false),
                  errorWidget: (_, __, ___) => _coverFallback(p),
                )
              : _coverFallback(p),
        ),
        Container(
          width: double.infinity,
          color: Colors.white,
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      p.displayPath,
                      style: const TextStyle(
                          fontSize: 19, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${p.followerCount} 人关注',
                      style: const TextStyle(fontSize: 14, color: kDimiGray66),
                    ),
                  ],
                ),
              ),
              // 关注按钮（可切换；主色实心 / 描边已关注）
              p.isFollowing
                  ? OutlinedButton(
                      onPressed: _followBusy ? null : _toggleFollow,
                      child: Text(_followBusy ? '处理中…' : '已关注'),
                    )
                  : FilledButton(
                      onPressed: _followBusy ? null : _toggleFollow,
                      child: Text(_followBusy ? '处理中…' : '+ 关注'),
                    ),
            ],
          ),
        ),
      ],
    );
  }

  /// 空封面兜底：浅雾杏底 + 镇名
  Widget _coverFallback(HometownPage p, {bool showName = true}) {
    return Container(
      decoration: const BoxDecoration(
        color: kDimiApricotSoft,
      ),
      alignment: Alignment.center,
      child: showName
          ? Text(
              p.townName,
              style: const TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.w700,
                color: kDimiApricotDeep,
              ),
            )
          : null,
    );
  }

  /// 简介区：超 3 行折叠，末尾「展开/收起」
  Widget _introSection(HometownPage p) {
    return Container(
      width: double.infinity,
      color: Colors.white,
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            p.intro,
            maxLines: _introExpanded ? null : 3,
            overflow:
                _introExpanded ? TextOverflow.visible : TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 16, height: 1.6),
          ),
          const SizedBox(height: 4),
          // 折叠开关触控区 ≥48dp
          SizedBox(
            height: 48,
            child: InkWell(
              onTap: () => setState(() => _introExpanded = !_introExpanded),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _introExpanded ? '收起' : '展开全文',
                    style: const TextStyle(fontSize: 15, color: kDimiPrimary),
                  ),
                  Icon(
                    _introExpanded
                        ? Icons.keyboard_arrow_up
                        : Icons.keyboard_arrow_down,
                    size: 18,
                    color: kDimiPrimary,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 分类 Tab：风光/特产/手艺/故事（选中态雾杏浅底 + 深雾杏字）
  Widget _categoryTabs() {
    return Container(
      color: Colors.white,
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Row(
        children: _categories.entries.map((e) {
          final selected = e.key == _category;
          return Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Material(
                color: selected ? kDimiApricotSoft : Colors.transparent,
                borderRadius: BorderRadius.circular(kDimiRadiusInput),
                child: InkWell(
                  borderRadius: BorderRadius.circular(kDimiRadiusInput),
                  onTap: () => _switchCategory(e.key),
                  child: SizedBox(
                    height: 48,
                    child: Center(
                      child: Text(
                        e.value,
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight:
                              selected ? FontWeight.w600 : FontWeight.w400,
                          color: selected ? kDimiApricotDeep : kDimiGray66,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  /// 内容列表区：骨架 / 错误 / 空态 / 卡片流（含 rolled_up 县页兜底）
  Widget _contentList() {
    if (_listLoading && _items.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: DimiListSkeleton(itemCount: 3),
      );
    }
    if (_listError != null && _items.isEmpty) {
      return SizedBox(
        height: 260,
        child: DimiErrorView(
          message: _listError!,
          onRetry: () => _loadContents(),
        ),
      );
    }
    if (_items.isEmpty && (!_rolledUp || _rollupItems.isEmpty)) {
      // rolled_up 但县页 TOP 也为空时同样回落空态（不留空白区）
      // 空态不再放「分享家乡」按钮：右下角常驻 FAB 已是同一动作，
      // 同屏两个相同 CTA 属冗余（「简约而不简单」）
      final canPost = _page?.canPost ?? false;
      return SizedBox(
        height: 320,
        child: DimiEmptyState(
          icon: Icons.landscape_outlined,
          title: '这个分类还没有内容',
          message: canPost ? '你是第一个为家乡上图的人' : '等老乡们来分享',
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 10),
          // 低密度兜底：镇页内容不足时提示并展示县页 TOP 内容
          if (_rolledUp && _rollupItems.isNotEmpty) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: kDimiApricotSoft,
                borderRadius: BorderRadius.circular(kDimiRadiusCard),
              ),
              child: const Row(
                children: [
                  Icon(Icons.info_outline, size: 16, color: kDimiApricotDeep),
                  SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '本镇内容还不多，先看看县里的',
                      style: TextStyle(fontSize: 14, color: kDimiApricotDeep),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
          ..._items.map(_contentCard),
          if (_rolledUp)
            ..._rollupItems.map((c) => _contentCard(c, rollup: true)),
          // 加载更多指示 / 到底提示
          if (_loadingMore)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: kDimiPrimary),
                ),
              ),
            )
          else if (_items.isNotEmpty && !_hasMore)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Center(
                child: Text('到底啦',
                    style: TextStyle(fontSize: 14, color: kDimiGrayBB)),
              ),
            ),
        ],
      ),
    );
  }

  /// 内容卡：首图（有图时 16:9 横幅）+ 标题 + 提供人 + 浏览/点赞。
  /// 分类标签仅「县里热传」rollup 条目保留（当前分类 Tab 已选定大类，
  /// 本镇卡片再标分类字属冗余，「简约而不简单」）；
  /// rollup 条目来自县页混合分类，需保留标签以区分
  Widget _contentCard(HometownContent c, {bool rollup = false}) {
    final cover = c.media.isEmpty ? null : c.media.first;
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
          onTap: () => _openDetail(c),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (cover != null)
                AspectRatio(
                    aspectRatio: 16 / 9,
                    child: CachedNetworkImage(
                        imageUrl: cover,
                        fit: BoxFit.cover,
                        memCacheWidth: 800,
                        placeholder: (_, __) =>
                            Container(color: kDimiApricotSoft),
                        errorWidget: (_, __, ___) => Container(
                            color: kDimiApricotSoft,
                            child: const Icon(Icons.landscape_outlined,
                                color: kDimiApricotDeep)))),
              Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (rollup) ...[
                        Wrap(spacing: 6, runSpacing: 4, children: [
                          _categoryChip(c.categoryLabel),
                          _categoryChip('县里热传')
                        ]),
                        const SizedBox(height: 8),
                      ],
                      Text(c.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 19,
                              height: 1.45,
                              fontWeight: FontWeight.w600,
                              color: kDimiText)),
                      if (c.body.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(c.body,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 17, height: 1.6, color: kDimiGray66)),
                      ],
                      const SizedBox(height: 8),
                      Row(children: [
                        Expanded(
                            child: InkWell(
                                onTap: c.author == null
                                    ? null
                                    : () => ProfileCardScreen.open(
                                        context, c.author!.userId),
                                borderRadius: BorderRadius.circular(8),
                                child: ConstrainedBox(
                                    constraints:
                                        const BoxConstraints(minHeight: 48),
                                    child: Row(children: [
                                      DimiAvatar(
                                          name: c.authorName,
                                          avatarUrl: c.author?.avatarUrl,
                                          seed: c.author?.userId,
                                          size: 20),
                                      const SizedBox(width: 6),
                                      Expanded(
                                          child: Text(c.authorName,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                  fontSize: 14,
                                                  color: kDimiGray99))),
                                    ])))),
                        const SizedBox(width: 12),
                        Icon(
                            c.liked
                                ? Icons.favorite_rounded
                                : Icons.favorite_border_rounded,
                            size: 14,
                            color: c.liked ? kDimiDanger : kDimiGray99),
                        const SizedBox(width: 4),
                        Text('${c.likeCount}',
                            style: const TextStyle(
                                fontSize: 14, color: kDimiGray99)),
                      ]),
                    ],
                  )),
            ],
          )),
    );
  }

  Widget _categoryChip(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: kDimiApricotSoft,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: const TextStyle(fontSize: 14, color: kDimiApricotDeep),
      ),
    );
  }

  /// 底部「老乡群」入口卡：雾杏色系，点击 join 后进聊天页
  Widget _groupEntry(HometownPage p) {
    final g = p.group!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
      child: Material(
        color: kDimiApricotSoft,
        borderRadius: BorderRadius.circular(kDimiRadiusCard),
        child: InkWell(
          borderRadius: BorderRadius.circular(kDimiRadiusCard),
          onTap: _openGroup,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: const Icon(Icons.groups_outlined,
                      color: kDimiApricotDeep, size: 22),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        g.title ?? '老乡群',
                        style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                            color: kDimiText),
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (g.memberCount != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          '${g.memberCount} 位群成员',
                          style:
                              const TextStyle(fontSize: 14, color: kDimiGray66),
                        ),
                      ],
                    ],
                  ),
                ),
                if (_joiningGroup)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: kDimiApricotDeep),
                  )
                else
                  const Icon(Icons.chevron_right,
                      color: kDimiApricotDeep, size: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 页面常驻免责声明（设计 §15：不碰交易红线）
  Widget _disclaimer() {
    return const Padding(
      padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Text(
        '本页内容为老乡自发分享的信息展示。平台不提供任何交易服务，不涉及价格与支付。'
        '如据此进行线下交易，请自行核实对方身份与商品情况，谨防诈骗。',
        style: TextStyle(fontSize: 14, color: kDimiGrayBB, height: 1.5),
      ),
    );
  }
}
