/// 用户资料卡（原型屏③）：头像/昵称/real_name（服务端渐显判定后的展示值，
/// 可能为掩码，客户端不得二次加工）+ 交集横幅（含「未验证」限定句情形）
/// + 教育经历 + 底部操作按钮（按 UserCard.relation 渲染：
/// 好友→发消息 / pending_out→等待验证 / pending_in→通过好友验证 / 其他→加好友）。
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../state/session.dart';
import '../widgets/common/dimi_error_view.dart';
import '../widgets/common/dimi_skeleton.dart';
import '../widgets/dimi_avatar.dart';
import '../widgets/group_unlock.dart';
import '../widgets/intersection_banner.dart';
import '../widgets/masked_name.dart';
import '../widgets/report_dialog.dart';
import '../widgets/verify_badge.dart';
import 'chat.dart';
import 'friend_apply.dart';
import 'friend_requests.dart';
import 'hometown_page.dart';
import 'user_moments.dart';
import '../theme.dart';

class ProfileCardScreen extends StatefulWidget {
  const ProfileCardScreen({super.key, required this.userId});

  final int userId;

  /// 最近一次打开时间（300ms 连点防抖用）
  static DateTime? _lastOpenAt;

  /// 统一进入入口：300ms 内的连点只生效一次。
  /// 各列表页（找同学/找老乡/推荐等）跳转资料卡请走这里。
  static Future<void> open(BuildContext context, int userId) async {
    final now = DateTime.now();
    final last = _lastOpenAt;
    if (last != null && now.difference(last).inMilliseconds < 300) return;
    _lastOpenAt = now;
    await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => ProfileCardScreen(userId: userId)));
  }

  @override
  State<ProfileCardScreen> createState() => _ProfileCardScreenState();
}

class _ProfileCardScreenState extends State<ProfileCardScreen>
    with GroupUnlockAware<ProfileCardScreen> {
  int _loadVersion = 0;

  @override
  void onGroupLocked() {
    setState(() {
      _card = null;
    });
    _load();
  }

  UserCard? _card;
  bool _loading = true;
  String? _error;
  bool _privacyBlocked = false;
  bool _groupLocked = false;
  bool _openingChat = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    final version = ++_loadVersion;
    final unlockToken = context.read<Session>().groupUnlockToken;
    setState(() {
      _loading = true;
      _error = null;
      _privacyBlocked = false;
      _groupLocked = false;
    });
    try {
      final card = await context
          .read<DimiApi>()
          .userCard(widget.userId, unlockToken: unlockToken);
      if (!mounted || version != _loadVersion) return;
      setState(() => _card = card);
    } on ApiException catch (e) {
      if (!mounted || version != _loadVersion) return;
      setState(() {
        _error = e.message;
        _groupLocked = e.isGroupLocked;
        _privacyBlocked =
            e.code == ApiException.privacyBlocked && !e.isGroupLocked;
      });
    } finally {
      if (mounted && version == _loadVersion) setState(() => _loading = false);
    }
  }

  Future<void> _unlockAndReload() async {
    final ok = await showGroupUnlockDialog(context);
    if (ok && mounted) _load();
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// 「发消息」：打开（或复用）与该用户的单聊会话
  Future<void> _openChat(int toUserId) async {
    if (_openingChat) return;
    setState(() => _openingChat = true);
    try {
      final conv = await context.read<DimiApi>().createConversation(toUserId);
      if (!mounted) return;
      Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => ChatScreen(conversation: conv),
      ));
    } on ApiException catch (e) {
      _toast(e.message);
    } finally {
      if (mounted) setState(() => _openingChat = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isSelf = context.read<Session>().currentUser?.userId == widget.userId;
    return Scaffold(
      backgroundColor: kDimiBg,
      appBar: AppBar(
        title: const Text('详细资料'),
        actions: [
          if (!isSelf && _card != null)
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert),
              onSelected: (v) {
                if (v == 'report') {
                  showReportDialog(context,
                      targetType: 'user', targetId: widget.userId);
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'report', child: Text('举报')),
              ],
            ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return ListView(
        padding: const EdgeInsets.all(12),
        children: const [
          DimiSkeleton(height: 210, radius: kDimiRadiusCard),
          SizedBox(height: 10),
          DimiSkeleton(height: 110, radius: kDimiRadiusCard),
          SizedBox(height: 10),
          DimiSkeleton(height: 64, radius: kDimiRadiusCard),
        ],
      );
    }
    if (_error != null) {
      // 高隐私分组门禁：锁图标 + 解锁入口（区别于普通隐私拦截）
      if (_groupLocked) {
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.lock_outline, size: 48, color: kDimiApricotDeep),
              const SizedBox(height: 12),
              const Text('该联系人在你的高隐私分组中', style: TextStyle(color: kDimiGray99)),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _unlockAndReload,
                style:
                    FilledButton.styleFrom(backgroundColor: kDimiPrimaryFill),
                child: const Text('输入密码查看'),
              ),
            ],
          ),
        );
      }
      // 隐私拦截为终态（重试无意义），保留锁定提示；其余错误统一走重试图
      if (_privacyBlocked) {
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.lock_outline, size: 48, color: kDimiGrayCC),
              const SizedBox(height: 12),
              Text(_error!, style: const TextStyle(color: kDimiGray99)),
            ],
          ),
        );
      }
      return DimiErrorView(message: _error!, onRetry: _load);
    }
    final card = _card!;
    final brief = card.brief;
    final isSelf = context.read<Session>().currentUser?.userId == widget.userId;
    // 资料卡主经历取第一条，用于验证徽标与交集横幅的 V0 判定提示
    final firstEdu = card.educations.isNotEmpty ? card.educations.first : null;
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        // 头部白卡：顶部主色渐变背景层（kDimiPrimary→kDimiSuccess），头像叠放其上
        Card(
          child: Column(
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  ClipRRect(
                    borderRadius:
                        const BorderRadius.vertical(top: Radius.circular(10)),
                    child: Container(
                      height: 88,
                      decoration: const BoxDecoration(
                        color: kDimiPrimarySoft,
                      ),
                    ),
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: -36,
                    child: Center(
                      child: Container(
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.white, width: 3),
                          borderRadius:
                              BorderRadius.circular(kDimiRadiusAvatar + 3),
                        ),
                        child: DimiAvatar(
                          name: brief.nickname,
                          avatarUrl: brief.avatarUrl,
                          size: 72,
                          seed: brief.userId,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 46, 14, 20),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Flexible(
                          child: Text(
                            brief.nickname ?? '未命名',
                            style: const TextStyle(
                                fontSize: 19, fontWeight: FontWeight.w700),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        VerifyBadge(
                          firstEdu?.verificationLevel ?? 0,
                          label: (brief.matchTags.isNotEmpty)
                              ? brief.matchTags.first
                              : null,
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    // real_name 为服务端渐显判定后的展示值（全名/掩码/null），直接展示
                    MaskedName(
                      brief.realName,
                      style: const TextStyle(fontSize: 17, color: kDimiText),
                    ),
                    // 不展示 DIMI 号：昵称+真名即身份，内部标识不外显
                    //（精确找人的身份核验靠交集横幅与学校/家乡信息）
                  ],
                ),
              ),
            ],
          ),
        ),
        // 交集横幅：服务端分级措辞直接展示（含 V0 未验证限定句情形）
        if (card.intersectionBanner != null &&
            card.intersectionBanner!.isNotEmpty) ...[
          IntersectionBanner(card.intersectionBanner),
          if (card.crossExperiences.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6, left: 4),
              child: Text(
                card.crossExperiences.join(' · '),
                style: const TextStyle(fontSize: 14, color: kDimiGray99),
              ),
            ),
          const SizedBox(height: 10),
        ],
        if (card.educations.isNotEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('教育经历',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  ...card.educations.map(
                    (e) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: [
                          const Icon(Icons.school_outlined,
                              size: 18, color: kDimiPrimary),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(e.displayLine,
                                style: const TextStyle(fontSize: 16)),
                          ),
                          VerifyBadge(e.verificationLevel),
                        ],
                      ),
                    ),
                  ),
                  if (card.hometownDisplay != null) ...[
                    const Divider(height: 24),
                    const Text('家乡',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    // 家乡字段可点 → 对方家乡页（服务端下发 hometown_region_code 时）；
                    // 未下发 code 时降级为纯展示
                    InkWell(
                      borderRadius: BorderRadius.circular(kDimiRadiusInput),
                      onTap: card.hometownRegionCode == null
                          ? null
                          : () => Navigator.of(context)
                                  .push(MaterialPageRoute<void>(
                                builder: (_) => HometownPageScreen(
                                  regionCode: card.hometownRegionCode!,
                                ),
                              )),
                      child: SizedBox(
                        height: 48,
                        child: Row(
                          children: [
                            const Icon(Icons.home_work_outlined,
                                size: 18, color: kDimiApricotDeep),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                // 已下发镇级 code 可直达家乡页，不再提示「成为好友后可见」
                                card.hometownRegionCode == null
                                    ? '${card.hometownDisplay}（精确镇：成为好友后可见）'
                                    : card.hometownDisplay ?? '',
                                style: const TextStyle(fontSize: 16),
                              ),
                            ),
                            if (card.hometownRegionCode != null)
                              const Icon(Icons.chevron_right,
                                  color: kDimiGrayCC),
                          ],
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        Card(
          child: ListTile(
            leading:
                const Icon(Icons.auto_awesome_outlined, color: kDimiPrimary),
            title: const Text('TA 的朋友圈', style: TextStyle(fontSize: 17)),
            subtitle: Text(
              card.canViewMoments ? '可查看' : '对方设置了陌生人不可见',
              style: const TextStyle(fontSize: 14),
            ),
            trailing: const Icon(Icons.chevron_right, color: kDimiGrayCC),
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => UserMomentsScreen(
                userId: widget.userId,
                nickname: brief.nickname,
              ),
            )),
          ),
        ),
        const SizedBox(height: 10),
        // 底部操作按钮按关系渲染：本人/拉黑不显示；
        // 好友→发消息；pending_out→等待验证（禁用）；pending_in→通过好友验证
        if (!isSelf && card.relation != 'blocked')
          switch (card.relation) {
            'friend' => FilledButton(
                onPressed: _openingChat ? null : () => _openChat(brief.userId),
                style: FilledButton.styleFrom(
                  backgroundColor: kDimiPrimaryFill,
                  foregroundColor: kDimiPrimary,
                  padding: const EdgeInsets.symmetric(vertical: 13),
                ),
                child: Text(_openingChat ? '打开中…' : '发消息',
                    style: const TextStyle(fontSize: 17)),
              ),
            'pending_out' => FilledButton(
                onPressed: null,
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 13),
                ),
                child: const Text('等待验证', style: TextStyle(fontSize: 17)),
              ),
            'pending_in' => FilledButton(
                onPressed: () => Navigator.of(context)
                    .pushNamed(FriendRequestsScreen.routeName),
                style: FilledButton.styleFrom(
                  backgroundColor: kDimiPrimaryFill,
                  foregroundColor: kDimiPrimary,
                  padding: const EdgeInsets.symmetric(vertical: 13),
                ),
                child: const Text('通过好友验证', style: TextStyle(fontSize: 17)),
              ),
            _ => FilledButton(
                onPressed: () =>
                    Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => FriendApplyScreen(
                    target: brief,
                    bannerText: card.intersectionBanner,
                  ),
                )),
                style: FilledButton.styleFrom(
                  backgroundColor: kDimiPrimaryFill,
                  foregroundColor: kDimiPrimary,
                  padding: const EdgeInsets.symmetric(vertical: 13),
                ),
                child: const Text('加好友', style: TextStyle(fontSize: 17)),
              ),
          },
        const SizedBox(height: 16),
      ],
    );
  }
}
