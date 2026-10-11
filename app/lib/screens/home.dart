/// 主框架：底部四个主 tab（消息 / 城外 / 发现 / 我，对齐原型tabbar）。
/// 本文件包含 MainShell、城外首页 HomeTab、「我」MeTab；
/// 消息 tab 由 conversations.dart 的 ConversationsView 承载，
/// 发现 tab 由 discover.dart 的 DiscoverScreen（发现聚合页）承载。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../state/session.dart';
import '../widgets/common/dimi_error_view.dart';
import '../widgets/common/dimi_section.dart';
import '../widgets/common/dimi_skeleton.dart';
import '../widgets/dimi_avatar.dart';
import '../widgets/person_tile.dart';
import '../widgets/slider_captcha.dart';
import 'conversations.dart';
import 'about.dart';
import 'chat.dart';
import 'devices.dart';
import 'discover.dart';
import 'educations.dart';
import 'feedback.dart';
import 'fellow.dart';
import 'friends.dart';
import 'friend_apply.dart';
import 'invite.dart';
import 'login.dart';
import 'my_qrcode.dart';
import 'onboarding_education.dart';
import 'privacy.dart';
import 'profile_card.dart';
import 'profile_edit.dart';
import 'search.dart';
import 'wallet.dart';
import '../theme.dart';
import '../widgets/common/dimi_dialog.dart';

class MainShell extends StatefulWidget {
  const MainShell({super.key});

  static const routeName = '/home';

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _index = 1; // 默认落在「城外」（V0.9 主链路起点）

  /// 发现 tab 红点：我的动态有新点赞/评论（与发现页共用同一接口轮询）
  bool _momentsUnread = false;

  @override
  void initState() {
    super.initState();
    _refreshMomentsUnread();
  }

  /// 切换 tab 时顺带刷新一次红点；失败静默
  Future<void> _refreshMomentsUnread() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final since = prefs.getInt(kMomentsLastSeenKey) ?? 0;
      if (!mounted) return;
      final hasNew =
          await context.read<DimiApi>().momentsInteractionsUnread(since);
      if (mounted && hasNew != _momentsUnread) {
        setState(() => _momentsUnread = hasNew);
      }
    } on ApiException {
      // 未登录或接口未就绪时忽略
    }
  }

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      ConversationsView(onGoOut: () => setState(() => _index = 1)),
      HomeTab(active: _index == 1),
      const DiscoverScreen(),
      const MeTab(),
    ];
    return Scaffold(
      body: IndexedStack(index: _index, children: pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) {
          setState(() => _index = i);
          _refreshMomentsUnread();
        },
        destinations: [
          const NavigationDestination(
              icon: Icon(Icons.forum_outlined),
              selectedIcon: Icon(Icons.forum_rounded),
              label: '消息'),
          const NavigationDestination(
              icon: Icon(Icons.group_outlined),
              selectedIcon: Icon(Icons.group_rounded),
              label: '城外'),
          NavigationDestination(
              icon: Badge(
                isLabelVisible: _momentsUnread,
                smallSize: 8,
                backgroundColor: kDimiDanger,
                child: const Icon(Icons.explore_outlined),
              ),
              selectedIcon: Badge(
                isLabelVisible: _momentsUnread,
                smallSize: 8,
                backgroundColor: kDimiDanger,
                child: const Icon(Icons.explore_rounded),
              ),
              label: '发现'),
          const NavigationDestination(
              icon: Icon(Icons.person_outline_rounded),
              selectedIcon: Icon(Icons.person_rounded),
              label: '我'),
        ],
      ),
    );
  }
}

/// 城外首页（原型屏①）：找同学/找老乡两大入口卡 + 我的班级单元卡 + 我的老乡群 + 推荐好友。
class HomeTab extends StatefulWidget {
  const HomeTab({super.key, this.active = true});
  final bool active;

  @override
  State<HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends State<HomeTab> {
  int _loadVersion = 0;
  bool _loading = true;
  String? _error;
  List<Education> _educations = [];
  final Map<int, String> _unitCounts = {}; // educationId → total_masked
  final Set<int> _failedUnitCounts = {};
  List<UserBrief> _recommendations = [];
  List<ClassGroupUnit> _classGroupUnits = [];
  bool _joiningGroup = false;
  List<HometownGroupUnit> _hometownGroupUnits = [];
  bool _hometownGroupsLoaded = false;
  bool _hometownGroupsFailed = false;
  bool _joiningHometownGroup = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant HomeTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    final version = ++_loadVersion;
    setState(() {
      _loading = true;
      _error = null;
      _failedUnitCounts.clear();
    });
    final api = context.read<DimiApi>();
    _refreshRecommendations(version);
    _refreshClassGroups();
    _refreshHometownGroups();
    try {
      final edus = await api.myEducations();
      if (!mounted || version != _loadVersion) return;
      setState(() {
        _educations = edus;
        _loading = false;
      });
      // 单元计数并行补齐，不让一个慢接口阻塞整个首页。
      for (final e in edus) {
        if (e.id == null) continue;
        _refreshUnitCount(e.id!, version);
      }
    } on ApiException catch (e) {
      if (!mounted || version != _loadVersion) return;
      setState(() => _error = e.message);
    } finally {
      if (mounted && version == _loadVersion) setState(() => _loading = false);
    }
  }

  Future<void> _refreshRecommendations(int version) async {
    try {
      final result = await context.read<DimiApi>().recommendations();
      if (!mounted || version != _loadVersion) return;
      setState(() => _recommendations = result.items);
    } on ApiException {
      if (mounted && version == _loadVersion) {
        setState(() => _recommendations = []);
      }
    }
  }

  Future<void> _refreshUnitCount(int id, int version) async {
    try {
      final result = await context.read<DimiApi>().myClassmates(id);
      if (!mounted || version != _loadVersion) return;
      setState(() =>
          _unitCounts[id] = result.totalMasked ?? '${result.items.length}');
    } on ApiException {
      // 单张卡片计数不可用时，保留其他入口。
      if (mounted && version == _loadVersion) {
        setState(() => _failedUnitCounts.add(id));
      }
    }
  }

  /// 班级群单元列表（GET /class-groups/mine），失败静默不阻塞主页
  Future<void> _refreshClassGroups() async {
    if (!mounted) return;
    final version = _loadVersion;
    try {
      final units = await context.read<DimiApi>().myClassGroups();
      if (!mounted || version != _loadVersion) return;
      setState(() => _classGroupUnits = units);
    } on ApiException {
      // 班级群加载失败静默
    }
  }

  /// 老乡群单元列表（GET /hometown-groups/mine，0 或 1 条），失败静默不阻塞主页；
  /// 空列表视为未设家乡，展示「设置家乡」提示卡
  Future<void> _refreshHometownGroups() async {
    if (!mounted) return;
    final version = _loadVersion;
    setState(() => _hometownGroupsFailed = false);
    try {
      final units = await context.read<DimiApi>().myHometownGroups();
      if (!mounted || version != _loadVersion) return;
      setState(() {
        _hometownGroupUnits = units;
        _hometownGroupsLoaded = true;
      });
    } on ApiException {
      if (mounted && version == _loadVersion) {
        setState(() => _hometownGroupsFailed = true);
      }
    }
  }

  /// 按三元组（学校+入学年+班级）匹配教育经历对应的班级群单元
  ClassGroupUnit? _groupUnitFor(Education e) {
    for (final u in _classGroupUnits) {
      if (u.schoolId == e.schoolId &&
          u.enrollYear == e.enrollYear &&
          (u.className == e.classNameRaw || u.className == e.classNameNorm)) {
        return u;
      }
    }
    return null;
  }

  /// 点击班级群入口：未加入（含群未建）先 join（未建自动建群），再进聊天页
  Future<void> _openClassGroup(ClassGroupUnit unit) async {
    if (_joiningGroup) return;
    final api = context.read<DimiApi>();
    var g = unit.group;
    try {
      if (g == null || !g.joined) {
        setState(() => _joiningGroup = true);
        g = await api.joinClassGroup(
          schoolId: unit.schoolId,
          enrollYear: unit.enrollYear,
          className: unit.className,
        );
      }
      if (!mounted) return;
      // convId 是进聊天页的必需字段，接口缺失时 fromJson 兜底 0，视为异常不进页
      final group = g;
      if (group.convId <= 0) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('班级群信息异常，请稍后重试')));
        return;
      }
      await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => ChatScreen(
          conversation: Conversation(
            convId: group.convId,
            convType: 'group',
            groupKind: 'class',
            title: group.title ?? '班级群',
            memberCount: group.memberCount,
          ),
        ),
      ));
      _refreshClassGroups();
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    } finally {
      if (mounted) setState(() => _joiningGroup = false);
    }
  }

  /// 点击老乡群入口：未加入（含群未建）先 join（未建自动建群），再进聊天页。
  /// 聊天页走通用会话（chat.dart），群资料页走通用群管理页（group_info.dart）。
  Future<void> _openHometownGroup(HometownGroupUnit unit) async {
    if (_joiningHometownGroup) return;
    final api = context.read<DimiApi>();
    var g = unit.group;
    try {
      if (g == null || !g.joined) {
        setState(() => _joiningHometownGroup = true);
        g = await api.joinHometownGroup();
      }
      if (!mounted) return;
      // convId 是进聊天页的必需字段，接口缺失时 fromJson 兜底 0，视为异常不进页
      final group = g;
      if (group.convId <= 0) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('老乡群信息异常，请稍后重试')));
        return;
      }
      await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => ChatScreen(
          conversation: Conversation(
            convId: group.convId,
            convType: 'group',
            groupKind: 'hometown',
            title: group.title ?? '老乡群',
            memberCount: group.memberCount,
          ),
        ),
      ));
      _refreshHometownGroups();
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    } finally {
      if (mounted) setState(() => _joiningHometownGroup = false);
    }
  }

  void _openProfile(UserBrief user) {
    ProfileCardScreen.open(context, user.userId).then((_) => _load());
  }

  /// 推荐负反馈：长按卡片 →「不感兴趣」→ /discover/feedback + 本地移除
  Future<void> _showRecommendActions(UserBrief u) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading:
                  const Icon(Icons.not_interested_outlined, color: kDimiDanger),
              title: const Text('不感兴趣'),
              subtitle: const Text('不再向你推荐 TA', style: TextStyle(fontSize: 14)),
              onTap: () => Navigator.pop(ctx, 'not_interested'),
            ),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    try {
      await context
          .read<DimiApi>()
          .discoverFeedback(targetUserId: u.userId, action: action);
      if (!mounted) return;
      setState(() => _recommendations.removeWhere((x) => x.userId == u.userId));
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kDimiBg,
      appBar: AppBar(title: const Text('城外')),
      body: RefreshIndicator(
        color: kDimiPrimary,
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          children: [
            // 两大入口卡
            Row(
              children: [
                Expanded(
                  child: _entryCard(
                    icon: Icons.school_outlined,
                    title: '找同学',
                    subtitle: '小学·中学·高中·大学',
                    onTap: () =>
                        Navigator.of(context).push(MaterialPageRoute<void>(
                      builder: (_) => const SearchScreen(),
                    )),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _entryCard(
                    icon: Icons.cottage_outlined,
                    title: '找老乡',
                    subtitle: '省·市·区·镇',
                    onTap: () => Navigator.of(context)
                        .push(MaterialPageRoute<void>(
                          builder: (_) => const FellowScreen(),
                        ))
                        .then((_) => _load()),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (_loading)
              // 首屏骨架屏，替代转圈加载
              const DimiListSkeleton(itemCount: 4)
            else if (_error != null)
              DimiErrorView(message: _error!, onRetry: _load)
            else ...[
              // 我的班级单元卡
              if (_educations.isEmpty)
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.edit_note, color: kDimiPrimary),
                    title:
                        const Text('还没有填写教育经历', style: TextStyle(fontSize: 16)),
                    subtitle: const Text('填了学校，才能帮你找到老同学',
                        style: TextStyle(fontSize: 14)),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () =>
                        Navigator.of(context).push(MaterialPageRoute<void>(
                      builder: (_) => const OnboardingEducationScreen(),
                    )),
                  ),
                )
              else
                ..._educations.map(_unitCard),
              // 我的老乡群（家乡同市聚合，与老乡圈同边界）；
              // 未设家乡（接口返回空）时展示「设置家乡」提示卡
              if (_hometownGroupsFailed)
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.refresh),
                    title: const Text('老乡群暂时未能加载'),
                    subtitle: const Text('点击重试'),
                    onTap: _refreshHometownGroups,
                  ),
                )
              else if (_hometownGroupsLoaded && _hometownGroupUnits.isEmpty)
                _hometownGroupPlaceholder()
              else
                ..._hometownGroupUnits.map(_hometownGroupCard),
              // 推荐好友
              if (_recommendations.isNotEmpty)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('推荐好友',
                            style: TextStyle(fontWeight: FontWeight.w600)),
                        const SizedBox(height: 4),
                        // 行间发丝分隔线（缩进对齐文字起点，避开头像）
                        for (var i = 0; i < _recommendations.length; i++) ...[
                          if (i > 0)
                            const Divider(
                                height: 1, indent: 54, color: kDimiHairline),
                          PersonTile(
                            user: _recommendations[i],
                            onTap: () => _openProfile(_recommendations[i]),
                            onLongPress: () =>
                                _showRecommendActions(_recommendations[i]),
                            actionLabel: '加好友',
                            onAction: () => Navigator.of(context)
                                .push(
                                  MaterialPageRoute<void>(
                                    builder: (_) => FriendApplyScreen(
                                        target: _recommendations[i]),
                                  ),
                                )
                                .then((_) => _load()),
                            // 长按「不感兴趣」的显性入口（长按保留为快捷方式）
                            trailing: IconButton(
                              icon: const Icon(Icons.more_horiz,
                                  color: kDimiGray99),
                              tooltip: '推荐设置',
                              onPressed: () =>
                                  _showRecommendActions(_recommendations[i]),
                            ),
                          ),
                        ],
                        const Divider(height: 20),
                        GestureDetector(
                          onTap: _educations.isEmpty
                              ? null
                              : () => Navigator.of(context).push(
                                    MaterialPageRoute<void>(
                                      builder: (_) => InviteScreen(
                                          education: _educations.first),
                                    ),
                                  ),
                          child: const Text(
                            '同班未点亮的名字等你去点亮 · 发起班级召集令 →',
                            style: TextStyle(fontSize: 14, color: kDimiPrimary),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _entryCard({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 18),
          child: Column(
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: const BoxDecoration(
                  color: kDimiPrimarySoft,
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, size: 26, color: kDimiPrimary),
              ),
              const SizedBox(height: 10),
              Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(subtitle,
                  style: const TextStyle(fontSize: 14, color: kDimiGray66)),
            ],
          ),
        ),
      ),
    );
  }

  /// 班级单元卡（一卡一条信息）：标题行（学校·届·班，点击去找同学点亮名录）
  /// + 同班数据行 + 群入口行（卡内整行可点，发丝线分隔）。
  /// 旧版为「单元卡 + 外挂色块入口」两段式，用户反馈像 2 行 tab 框，
  /// 重构为单卡三行层次：标题 → 数据 → 群入口，不嵌套多层容器。
  Widget _unitCard(Education e) {
    final count = e.id != null ? _unitCounts[e.id!] : null;
    final unit = _groupUnitFor(e);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          InkWell(
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => SearchScreen(initialEducation: e),
            )),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  const Icon(Icons.school, color: kDimiPrimary, size: 26),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(e.displayLine,
                            style:
                                const TextStyle(fontWeight: FontWeight.w600)),
                        const SizedBox(height: 3),
                        Text(
                          count != null
                              ? '同班 $count 人已归队'
                              : _failedUnitCounts.contains(e.id)
                                  ? '点击查看同班名录'
                                  : '同班名录加载中…',
                          style:
                              const TextStyle(fontSize: 14, color: kDimiGray99),
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right, color: kDimiGrayCC),
                ],
              ),
            ),
          ),
          if (unit != null) ...[
            const Divider(
                height: 1, indent: 14, endIndent: 14, color: kDimiHairline),
            _classGroupRow(unit),
          ],
        ],
      ),
    );
  }

  /// 班级群入口行（卡内整行可点区块）：
  /// 群图标 + 群名 + 成员数 + 未读徽标 + 箭头；未加入（含群未建）先 join 再进聊天页
  Widget _classGroupRow(ClassGroupUnit unit) {
    return InkWell(
      onTap: () => _openClassGroup(unit),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: const BoxDecoration(
                color: kDimiPrimarySoft,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: const Icon(Icons.groups_outlined,
                  color: kDimiPrimary, size: 20),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    unit.group == null ? '创建班级群' : (unit.group!.title ?? '班级群'),
                    style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: kDimiText),
                    overflow: TextOverflow.ellipsis,
                  ),
                  // 成员数字段缺失（null）时省略该行
                  if (unit.group != null &&
                      unit.group!.memberCount != null) ...[
                    const SizedBox(height: 2),
                    Text('${unit.group!.memberCount} 位群成员',
                        style:
                            const TextStyle(fontSize: 14, color: kDimiGray66)),
                  ],
                ],
              ),
            ),
            if (unit.group != null && unit.group!.unreadCount > 0) ...[
              const SizedBox(width: 6),
              Badge(
                label: Text('${unit.group!.unreadCount}'),
                backgroundColor: kDimiBadge,
              ),
            ],
            const SizedBox(width: 4),
            if (_joiningGroup)
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: kDimiPrimary),
              )
            else
              const Icon(Icons.chevron_right, color: kDimiPrimary, size: 20),
          ],
        ),
      ),
    );
  }

  /// 未设家乡时的提示卡：点击跳找老乡页（内含四级联动设置家乡流程）
  Widget _hometownGroupPlaceholder() {
    return Card(
      child: ListTile(
        leading: const Icon(Icons.cottage_outlined, color: kDimiApricotDeep),
        title: const Text('设置家乡，找到你的老乡群 →', style: TextStyle(fontSize: 16)),
        subtitle: const Text('同市老乡的群聊，免好友也能畅聊', style: TextStyle(fontSize: 14)),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.of(context)
            .push(MaterialPageRoute<void>(
              builder: (_) => const FellowScreen(),
            ))
            .then((_) => _load()),
      ),
    );
  }

  /// 老乡群单元卡（一卡一条信息，对齐 _unitCard 结构）：标题行
  ///（region_name +「老乡群」，点击进找老乡页）+ 群入口行（卡内整行可点，发丝线分隔）
  Widget _hometownGroupCard(HometownGroupUnit unit) {
    final name = (unit.regionName != null && unit.regionName!.isNotEmpty)
        ? unit.regionName!
        : '我的家乡';
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          InkWell(
            onTap: () => Navigator.of(context)
                .push(MaterialPageRoute<void>(
                  builder: (_) => const FellowScreen(),
                ))
                .then((_) => _load()),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: const BoxDecoration(
                      color: kDimiApricotSoft,
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: const Icon(Icons.cottage_outlined,
                        color: kDimiApricotDeep, size: 22),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('$name 老乡群',
                            style:
                                const TextStyle(fontWeight: FontWeight.w600)),
                        const SizedBox(height: 3),
                        const Text('同市老乡 · 免好友也能畅聊',
                            style: TextStyle(fontSize: 14, color: kDimiGray99)),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right, color: kDimiGrayCC),
                ],
              ),
            ),
          ),
          const Divider(
              height: 1, indent: 14, endIndent: 14, color: kDimiHairline),
          _hometownGroupRow(unit),
        ],
      ),
    );
  }

  /// 老乡群入口行（卡内整行可点区块，雾杏色系对齐 _classGroupRow）：
  /// 群图标 + 群名 + 成员数 + 未读徽标 + 箭头；未加入（含群未建）先 join 再进聊天页
  Widget _hometownGroupRow(HometownGroupUnit unit) {
    return InkWell(
      onTap: () => _openHometownGroup(unit),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: const BoxDecoration(
                color: kDimiApricotSoft,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: const Icon(Icons.groups_outlined,
                  color: kDimiApricotDeep, size: 20),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    unit.group == null ? '加入老乡群' : (unit.group!.title ?? '老乡群'),
                    style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: kDimiText),
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (unit.group != null &&
                      unit.group!.memberCount != null) ...[
                    const SizedBox(height: 2),
                    Text('${unit.group!.memberCount} 位群成员',
                        style:
                            const TextStyle(fontSize: 14, color: kDimiGray66)),
                  ],
                ],
              ),
            ),
            if (unit.group != null && unit.group!.unreadCount > 0) ...[
              const SizedBox(width: 6),
              Badge(
                label: Text('${unit.group!.unreadCount}'),
                backgroundColor: kDimiBadge,
              ),
            ],
            const SizedBox(width: 4),
            if (_joiningHometownGroup)
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
    );
  }
}

/// 「我」tab：账号信息 + 隐私设置 / 召集令 / 退出登录入口。
class MeTab extends StatelessWidget {
  const MeTab({super.key});

  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    final me = session.currentUser;
    return Scaffold(
      backgroundColor: kDimiBg,
      appBar: AppBar(title: const Text('我')),
      body: ListView(
        children: [
          // 资料头：点击进入资料编辑
          Card(
            margin: const EdgeInsets.all(12),
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => const ProfileEditScreen(),
              )),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    DimiAvatar(
                      name: me?.nickname,
                      avatarUrl: me?.avatarUrl,
                      size: 56,
                      seed: me?.userId,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(me?.nickname ?? '未登录',
                              style: const TextStyle(
                                  fontSize: 19, fontWeight: FontWeight.w600)),
                          // DIMI号/信用分不外显（内部标识与信任分）；
                          // DIMI号在资料编辑页保留可查看复制（唯一用途=精确找人）
                        ],
                      ),
                    ),
                    // 我的二维码入口（对齐微信：资料头右侧小图标）
                    IconButton(
                      icon: const Icon(Icons.qr_code_2, color: kDimiGray99),
                      tooltip: '我的二维码',
                      onPressed: () =>
                          Navigator.of(context).push(MaterialPageRoute<void>(
                        builder: (_) => const MyQrcodeScreen(),
                      )),
                    ),
                    const Icon(Icons.chevron_right, color: kDimiGray99),
                  ],
                ),
              ),
            ),
          ),
          // 入口按语义分组（微信式整块白底 + 组内发丝分隔线）：
          // 社交与资产 / 账号与服务 / 隐私与安全 / 召集 / 显示 / 其他
          DimiSection(
            children: [
              _entry(
                icon: Icons.people_alt_outlined,
                title: '我的好友',
                onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => const FriendsScreen(),
                )),
              ),
              _entry(
                icon: Icons.school_outlined,
                title: '我的教育经历',
                onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => const EducationsScreen(),
                )),
              ),
              _entry(
                icon: Icons.savings_outlined,
                title: '觅豆钱包',
                onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => const WalletScreen(),
                )),
              ),
            ],
          ),
          DimiSection(
            children: [
              _entry(
                icon: Icons.lock_outline,
                title: '登录密码',
                onTap: () => _setLoginPassword(context),
              ),
              _entry(
                icon: Icons.help_outline,
                title: '帮助与反馈',
                onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => const FeedbackScreen(),
                )),
              ),
            ],
          ),
          DimiSection(
            children: [
              _entry(
                icon: Icons.no_accounts_outlined,
                title: '注销账号',
                // 关键政策信息（后果提示）保留副标题
                subtitle: '7 天冷静期，期内登录可撤销',
                onTap: () => _deactivate(context),
              ),
              _entry(
                icon: Icons.privacy_tip_outlined,
                title: '隐私设置',
                onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => const PrivacyScreen(),
                )),
              ),
              _entry(
                icon: Icons.devices_outlined,
                title: '登录设备管理',
                onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => const DevicesScreen(),
                )),
              ),
            ],
          ),
          DimiSection(
            children: [
              _entry(
                icon: Icons.campaign_outlined,
                title: '邀请老同学',
                onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => const InviteScreen(),
                )),
              ),
            ],
          ),
          // 关怀模式（适老化）：全局字号放大，设备级偏好即时生效
          DimiSection(
            dividerIndent: 16,
            children: [
              SwitchListTile(
                secondary:
                    const Icon(Icons.accessible_forward, color: kDimiPrimary),
                title: const Text('关怀模式', style: TextStyle(fontSize: 17)),
                subtitle:
                    const Text('字号更大，方便阅读', style: TextStyle(fontSize: 14)),
                value: session.careMode,
                activeThumbColor: kDimiPrimary,
                onChanged: (v) => session.setCareMode(v),
              ),
            ],
          ),
          DimiSection(
            children: [
              _entry(
                icon: Icons.info_outline,
                title: '关于 DIMI',
                onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => const AboutScreen(),
                )),
              ),
              _entry(
                icon: Icons.logout,
                title: '退出登录',
                onTap: () async {
                  try {
                    await context.read<DimiApi>().logout();
                  } on ApiException {
                    // 退出接口失败不阻塞本地登出
                  }
                  if (!context.mounted) return;
                  await context.read<Session>().clear();
                  if (!context.mounted) return;
                  Navigator.of(context).pushAndRemoveUntil(
                    MaterialPageRoute<void>(
                        builder: (_) => const LoginScreen()),
                    (route) => false,
                  );
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _entry({
    required IconData icon,
    required String title,
    String? subtitle,
    required VoidCallback onTap,
  }) {
    return DimiSectionItem(
      icon: icon,
      title: title,
      subtitle: subtitle,
      onTap: onTap,
    );
  }

  // 设置/修改登录密码（POST /auth/password）：输入新密码+确认 →
  // 获取短信验证码（60s 倒计时，42901 时滑块兜底）→ 提交。
  Future<void> _setLoginPassword(BuildContext context) async {
    final ok = await showDimiDialog<bool>(
      context: context,
      builder: (_) => const _SetPasswordDialog(),
    );
    if (ok == true && context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('密码已设置')));
    }
  }

  // 注销账号（PIPL 注销权）：输入完整手机号 → 短信二次验证 → 7 天冷静期
  Future<void> _deactivate(BuildContext context) async {
    final api = context.read<DimiApi>();
    final session = context.read<Session>();
    final step1 = await showDimiDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('注销账号 (1/3)'),
        content: const Text(
            '注销后账号进入 7 天冷静期：期内登录即撤销注销，逾期不可恢复。\n\n确认后继续，需要输入注册手机号并完成短信验证。\n\n（共 3 步，每一步都可以取消）'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('再想想')),
          FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: kDimiDangerSoft,
                  foregroundColor: kDimiDanger),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('继续注销')),
        ],
      ),
    );
    if (step1 != true || !context.mounted) return;

    // 手机号在客户端只持有掩码值（隐私设计），注销须本人输入完整号码
    final phoneCtrl = TextEditingController();
    final phone = await showDimiDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('注销账号 (2/3)'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('请输入完整注册手机号（随时可以取消）',
                style: TextStyle(fontSize: 15, color: kDimiGray66)),
            const SizedBox(height: 10),
            TextField(
              controller: phoneCtrl,
              keyboardType: TextInputType.phone,
              maxLength: 11,
              decoration: const InputDecoration(hintText: '请输入 11 位注册手机号'),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, phoneCtrl.text.trim()),
              child: const Text('发送验证码')),
        ],
      ),
    );
    phoneCtrl.dispose();
    if (phone == null || !RegExp(r'^1[3-9]\d{9}$').hasMatch(phone)) return;
    if (!context.mounted) return;
    try {
      await sendSmsWithCaptcha(context, phone, scene: 'deactivate');
    } on ApiException catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
      return;
    }
    if (!context.mounted) return;
    final codeCtrl = TextEditingController();
    final code = await showDimiDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('注销账号 (3/3)'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('验证码已发送到注册手机号，输入后确认注销（随时可以取消）',
                style: TextStyle(fontSize: 15, color: kDimiGray66)),
            const SizedBox(height: 10),
            TextField(
              controller: codeCtrl,
              keyboardType: TextInputType.number,
              maxLength: 6,
              decoration: const InputDecoration(hintText: '6 位短信验证码'),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, codeCtrl.text.trim()),
              child: const Text('确认注销')),
        ],
      ),
    );
    codeCtrl.dispose();
    if (code == null || code.isEmpty || !context.mounted) return;
    try {
      await api.deactivateAccount(code);
    } on ApiException catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
      return;
    }
    if (!context.mounted) return;
    await session.clear();
    if (!context.mounted) return;
    // 先提示再跳转：pushAndRemoveUntil 后本 context 已失效，无法再弹 SnackBar
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('账号已进入 7 天冷静期，期内登录可撤销')));
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute<void>(builder: (_) => const LoginScreen()),
      (route) => false,
    );
  }
}

/// 设置/修改登录密码对话框（POST /auth/password）：
/// 注册手机号 + 新密码/确认 + 短信验证码（60s 倒计时，42901 滑块兜底）→ 提交。
/// 手机号在客户端只持有掩码值（隐私设计），须本人输入完整号码发码。
class _SetPasswordDialog extends StatefulWidget {
  const _SetPasswordDialog();

  @override
  State<_SetPasswordDialog> createState() => _SetPasswordDialogState();
}

class _SetPasswordDialogState extends State<_SetPasswordDialog> {
  final _phoneCtrl = TextEditingController();
  final _pwCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  bool _sending = false;
  bool _submitting = false;
  int _countdown = 0;
  Timer? _timer;

  static final _phoneReg = RegExp(r'^1[3-9]\d{9}$');

  @override
  void dispose() {
    _timer?.cancel();
    _phoneCtrl.dispose();
    _pwCtrl.dispose();
    _confirmCtrl.dispose();
    _codeCtrl.dispose();
    super.dispose();
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  void _startCountdown() {
    setState(() => _countdown = 60);
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() {
        _countdown--;
        if (_countdown <= 0) t.cancel();
      });
    });
  }

  Future<void> _sendCode() async {
    final phone = _phoneCtrl.text.trim();
    if (!_phoneReg.hasMatch(phone)) {
      _toast('请输入正确的注册手机号');
      return;
    }
    setState(() => _sending = true);
    try {
      final sent =
          await sendSmsWithCaptcha(context, phone, scene: 'set_password');
      if (!sent || !mounted) return;
      _toast('验证码已发送');
      _startCountdown();
    } on ApiException catch (e) {
      if (!mounted) return;
      _toast(e.message);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _submit() async {
    final pw = _pwCtrl.text;
    if (pw.length < 8 || pw.length > 64) {
      _toast('密码须 8–64 位');
      return;
    }
    if (pw != _confirmCtrl.text) {
      _toast('两次输入的密码不一致');
      return;
    }
    final code = _codeCtrl.text.trim();
    if (code.length < 4) {
      _toast('请输入短信验证码');
      return;
    }
    setState(() => _submitting = true);
    try {
      await context.read<DimiApi>().setPassword(newPassword: pw, smsCode: code);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (!mounted) return;
      _toast(e.message);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('设置/修改登录密码', style: TextStyle(fontSize: 18)),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _phoneCtrl,
              keyboardType: TextInputType.phone,
              maxLength: 11,
              decoration: const InputDecoration(
                hintText: '注册手机号（验证码发到该号码）',
                counterText: '',
                isDense: true,
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _pwCtrl,
              obscureText: true,
              decoration: const InputDecoration(
                hintText: '新密码（8–64 位）',
                isDense: true,
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _confirmCtrl,
              obscureText: true,
              decoration: const InputDecoration(
                hintText: '确认新密码',
                isDense: true,
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _codeCtrl,
                    keyboardType: TextInputType.number,
                    maxLength: 6,
                    decoration: const InputDecoration(
                      hintText: '6 位短信验证码',
                      counterText: '',
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: (_countdown > 0 || _sending) ? null : _sendCode,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: kDimiPrimary,
                    side: BorderSide.none,
                  ),
                  child: Text(
                    _countdown > 0 ? '${_countdown}s' : '获取验证码',
                    style: const TextStyle(fontSize: 14),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: kDimiPrimaryFill),
          onPressed: _submitting ? null : _submit,
          child: Text(_submitting ? '提交中…' : '确定'),
        ),
      ],
    );
  }
}
