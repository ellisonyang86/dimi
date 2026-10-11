/// 新的朋友（好友申请收件箱/发件箱）：/friends/requests 列表，接受/拒绝。
/// 通过后服务端自动生成交集破冰消息并返回 conversation_id，可直接进入单聊。
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../widgets/common/dimi_section.dart';
import '../widgets/dimi_avatar.dart';
import '../widgets/intersection_banner.dart';
import '../widgets/masked_name.dart';
import 'chat.dart';
import '../theme.dart';

class FriendRequestsScreen extends StatefulWidget {
  const FriendRequestsScreen({super.key});

  static const routeName = '/friend_requests';

  @override
  State<FriendRequestsScreen> createState() => _FriendRequestsScreenState();
}

class _FriendRequestsScreenState extends State<FriendRequestsScreen> {
  String _box = 'inbox';
  bool _loading = true;
  String? _error;
  List<FriendRequest> _items = [];

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
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final items = await context.read<DimiApi>().friendRequests(box: _box);
      if (!mounted) return;
      setState(() => _items = items);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _accept(FriendRequest req) async {
    try {
      final convId = await context.read<DimiApi>().acceptFriendRequest(req.id);
      if (!mounted) return;
      _toast('已通过申请，打个招呼吧');
      await _load();
      if (!mounted || convId <= 0) return;
      Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => ChatScreen(
          conversation: Conversation(
            convId: convId,
            title: req.fromUser?.nickname ?? '',
            intersectionBanner: req.intersectionSnapshot,
            peerId: req.fromUser?.userId,
          ),
        ),
      ));
    } on ApiException catch (e) {
      _toast(e.message);
    }
  }

  Future<void> _reject(FriendRequest req) async {
    try {
      await context.read<DimiApi>().rejectFriendRequest(req.id);
      if (!mounted) return;
      _toast('已拒绝（不通知对方）');
      _load();
    } on ApiException catch (e) {
      _toast(e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kDimiBg,
      appBar: AppBar(title: const Text('新的朋友')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'inbox', label: Text('收到的申请')),
                ButtonSegment(value: 'outbox', label: Text('我发出的')),
              ],
              selected: {_box},
              onSelectionChanged: (s) {
                setState(() => _box = s.first);
                _load();
              },
            ),
          ),
          Expanded(child: _buildBody()),
        ],
      ),
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
        child: Text(
          _box == 'inbox' ? '还没有收到好友申请' : '还没有发出过好友申请',
          style: const TextStyle(color: kDimiGray99),
        ),
      );
    }
    return RefreshIndicator(
      color: kDimiPrimary,
      onRefresh: _load,
      // 微信式分组排版：申请条目并入整块白底，组内发丝分隔线
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 7),
        children: [
          DimiSection(
            dividerIndent: 70,
            children: [
              for (var i = 0; i < _items.length; i++)
                _RequestTile(
                  req: _items[i],
                  isInbox: _box == 'inbox',
                  onAccept: () => _accept(_items[i]),
                  onReject: () => _reject(_items[i]),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _RequestTile extends StatelessWidget {
  const _RequestTile({
    required this.req,
    required this.isInbox,
    required this.onAccept,
    required this.onReject,
  });

  final FriendRequest req;
  final bool isInbox;
  final VoidCallback onAccept;
  final VoidCallback onReject;

  @override
  Widget build(BuildContext context) {
    final user = req.fromUser;
    // 条目内容不再单独包 Card，由外层 DimiSection 统一承载
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              DimiAvatar(
                name: user?.nickname,
                avatarUrl: user?.avatarUrl,
                seed: user?.userId,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            user?.nickname ?? '未命名',
                            style: const TextStyle(
                                fontSize: 17, fontWeight: FontWeight.w600),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 6),
                        // 真名钥匙披露：attach_real_name 时展示服务端渐显后的真名
                        if (req.attachRealName)
                          Flexible(child: MaskedName(user?.realName)),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      req.verifyMsg ?? '',
                      style: const TextStyle(fontSize: 15, color: kDimiGray55),
                    ),
                  ],
                ),
              ),
            ],
          ),
          // 申请当刻冻结的交集证据（§22.2）
          if (req.intersectionSnapshot != null &&
              req.intersectionSnapshot!.isNotEmpty) ...[
            const SizedBox(height: 10),
            IntersectionBanner(req.intersectionSnapshot, compact: true),
          ],
          const SizedBox(height: 10),
          if (isInbox && req.isPending)
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: onReject,
                  style: TextButton.styleFrom(
                    foregroundColor: kDimiGray66,
                  ),
                  child: const Text('拒绝'),
                ),
                const SizedBox(width: 6),
                // 扁平 tonal 按钮：浅底深字，避免列表里一排实心重按钮
                FilledButton(
                  onPressed: onAccept,
                  style: FilledButton.styleFrom(
                    backgroundColor: kDimiPrimarySoft,
                    foregroundColor: kDimiPrimary,
                    elevation: 0,
                  ),
                  child: const Text('接受'),
                ),
              ],
            )
          else
            Align(
              alignment: Alignment.centerRight,
              child: Text(
                switch (req.status) {
                  'pending' => isInbox ? '待处理' : '等待对方通过',
                  'accepted' => '已通过',
                  'rejected' => '已拒绝',
                  'expired' => '已过期',
                  _ => req.status,
                },
                style: const TextStyle(fontSize: 14, color: kDimiGray99),
              ),
            ),
        ],
      ),
    );
  }
}
