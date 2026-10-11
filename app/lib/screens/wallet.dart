/// 觅豆钱包（P0 纯赠送体系）：余额大字卡 + 每日签到 + 任务列表 + 收支明细
///（cursor 分页滚动加载）。觅豆只能任务/活跃获得，无充值无提现，
/// 页面不得出现任何与人民币/现金相关的表述。
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../theme.dart';
import '../widgets/common/dimi_button.dart';
import '../widgets/common/dimi_error_view.dart';
import '../widgets/common/dimi_skeleton.dart';
import '../widgets/moment_card.dart' show formatMomentTime;
import 'educations.dart';
import 'moment_compose.dart';
import 'search.dart';

class WalletScreen extends StatefulWidget {
  const WalletScreen({super.key});

  @override
  State<WalletScreen> createState() => _WalletScreenState();
}

class _WalletScreenState extends State<WalletScreen> {
  final _scrollCtrl = ScrollController();

  WalletInfo? _info;
  bool _loading = true;
  String? _error;
  bool _checkingIn = false;

  List<CoinTransaction> _txns = [];
  String? _nextCursor;
  bool _loadingMore = false;

  @override
  void initState() {
    super.initState();
    _load();
    _scrollCtrl.addListener(() {
      // 滚动接近底部时加载下一页收支明细
      if (_scrollCtrl.hasClients &&
          _scrollCtrl.position.pixels >=
              _scrollCtrl.position.maxScrollExtent - 200) {
        _loadMore();
      }
    });
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

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final api = context.read<DimiApi>();
    try {
      final info = await api.wallet();
      final page = await api.walletTransactions();
      if (!mounted) return;
      setState(() {
        _info = info;
        _txns = page.items;
        _nextCursor = page.nextCursor;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadMore() async {
    final cursor = _nextCursor;
    if (cursor == null || cursor.isEmpty || _loadingMore) return;
    setState(() => _loadingMore = true);
    try {
      final page =
          await context.read<DimiApi>().walletTransactions(cursor: cursor);
      if (!mounted) return;
      setState(() {
        _txns = [..._txns, ...page.items];
        _nextCursor = page.nextCursor;
      });
    } on ApiException {
      // 翻页失败静默，下次滚动重试
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  Future<void> _checkin() async {
    if (_checkingIn) return;
    setState(() => _checkingIn = true);
    try {
      final r = await context.read<DimiApi>().checkin();
      if (!mounted) return;
      _toast(r.granted ? '签到成功，觅豆 +${r.amount}' : '今日已签到过');
      // 刷新余额与任务完成态
      final info = await context.read<DimiApi>().wallet();
      if (!mounted) return;
      setState(() => _info = info);
    } on ApiException catch (e) {
      _toast(e.message);
    } finally {
      if (mounted) setState(() => _checkingIn = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kDimiBg,
      appBar: AppBar(title: const Text('觅豆钱包')),
      body: RefreshIndicator(
        color: kDimiPrimary,
        onRefresh: _load,
        child: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      // 骨架屏需可滚动，保证 RefreshIndicator 下拉手势可用
      return ListView(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        children: const [
          DimiSkeleton(height: 132, radius: kDimiRadiusCard),
          SizedBox(height: 10),
          DimiSkeleton(height: 64, radius: kDimiRadiusCard),
          SizedBox(height: 10),
          DimiSkeleton(height: 120, radius: kDimiRadiusCard),
          SizedBox(height: 16),
          DimiListSkeleton(itemCount: 4),
        ],
      );
    }
    if (_error != null) {
      return ListView(
        children: [
          const SizedBox(height: 120),
          DimiErrorView(message: _error!, onRetry: _load),
        ],
      );
    }
    final info = _info!;
    final hasTasks = info.tasks.isNotEmpty;
    // 固定头部：余额卡 / 签到卡 /（可选）任务卡
    final headerCount = hasTasks ? 3 : 2;
    // 收支明细区：1 个头片段 + N 行（懒加载）+ 1 个尾片段；空明细时头即整卡
    final txnCount = _txns.isEmpty ? 1 : _txns.length + 2;
    return ListView.builder(
      controller: _scrollCtrl,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      itemCount: headerCount + txnCount + 1,
      itemBuilder: (ctx, i) {
        if (i == 0) return _balanceCard(info);
        if (i == 1) {
          return Padding(
            padding: const EdgeInsets.only(top: 10),
            child: _checkinCard(info),
          );
        }
        if (hasTasks && i == 2) {
          return Padding(
            padding: const EdgeInsets.only(top: 10),
            child: _tasksCard(info),
          );
        }
        final j = i - headerCount;
        if (j == 0) {
          return Padding(
            padding: const EdgeInsets.only(top: 10),
            child: _txnHeader(),
          );
        }
        if (_txns.isNotEmpty) {
          if (j <= _txns.length) {
            return _txnRowItem(_txns[j - 1]);
          }
          if (j == _txns.length + 1) return _txnFooter();
        }
        return const SizedBox(height: 24);
      },
    );
  }

  /// 余额大字卡
  Widget _balanceCard(WalletInfo info) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Column(
          children: [
            const Text('觅豆余额',
                style: TextStyle(fontSize: 15, color: kDimiGray99)),
            const SizedBox(height: 6),
            Text(
              '${info.balance}',
              style: const TextStyle(
                  fontSize: 40, fontWeight: FontWeight.w700, color: kDimiText),
            ),
            const SizedBox(height: 6),
            Text(
              '累计收入 ${info.totalEarned} · 累计支出 ${info.totalSpent}',
              style: const TextStyle(fontSize: 14, color: kDimiGrayBB),
            ),
          ],
        ),
      ),
    );
  }

  /// 每日签到卡
  Widget _checkinCard(WalletInfo info) {
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        leading: const Icon(Icons.calendar_today_outlined, color: kDimiPrimary),
        title:
            const Text('每日签到', style: TextStyle(fontWeight: FontWeight.w600)),
        subtitle: const Text('每天活跃一下，觅豆到账',
            style: TextStyle(fontSize: 14, color: kDimiGray99)),
        trailing: info.todayCheckedIn
            ? const Text('今日已签到',
                style: TextStyle(fontSize: 15, color: kDimiGrayBB))
            : FilledButton(
                onPressed: _checkingIn ? null : _checkin,
                style: FilledButton.styleFrom(
                  backgroundColor: kDimiPrimaryFill,
                  foregroundColor: kDimiPrimary,
                  minimumSize: Size.zero,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                ),
                child: Text(_checkingIn ? '签到中' : '签到'),
              ),
      ),
    );
  }

  /// 任务「去完成」入口：按任务 code 落到对应页面，返回后刷新完成态
  /// （签到是独立签到卡的一键动作，不在任务列表里——避免"点一下白赚"的误解）
  Future<void> _goTask(CoinTask t) async {
    switch (t.code) {
      case 'edu_complete':
        await Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const EducationsScreen()));
      case 'first_moment':
        await Navigator.of(context).push(MaterialPageRoute<void>(
            builder: (_) => const MomentComposeScreen()));
      default:
        // friend_accept 等：去「找同学」发起
        await Navigator.of(context).pushNamed(SearchScreen.routeName);
    }
    if (mounted) _load();
  }

  /// 任务列表卡
  Widget _tasksCard(WalletInfo info) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('做任务 赚觅豆',
                style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            // 签到有独立签到卡（一键动作），任务列表不再重复展示 daily_login
            ...info.tasks.where((t) => t.code != 'daily_login').map(
                  (t) => ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(t.remark, style: const TextStyle(fontSize: 16)),
                    subtitle: Text('+${t.amount} 觅豆',
                        style: const TextStyle(
                            fontSize: 14, color: kDimiApricotDeep)),
                    trailing: t.done
                        ? const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.check_circle,
                                  size: 20, color: kDimiSuccess),
                              SizedBox(width: 4),
                              Text('已完成',
                                  style: TextStyle(
                                      fontSize: 14, color: kDimiGray99)),
                            ],
                          )
                        : DimiButton(
                            label: '去完成',
                            variant: DimiButtonVariant.secondary,
                            onPressed: () => _goTask(t),
                          ),
                  ),
                ),
          ],
        ),
      ),
    );
  }

  /// 收支明细卡片段：明细行拆为外层 ListView 懒加载 item 后，
  /// 用顶/底圆角片段拼出与原整卡一致的视觉（主题卡：白底、圆角 10）
  Widget _txnPiece(
      {bool top = false, bool bottom = false, required Widget child}) {
    return Card(
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: top ? const Radius.circular(10) : Radius.zero,
          bottom: bottom ? const Radius.circular(10) : Radius.zero,
        ),
      ),
      child: child,
    );
  }

  /// 明细区头片段：标题（空明细时附带空态文案，且为整卡）
  Widget _txnHeader() {
    final empty = _txns.isEmpty;
    return _txnPiece(
      top: true,
      bottom: empty,
      child: Padding(
        padding: EdgeInsets.fromLTRB(14, 14, 14, empty ? 14 : 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('收支明细', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            if (empty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Center(
                  child: Text('还没有收支记录',
                      style: TextStyle(fontSize: 15, color: kDimiGray99)),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 明细区尾片段：加载更多指示（逻辑不变）+ 卡底留白
  Widget _txnFooter() {
    return _txnPiece(
      bottom: true,
      child: Column(
        children: [
          if (_loadingMore)
            const Padding(
              padding: EdgeInsets.all(12),
              child: Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: kDimiPrimary),
                ),
              ),
            ),
          const SizedBox(height: 14),
        ],
      ),
    );
  }

  /// 单条明细行（保持原有水平 14 / 垂直 8 内边距）
  Widget _txnRowItem(CoinTransaction t) {
    return _txnPiece(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: _txnRow(t),
      ),
    );
  }

  Widget _txnRow(CoinTransaction t) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(t.remark.isEmpty ? '觅豆变动' : t.remark,
                    style: const TextStyle(fontSize: 16, color: kDimiText)),
                const SizedBox(height: 2),
                Text(
                  formatMomentTime(t.createdAt),
                  style: const TextStyle(fontSize: 14, color: kDimiGrayBB),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '${t.isIn ? '+' : '-'}${t.amount}',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  color: t.isIn ? kDimiPrimary : kDimiDanger,
                ),
              ),
              Text('余额 ${t.balanceAfter}',
                  style: const TextStyle(fontSize: 14, color: kDimiGrayBB)),
            ],
          ),
        ],
      ),
    );
  }
}
