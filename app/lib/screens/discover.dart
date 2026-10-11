/// 「发现」tab 聚合页（对齐微信发现页）：三个圈边界清晰、各自独立入口——
/// 朋友圈=好友的动态；同学圈=同校同届同学的动态（无需加好友）；
/// 老乡圈=家乡同市老乡的动态（无需加好友）。
/// 我的二维码在「我」tab 资料头（对齐微信）；扫一扫入口在本页首组。
/// 红点 = 我的动态自上次进入朋友圈后有新点赞/评论（接口轮询，非数字）。
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/client.dart';
import '../theme.dart';
import '../widgets/common/dimi_section.dart';
import 'fellow.dart';
import 'followed_hometowns.dart';
import 'hometown_page.dart';
import 'moments_feed.dart';
import 'scan.dart';

/// 「上次进入朋友圈」时间戳（epoch 毫秒），红点以此为 since 基准
const kMomentsLastSeenKey = 'moments_last_seen_ms';

class DiscoverScreen extends StatefulWidget {
  const DiscoverScreen({super.key});

  @override
  State<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends State<DiscoverScreen> {
  bool _momentsUnread = false;

  /// 「我的家乡」入口防连点（家乡 code 需先拉接口确认）
  bool _openingHometown = false;

  @override
  void initState() {
    super.initState();
    _refreshUnread();
  }

  /// 查询我的动态是否有新互动（失败静默，不打扰浏览）
  Future<void> _refreshUnread() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final since = prefs.getInt(kMomentsLastSeenKey) ?? 0;
      if (!mounted) return;
      final hasNew =
          await context.read<DimiApi>().momentsInteractionsUnread(since);
      if (mounted) setState(() => _momentsUnread = hasNew);
    } on ApiException {
      // 未登录或接口未就绪时忽略
    }
  }

  Future<void> _openMoments() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const MomentsFeedScreen()),
    );
    // 从朋友圈返回：记为已看并清红点
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
        kMomentsLastSeenKey, DateTime.now().millisecondsSinceEpoch);
    if (mounted) setState(() => _momentsUnread = false);
  }

  /// 「我的家乡」入口：取本人家乡（type=1）镇级 code 进家乡页；
  /// 未设家乡或 code 非镇级（镇级为 9 位数字）则跳找老乡页
  /// （内含四级联动设置家乡流程，引导补全到镇级）
  Future<void> _openMyHometown() async {
    if (_openingHometown) return;
    setState(() => _openingHometown = true);
    try {
      final hometowns = await context.read<DimiApi>().myHometowns();
      if (!mounted) return;
      String? code;
      for (final h in hometowns) {
        if (h.type == 1 && h.regionCode.isNotEmpty) {
          code = h.regionCode;
          break;
        }
      }
      if (code != null && RegExp(r'^\d{9}$').hasMatch(code)) {
        Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => HometownPageScreen(regionCode: code!),
        ));
      } else {
        Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => const FellowScreen(),
        ));
      }
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    } finally {
      if (mounted) setState(() => _openingHometown = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kDimiBg,
      appBar: AppBar(title: const Text('发现')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 10),
        children: [
          // 三个圈一组（微信式整块白底 + 发丝分隔线），家乡系入口单列一组
          DimiSection(
            dividerIndent: 64,
            children: [
              // 扫一扫：识别对方 dimi://u/{userId} 二维码，进资料卡加好友
              _entry(
                icon: Icons.qr_code_scanner,
                title: '扫一扫',
                onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => const ScanScreen(),
                )),
              ),
              _entry(
                icon: Icons.history_toggle_off,
                title: '朋友圈',
                showDot: _momentsUnread,
                onTap: _openMoments,
              ),
              _entry(
                icon: Icons.school_outlined,
                title: '同学圈',
                onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => const MomentsFeedScreen(
                      title: '同学圈', visibility: 'classmates'),
                )),
              ),
              _entry(
                icon: Icons.cottage_outlined,
                title: '老乡圈',
                onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => const MomentsFeedScreen(
                      title: '老乡圈', visibility: 'fellows'),
                )),
              ),
            ],
          ),
          DimiSection(
            dividerIndent: 64,
            children: [
              _entry(
                icon: Icons.home_work_outlined,
                title: '我的家乡',
                accentColor: kDimiApricotDeep,
                accentBg: kDimiApricotSoft,
                onTap: _openMyHometown,
              ),
              // 我关注的家乡：朋友/老乡的家乡页关注后在此聚合回看
              _entry(
                icon: Icons.bookmarks_outlined,
                title: '我关注的家乡',
                accentColor: kDimiApricotDeep,
                accentBg: kDimiApricotSoft,
                onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => const FollowedHometownsScreen(),
                )),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 分组条目：40px 浅底图标徽标 + 标题 + 右侧箭头；
  /// 不带副标题（对齐微信发现页：圈名即语义，「简约而不简单」）；
  /// accentColor/accentBg 可换成雾杏色系（老乡系入口）
  Widget _entry({
    required IconData icon,
    required String title,
    required VoidCallback onTap,
    bool showDot = false,
    Color accentColor = kDimiPrimary,
    Color accentBg = kDimiPrimarySoft,
  }) {
    return DimiSectionItem(
      icon: icon,
      iconColor: accentColor,
      iconBackground: accentBg,
      title: title,
      // 新互动红点（朋友圈）：置于箭头左侧
      trailing: showDot
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: const BoxDecoration(
                    color: kDimiDanger,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
                const Icon(Icons.chevron_right, size: 20, color: kDimiGray99),
              ],
            )
          : null,
      onTap: onTap,
    );
  }
}
