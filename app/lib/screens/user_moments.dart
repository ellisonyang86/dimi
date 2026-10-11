/// TA 的朋友圈（相册页）：GET /users/{id}/moments。
/// 列表顶部为相册头部：16:9 封面区（服务端 moment_cover 有值显示封面图，
/// 无值雾杏渐变兜底）+ 右下角头像 + 昵称（本人时附签名）。
/// 本人相册页 AppBar 右上角有「设置封面」入口（跳资料编辑页对应项）。
/// 40301 显示隐私提示；高隐私分组门禁（data.locked）提供解锁入口。
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../state/session.dart';
import '../theme.dart';
import '../widgets/common/dimi_empty_state.dart';
import '../widgets/common/dimi_error_view.dart';
import '../widgets/common/dimi_skeleton.dart';
import '../widgets/dimi_avatar.dart';
import '../widgets/group_unlock.dart';
import '../widgets/moment_card.dart';
import 'moment_detail.dart';
import 'moment_compose.dart';
import 'profile_edit.dart';

class UserMomentsScreen extends StatefulWidget {
  const UserMomentsScreen({super.key, required this.userId, this.nickname});

  final int userId;
  final String? nickname;

  @override
  State<UserMomentsScreen> createState() => _UserMomentsScreenState();
}

class _UserMomentsScreenState extends State<UserMomentsScreen> {
  List<Moment> _items = [];
  bool _loading = true;
  String? _error;
  bool _groupLocked = false;

  /// 他人相册页的封面（取自 UserCard.momentCover；本人页直接读 Session）
  String? _coverUrl;

  bool get _isSelf {
    final me = context.read<Session>().currentUser;
    return me != null && me.userId == widget.userId;
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _groupLocked = false;
    });
    // 他人相册页补拉资料卡拿封面；失败不阻塞动态列表
    if (!_isSelf) {
      context
          .read<DimiApi>()
          .userCard(widget.userId,
              unlockToken: context.read<Session>().groupUnlockToken)
          .then((card) {
        if (mounted) setState(() => _coverUrl = card.momentCover);
      }).onError<Exception>((_, __) {});
    }
    try {
      final list = await context.read<DimiApi>().userMoments(widget.userId,
          unlockToken: context.read<Session>().groupUnlockToken);
      if (mounted) setState(() => _items = list);
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _error = e.message;
          _groupLocked = e.isGroupLocked;
        });
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _unlockAndReload() async {
    final ok = await showGroupUnlockDialog(context);
    if (ok && mounted) _load();
  }

  /// 本人相册页：跳资料编辑页「朋友圈封面」项；返回时 Session 已被该页刷新
  Future<void> _goSetCover() async {
    await Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const ProfileEditScreen()));
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    // watch Session：资料编辑页换封面后本人相册头即时刷新
    final isSelf =
        context.watch<Session>().currentUser?.userId == widget.userId;
    return Scaffold(
      backgroundColor: kDimiBg,
      appBar: AppBar(
        title: Text('${widget.nickname ?? 'TA'} 的朋友圈'),
        actions: [
          if (isSelf)
            IconButton(
                icon: const Icon(Icons.edit_note),
                tooltip: '写文章',
                onPressed: () async {
                  final published = await Navigator.of(context).push<bool>(
                      MaterialPageRoute(
                          builder: (_) =>
                              const MomentComposeScreen(articleMode: true)));
                  if (published == true && mounted) _load();
                }),
          if (isSelf)
            IconButton(
              icon: const Icon(Icons.image_outlined),
              tooltip: '设置封面',
              onPressed: _goSetCover,
            ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
        children: const [
          DimiSkeleton(height: 160),
          SizedBox(height: 16),
          DimiSkeleton(height: 180, radius: kDimiRadiusCard),
          SizedBox(height: 10),
          DimiSkeleton(height: 180, radius: kDimiRadiusCard),
        ],
      );
    }
    if (_error != null) {
      // 高隐私分组门禁：锁图标 + 解锁入口
      if (_groupLocked) {
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.lock_outline, size: 48, color: kDimiApricotDeep),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Text(_error!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: kDimiGray99)),
              ),
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
      return DimiErrorView(message: _error!, onRetry: _load);
    }
    if (_items.isEmpty) {
      // 空相册也保留页头封面区（本人可经右上角入口先设封面）
      return ListView(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
        children: [
          _header(),
          const DimiEmptyState(
            icon: Icons.auto_awesome_outlined,
            title: 'TA 还没有动态',
          ),
        ],
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
      itemCount: _items.length + 1,
      itemBuilder: (ctx, i) {
        if (i == 0) return _header();
        final m = _items[i - 1];
        return MomentCard(
          moment: m,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
                builder: (_) => MomentDetailScreen(momentId: m.momentId)),
          ),
        );
      },
    );
  }

  /// 相册页头部：16:9 封面区（moment_cover 有值显示封面图，无值雾杏渐变兜底）
  /// + 右下角头像（白描边）+ 昵称 / 签名
  Widget _header() {
    final me = context.read<Session>().currentUser;
    final isSelf = me != null && me.userId == widget.userId;
    final author = _items.isNotEmpty ? _items.first.author : null;
    // 头像优先取动态作者信息；本人页回退 Session 缓存
    final avatarUrl = author?.userId == widget.userId
        ? author?.avatarUrl
        : (isSelf ? me.avatarUrl : null);
    final name = widget.nickname ??
        author?.realName ??
        author?.nickname ??
        (isSelf ? me.nickname : null) ??
        'TA';
    // 签名只有本人页有数据来源（Session 缓存），不为此新增接口
    final signature = isSelf ? me.signature : null;
    // 封面：本人读 Session.currentUser.momentCover，他人读资料卡补拉结果
    final cover = isSelf ? me.momentCover : _coverUrl;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Stack(
          clipBehavior: Clip.none,
          children: [
            AspectRatio(
              aspectRatio: 16 / 9,
              child: SizedBox(
                width: double.infinity,
                child: cover != null && cover.isNotEmpty
                    ? Image.network(
                        cover,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => _coverFallback(),
                      )
                    : _coverFallback(),
              ),
            ),
            Positioned(
              right: 12,
              bottom: -28,
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.white, width: 3),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: DimiAvatar(
                  name: name,
                  avatarUrl: avatarUrl,
                  size: 60,
                  seed: widget.userId,
                ),
              ),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(right: 12, top: 34, bottom: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                name,
                style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: kDimiText),
              ),
              if (signature != null && signature.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  signature,
                  style: const TextStyle(fontSize: 14, color: kDimiGray99),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  /// 封面缺省兜底：雾杏渐变 + 半透明风景图标
  Widget _coverFallback() {
    return Container(
      decoration: const BoxDecoration(
        color: kDimiApricotSoft,
      ),
      child: const Center(
        child:
            Icon(Icons.landscape_outlined, size: 64, color: kDimiApricotDeep),
      ),
    );
  }
}
