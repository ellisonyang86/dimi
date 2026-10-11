/// 单聊（原型屏⑥）：顶部交集提示条 + 消息气泡（文本/图片/语音/视频）+ 输入栏
///（语音长按录音、表情面板、图片/视频发送）。
/// V0.9 用 REST 轮询（3s，页面可见时）实现收发；正式版替换为
/// 腾讯云 IM SDK（见 V0.9 计划书 §5.3）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:audioplayers/audioplayers.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:record/record.dart';
import 'package:video_player/video_player.dart';

import '../theme.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../api/config.dart';
import '../api/models.dart';
import '../state/session.dart';
import '../state/chat_messages.dart';
import '../widgets/common/dimi_error_view.dart';
import '../widgets/common/dimi_skeleton.dart';
import '../widgets/dimi_avatar.dart';
import '../widgets/intersection_banner.dart';
import 'group_info.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.conversation});

  final Conversation conversation;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  final _inputCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  final _picker = ImagePicker();

  List<Message> _messages = []; // 时间正序
  bool _loading = true;
  String? _loadError; // 首载失败信息（整页错误态 + 重试）
  String? _nextCursor; // 历史分页游标（倒序），null 表示没有更早消息
  bool _loadingMore = false; // 「加载更早消息」进行中
  int _pendingNew = 0; // 用户不在底部时累积的新消息数（浮动胶囊提示）
  bool _sending = false;
  Future<void>? _pollInFlight;
  String? _retryText;
  String? _retryClientMsgId;
  bool _sendingImage = false;
  bool _sendingVideo = false;
  bool _emojiOpen = false;
  bool _plusOpen = false; // 功能面板（⊕：图片/视频等入口）
  bool _hasText = false; // 输入框非空时 ⊕ 让位给发送按钮（微信行为）
  Timer? _pollTimer;
  bool _appForeground = true;

  // ---- 语音消息 ----
  final _recorder = AudioRecorder();
  AudioPlayer? _voicePlayer;
  StreamSubscription<void>? _voiceCompleteSub;
  int? _playingMsgId;

  bool _voiceMode = false; // 输入栏语音/键盘切换
  bool _recording = false;
  bool _recordCancel = false; // 上滑取消态
  int _recordSeconds = 0;
  DateTime? _recordStartAt;
  String? _recordPath;
  Timer? _recordTimer;
  OverlayEntry? _recordOverlay;

  static const int _maxRecordSeconds = 60;
  static const double _recordCancelDy = 80; // 上滑取消阈值（px）

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _inputCtrl.addListener(_syncHasText);
    _scrollCtrl.addListener(_onScroll);
    _loadInitial();
    // 消息轮询：3s；仅在页面可见且 App 前台时发起（见头注释，正式版由 IM SDK 替代）
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (!mounted || !_appForeground) return;
      final route = ModalRoute.of(context);
      if (route?.isCurrent ?? false) _poll();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _inputCtrl.removeListener(_syncHasText);
    _pollTimer?.cancel();
    _recordTimer?.cancel();
    _recordOverlay?.remove();
    _recorder.dispose();
    _voiceCompleteSub?.cancel();
    _voicePlayer?.dispose();
    _inputCtrl.dispose();
    _scrollCtrl.removeListener(_onScroll);
    _scrollCtrl.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appForeground = state == AppLifecycleState.resumed;
    if (_appForeground && !_loading) _poll();
  }

  /// 是否破冰系统消息：服务端通过好友申请时同事务代发（friends.js accept），
  /// msg_type='system'，content 约定 JSON {"type":"ice_breaker","banner":"…"}
  static bool _isIceBreakerMessage(Message m) {
    if (!m.isSystem) return false;
    try {
      final j = jsonDecode(m.content);
      return j is Map && j['type'] == 'ice_breaker';
    } on Exception {
      return false; // 非约定 JSON 按普通系统消息处理
    }
  }

  /// 顶栏标题：群会话显示「群名(人数)」，单聊维持原标题
  String _titleText() {
    final conv = widget.conversation;
    if (conv.isGroup) {
      // 空标题按群种类兜底：老乡群 / 班级群
      final t = conv.title.isEmpty
          ? (conv.groupKind == 'hometown' ? '老乡群' : '班级群')
          : conv.title;
      return conv.memberCount != null ? '$t(${conv.memberCount})' : t;
    }
    return conv.title.isEmpty ? '聊天' : conv.title;
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// 周期计数：每 5 个轮询周期（≈15s）做一次全量对账
  int _pollTick = 0;

  Future<void> _confirmRecall(Message message) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('撤回这条消息？'),
        content: const Text('仅发送后 2 分钟内可撤回，撤回后双方均不可见内容。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('撤回')),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    try {
      await context.read<DimiApi>().recallMessage(message.msgId);
      if (!mounted) return;
      setState(() => _messages = mergeChatMessages(_messages, [
            Message(
              msgId: message.msgId,
              convId: message.convId,
              sender: message.sender,
              msgType: message.msgType,
              status: 'recalled',
              createdAt: message.createdAt,
            )
          ]));
      await _refreshFull();
    } on ApiException catch (e) {
      if (!mounted) return;
      _toast(e.message);
    }
  }

  Future<void> _loadInitial() async {
    try {
      final page = await context
          .read<DimiApi>()
          .messages(widget.conversation.convId, limit: 50);
      if (!mounted) return;
      // 接口返回倒序，翻转为正序展示
      setState(() {
        _messages = page.items.reversed.toList();
        _nextCursor = page.nextCursor;
        _loading = false;
        _loadError = null;
      });
      _scrollToBottom(animate: false);
      _markRead();
    } on ApiException catch (e) {
      if (!mounted) return;
      // 首载失败给整页错误态 + 重试入口（不再只 toast）
      setState(() {
        _loading = false;
        _loadError = e.message;
      });
    }
  }

  /// 首载重试：重置状态后重新拉取
  void _retryLoad() {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    _loadInitial();
  }

  /// 滚动监听（reverse 列表：pixels≈0 为底部最新消息，maxScrollExtent 为顶部）：
  /// 接近顶部触发「加载更早消息」；回到底部时清掉新消息胶囊
  void _onScroll() {
    if (!_scrollCtrl.hasClients) return;
    final pos = _scrollCtrl.position;
    if (pos.pixels >= pos.maxScrollExtent - 120) _loadEarlier();
    if (_pendingNew > 0 && pos.pixels < 80) {
      setState(() => _pendingNew = 0);
    }
  }

  /// 上拉加载更早消息：cursor 倒序分页，翻正后前插；
  /// reverse 列表下旧消息增长在可视顶部一端，滚动位置自动保持，无需补偿
  Future<void> _loadEarlier() async {
    final cursor = _nextCursor;
    if (_loadingMore || cursor == null || cursor.isEmpty) return;
    setState(() => _loadingMore = true);
    try {
      final page = await context
          .read<DimiApi>()
          .messages(widget.conversation.convId, cursor: cursor, limit: 50);
      if (!mounted) return;
      setState(() {
        _messages = mergeChatMessages(_messages, page.items);
        // 空页防御：不再推进游标，避免死循环
        _nextCursor = page.items.isEmpty ? null : page.nextCursor;
      });
    } on ApiException {
      // 加载更早失败静默，下次滚到顶部重试
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  /// 列表内容是否无变化（msgId + status 逐项比对）：
  /// 轮询对账无变化时跳过 setState，避免闪烁
  static bool _sameMessages(List<Message> a, List<Message> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].msgId != b[i].msgId || a[i].status != b[i].status) return false;
    }
    return true;
  }

  /// 用户是否本就近底部（reverse 列表：pixels 越小越靠底部）
  bool get _nearBottom =>
      !_scrollCtrl.hasClients || _scrollCtrl.position.pixels < 240;

  /// 增量轮询：传已知最大 msg_id，服务端返回正序新消息直接 append；
  /// 每 5 个周期做一次全量对账（撤回不产生新 msg_id，增量拉不到状态变更）。
  /// forceScroll：自己发消息后的拉取强制滚到底，不受「近底部」判断限制。
  Future<void> _poll({bool forceScroll = false}) async {
    if (_loading) return;
    final existing = _pollInFlight;
    if (existing != null) {
      await existing;
      if (forceScroll && mounted) await _poll(forceScroll: true);
      return;
    }
    final task = _pollOnce(forceScroll: forceScroll);
    _pollInFlight = task;
    try {
      await task;
    } finally {
      _pollInFlight = null;
    }
  }

  Future<void> _pollOnce({required bool forceScroll}) async {
    if (_messages.isEmpty) {
      await _refreshFull();
      return;
    }
    try {
      var caughtUp = false;
      // 每轮最多补 250 条；仍有积压时下轮继续，不能跳到最新页而漏中间消息。
      for (var batch = 0; batch < 5; batch++) {
        final since = _messages.last.msgId;
        final page = await context
            .read<DimiApi>()
            .messages(widget.conversation.convId, sinceMsgId: since, limit: 50);
        if (!mounted) return;
        final known = _messages.map((m) => m.msgId).toSet();
        final fresh =
            page.items.where((m) => !known.contains(m.msgId)).toList();
        if (fresh.isNotEmpty) {
          final stickBottom = forceScroll || _nearBottom;
          setState(() {
            _messages = mergeChatMessages(_messages, page.items);
            _pendingNew = stickBottom ? 0 : _pendingNew + fresh.length;
          });
          if (stickBottom) _scrollToBottom();
          _markRead();
        }
        if (page.items.length < 50 || _messages.last.msgId <= since) {
          caughtUp = true;
          break;
        }
      }
      if (caughtUp && ++_pollTick % 5 == 0) await _refreshFull();
      if (forceScroll && mounted) _scrollToBottom();
    } on ApiException {
      // 保留当前记录，网络恢复后继续从最后已知位点拉取。
    }
  }

  /// 最新页只对账已知消息状态，不丢弃已加载历史，也不跳过尚未拉到的消息。
  Future<void> _refreshFull() async {
    try {
      final page = await context
          .read<DimiApi>()
          .messages(widget.conversation.convId, limit: 50);
      if (!mounted) return;
      final wasEmpty = _messages.isEmpty;
      final known = _messages.map((m) => m.msgId).toSet();
      final fresh = mergeChatMessages(
          _messages,
          wasEmpty
              ? page.items
              : page.items.where((m) => known.contains(m.msgId)));
      if (_sameMessages(fresh, _messages)) return;
      setState(() {
        _messages = fresh;
        if (wasEmpty) _nextCursor = page.nextCursor;
      });
      if (wasEmpty) {
        _scrollToBottom();
        _markRead();
      }
    } on ApiException {
      // 对账失败保留本地记录，下个周期重试。
    }
  }

  Future<void> _markRead() async {
    if (_messages.isEmpty) return;
    try {
      await context
          .read<DimiApi>()
          .markRead(widget.conversation.convId, _messages.last.msgId);
    } on ApiException {
      // 已读上报失败静默
    }
  }

  Future<void> _send() async {
    final text = _inputCtrl.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() {
      _sending = true;
      _emojiOpen = false;
      _plusOpen = false;
    });
    if (_retryText != text) {
      _retryText = text;
      _retryClientMsgId =
          'c-${DateTime.now().microsecondsSinceEpoch}-${text.hashCode}';
    }
    try {
      await context.read<DimiApi>().sendMessage(
            convId: widget.conversation.convId,
            content: text,
            // client_msg_id 幂等防重（与 Idempotency-Key 双保险）
            clientMsgId: _retryClientMsgId!,
          );
      if (!mounted) return;
      _retryText = null;
      _retryClientMsgId = null;
      // 等待期间用户修改的草稿保留；确认成功后才清理本次提交文本。
      if (_inputCtrl.text.trim() == text) _inputCtrl.clear();
      await _poll(forceScroll: true);
    } on ApiException catch (e) {
      if (!mounted) return;
      _toast(e.message);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  static const _allowedImageExts = {'jpg', 'jpeg', 'png', 'webp'};

  /// 发送图片：相册选图（客户端压缩兜底 2MB 上限：1920×1920 / q85，
  /// 压缩后 1080p JPEG q85 约 300-600KB）→ ≤2MB 校验 →
  /// 上传 scene=chat_image → 发 msg_type='image' 消息
  Future<void> _sendImage() async {
    if (_sendingImage) return;
    XFile? f;
    try {
      f = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1920,
        maxHeight: 1920,
        imageQuality: 85,
      );
    } on Exception {
      if (mounted) _toast('打开相册失败，请重试');
      return;
    }
    if (f == null) return;
    if (!mounted) return;
    final ext =
        f.name.contains('.') ? f.name.split('.').last.toLowerCase() : 'jpg';
    if (!_allowedImageExts.contains(ext)) {
      _toast('仅支持 jpg / jpeg / png / webp 图片');
      return;
    }
    final bytes = await f.readAsBytes();
    if (!mounted) return;
    if (bytes.length > 2 * 1024 * 1024) {
      _toast('图片过大，请选择 2MB 以内的图片');
      return;
    }
    setState(() {
      _sendingImage = true;
      _emojiOpen = false;
      _plusOpen = false;
    });
    try {
      final api = context.read<DimiApi>();
      final res = await api.uploadImage('chat_image', bytes, ext);
      if (!mounted) return;
      await api.sendMessage(
        convId: widget.conversation.convId,
        content: res['url'] ?? '',
        msgType: 'image',
        clientMsgId:
            'c-${DateTime.now().millisecondsSinceEpoch}-${Random().nextInt(0x7fffffff)}',
      );
      if (!mounted) return;
      await _poll(forceScroll: true);
    } on ApiException catch (e) {
      if (!mounted) return;
      _toast(e.message);
    } finally {
      if (mounted) setState(() => _sendingImage = false);
    }
  }

  static const _allowedVideoExts = {'mp4', 'mov'};
  static const int _maxVideoBytes = 20 * 1024 * 1024;

  /// 视频入口：底部选择拍摄 / 相册
  Future<void> _pickVideoSource() async {
    if (_sending || _sendingVideo) return;
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.videocam_outlined),
              title: const Text('拍摄'),
              subtitle: const Text('最长 30 秒', style: TextStyle(fontSize: 14)),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('从相册选择'),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (source == null) return;
    await _sendVideo(source);
  }

  /// 发送视频：选/拍视频 → ≤20MB 校验 → 上传 scene=chat_video →
  /// 发 msg_type='video' 消息（content 约定 JSON：{"url":...}）
  Future<void> _sendVideo(ImageSource source) async {
    XFile? f;
    try {
      f = await _picker.pickVideo(
        source: source,
        maxDuration:
            source == ImageSource.camera ? const Duration(seconds: 30) : null,
      );
    } on Exception {
      if (mounted) _toast('选择视频失败，请重试');
      return;
    }
    if (f == null) return;
    if (!mounted) return;
    final ext =
        f.name.contains('.') ? f.name.split('.').last.toLowerCase() : 'mp4';
    if (!_allowedVideoExts.contains(ext)) {
      _toast('仅支持 mp4 / mov 视频');
      return;
    }
    final bytes = await f.readAsBytes();
    if (!mounted) return;
    if (bytes.length > _maxVideoBytes) {
      _toast('视频过大，请选择 20MB 以内的视频');
      return;
    }
    // 20MB 上传较慢，loading 态覆盖按钮直到完成
    setState(() {
      _sending = true;
      _sendingVideo = true;
      _emojiOpen = false;
      _plusOpen = false;
    });
    try {
      final api = context.read<DimiApi>();
      final res = await api.uploadImage('chat_video', bytes, ext);
      if (!mounted) return;
      await api.sendMessage(
        convId: widget.conversation.convId,
        content: jsonEncode({'url': res['url'] ?? ''}),
        msgType: 'video',
        clientMsgId:
            'c-${DateTime.now().millisecondsSinceEpoch}-${Random().nextInt(0x7fffffff)}',
      );
      if (!mounted) return;
      await _poll(forceScroll: true);
    } on ApiException catch (e) {
      if (!mounted) return;
      _toast(e.message);
    } finally {
      if (mounted) {
        setState(() {
          _sending = false;
          _sendingVideo = false;
        });
      }
    }
  }

  // ==================== 觅豆红包 ====================

  /// ⊕ 面板「红包」入口：弹出发红包弹层；发出后服务端同事务代发消息卡，
  /// 本地立即拉一轮让卡片出现
  Future<void> _showRedPacketSheet() async {
    final sent = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => _RedPacketSheet(
        convId: widget.conversation.convId,
        isGroup: widget.conversation.isGroup,
      ),
    );
    if (sent == true && mounted) {
      _toast('红包已发出');
      await _poll(forceScroll: true);
    }
  }

  /// 点按红包气泡：可领（active 且非发者且未领过）→ 拆开弹窗；
  /// 其余（自己发的/已领过/已领完/已过期）→ 直接详情弹窗
  Future<void> _openRedPacket(String packetId) async {
    RedPacket p;
    try {
      p = await context.read<DimiApi>().redPacket(packetId);
    } on ApiException catch (e) {
      _toast(e.message);
      return;
    }
    if (!mounted) return;
    final me = context.read<Session>().currentUser?.userId;
    final isSender = p.sender?.userId == me;
    if (p.isActive && !isSender && p.myClaim == null) {
      _showClaimDialog(p);
    } else {
      _showPacketDetail(p);
    }
  }

  void _showClaimDialog(RedPacket p) {
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
          decoration: BoxDecoration(
            color: kDimiDangerSoft,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DimiAvatar(
                name: p.senderName,
                avatarUrl: p.sender?.avatarUrl,
                seed: p.sender?.userId,
                size: 44,
              ),
              const SizedBox(height: 8),
              Text('${p.senderName}的觅豆红包',
                  style: const TextStyle(fontSize: 16, color: kDimiDanger)),
              const SizedBox(height: 6),
              Text(
                p.greeting == null || p.greeting!.isEmpty
                    ? '恭喜发财，大吉大利'
                    : p.greeting!,
                style: const TextStyle(fontSize: 19, color: kDimiDanger),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 22),
              InkWell(
                onTap: () {
                  Navigator.of(ctx).pop();
                  _claimRedPacket(p.packetId);
                },
                borderRadius: BorderRadius.circular(32),
                child: Container(
                  width: 64,
                  height: 64,
                  decoration: const BoxDecoration(
                    color: kDimiApricotSoft,
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: const Text('開',
                      style: TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.w700,
                          color: kDimiDanger)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _claimRedPacket(String packetId) async {
    try {
      final r = await context.read<DimiApi>().claimRedPacket(packetId);
      if (!mounted) return;
      _toast('觅豆 +${r.amount}');
      _showPacketDetail(r.packet);
    } on ApiException catch (e) {
      if (!mounted) return;
      _toast(e.message);
      // 已领完/已过期等：刷新一份详情展示最终状态
      try {
        final p = await context.read<DimiApi>().redPacket(packetId);
        if (mounted) _showPacketDetail(p);
      } on ApiException {
        // 详情拉取失败静默
      }
    }
  }

  String _packetStatusLine(RedPacket p) {
    if (p.isExpired) return '红包已过期，未领取的觅豆已退回发出者';
    if (p.isFinished) return '已领完，共 ${p.totalAmount} 觅豆';
    return '已领取 ${p.claimedCount}/${p.count} 个，'
        '共 ${p.claimedAmount}/${p.totalAmount} 觅豆';
  }

  /// 红包详情弹窗：我的领取金额 + 状态行 + 领取列表（手气最佳标记）
  void _showPacketDetail(RedPacket p) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            DimiAvatar(
              name: p.senderName,
              avatarUrl: p.sender?.avatarUrl,
              seed: p.sender?.userId,
              size: 28,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text('${p.senderName}的觅豆红包',
                  style: const TextStyle(fontSize: 17),
                  overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (p.greeting != null && p.greeting!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(p.greeting!,
                    style: const TextStyle(fontSize: 16, color: kDimiText)),
              ),
            if (p.myClaim != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    Text('${p.myClaim!.amount} 觅豆',
                        style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                            color: kDimiDanger)),
                    if (p.myClaim!.isBest) ...[
                      const SizedBox(width: 8),
                      const Text('手气最佳',
                          style:
                              TextStyle(fontSize: 14, color: kDimiApricotDeep)),
                    ],
                  ],
                ),
              ),
            Text(_packetStatusLine(p),
                style: const TextStyle(fontSize: 14, color: kDimiGray99)),
            const SizedBox(height: 8),
            if (p.claims.isEmpty)
              const Text('还没有人领取',
                  style: TextStyle(fontSize: 14, color: kDimiGrayBB))
            else
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 220),
                child: SingleChildScrollView(
                  child: Column(
                    children: p.claims
                        .map(
                          (c) => Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Row(
                              children: [
                                DimiAvatar(
                                  name: c.displayName,
                                  avatarUrl: c.user?.avatarUrl,
                                  seed: c.user?.userId,
                                  size: 28,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(c.displayName,
                                      style: const TextStyle(fontSize: 15),
                                      overflow: TextOverflow.ellipsis),
                                ),
                                if (c.isBest)
                                  const Padding(
                                    padding: EdgeInsets.only(right: 6),
                                    child: Text('手气最佳',
                                        style: TextStyle(
                                            fontSize: 14,
                                            color: kDimiApricotDeep)),
                                  ),
                                Text('${c.amount} 觅豆',
                                    style: const TextStyle(
                                        fontSize: 14, color: kDimiGray66)),
                              ],
                            ),
                          ),
                        )
                        .toList(),
                  ),
                ),
              ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('知道了')),
        ],
      ),
    );
  }

  /// 在光标处插入表情；selection 无效（未聚焦等）时追加到末尾，
  /// start/end clamp 到文本范围内，防止越界 RangeError
  void _insertEmoji(String emoji) {
    final text = _inputCtrl.text;
    final sel = _inputCtrl.selection;
    final start = (sel.isValid ? sel.start : text.length).clamp(0, text.length);
    final end = (sel.isValid ? sel.end : text.length).clamp(0, text.length);
    _inputCtrl.value = TextEditingValue(
      text: text.replaceRange(start, end, emoji),
      selection: TextSelection.collapsed(offset: start + emoji.length),
    );
  }

  /// 输入框文字变化 → 切换 ⊕/发送按钮（空串时 ⊕ 常显）
  void _syncHasText() {
    final has = _inputCtrl.text.isNotEmpty;
    if (has != _hasText) setState(() => _hasText = has);
  }

  /// 表情面板开关：与功能面板互斥，打开时收起键盘避免布局跳动
  void _toggleEmojiPanel() {
    setState(() {
      _emojiOpen = !_emojiOpen;
      _plusOpen = false;
    });
    if (_emojiOpen) {
      FocusScope.of(context).unfocus();
    }
  }

  /// 功能面板（⊕）开关：与表情面板互斥，打开时收起键盘
  void _togglePlusPanel() {
    setState(() {
      _plusOpen = !_plusOpen;
      _emojiOpen = false;
    });
    if (_plusOpen) {
      FocusScope.of(context).unfocus();
    }
  }

  // ==================== 语音消息 ====================

  void _toggleVoiceMode() {
    setState(() {
      _voiceMode = !_voiceMode;
      _emojiOpen = false;
      _plusOpen = false;
    });
  }

  /// 长按开始录音（record 包自带权限请求）
  Future<void> _startRecord(LongPressStartDetails _) async {
    if (_sending || _recording) return;
    bool granted = false;
    try {
      granted = await _recorder.hasPermission();
    } on Exception {
      granted = false;
    }
    if (!mounted) return;
    if (!granted) {
      _toast('需要麦克风权限才能发语音');
      return;
    }
    final path =
        '${Directory.systemTemp.path}/dimi_voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
    try {
      await _recorder.start(const RecordConfig(encoder: AudioEncoder.aacLc),
          path: path);
    } on Exception {
      if (mounted) _toast('录音启动失败，请重试');
      return;
    }
    setState(() {
      _recording = true;
      _recordCancel = false;
      _recordSeconds = 0;
      _recordStartAt = DateTime.now();
      _recordPath = path;
    });
    _showRecordOverlay();
    _recordTimer?.cancel();
    _recordTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() => _recordSeconds++);
      _recordOverlay?.markNeedsBuild();
      // 最长 60 秒，到点自动停止并按发送处理
      if (_recordSeconds >= _maxRecordSeconds) {
        t.cancel();
        _finishRecording(cancelled: false);
      }
    });
  }

  /// 长按移动：上滑超过阈值进入取消态
  void _updateRecord(LongPressMoveUpdateDetails d) {
    if (!_recording) return;
    final cancel = d.localOffsetFromOrigin.dy < -_recordCancelDy;
    if (cancel != _recordCancel) {
      setState(() => _recordCancel = cancel);
      _recordOverlay?.markNeedsBuild();
    }
  }

  /// 松开手指（或手势被系统取消/到 60s 自动触发）结束录音
  Future<void> _finishRecording({required bool cancelled}) async {
    if (!_recording) return;
    _recordTimer?.cancel();
    final elapsed =
        DateTime.now().difference(_recordStartAt ?? DateTime.now()).inSeconds;
    final path = _recordPath;
    setState(() {
      _recording = false;
      _recordCancel = false;
    });
    _hideRecordOverlay();
    if (cancelled) {
      await _recorder.cancel();
      _deleteVoiceFile(path);
      return;
    }
    String? out;
    try {
      out = await _recorder.stop();
    } on Exception {
      out = null;
    }
    // 最短 1 秒，不足丢弃
    if (elapsed < 1) {
      _toast('说话时间太短');
      _deleteVoiceFile(out ?? path);
      return;
    }
    if (out == null) {
      _toast('录音失败，请重试');
      _deleteVoiceFile(path);
      return;
    }
    await _sendVoice(out, elapsed.clamp(1, _maxRecordSeconds));
  }

  /// 上传并发送语音消息（content 约定 JSON：{"url":..., "duration":...}）
  Future<void> _sendVoice(String path, int seconds) async {
    if (_sending) return;
    setState(() => _sending = true);
    try {
      final bytes = await File(path).readAsBytes();
      if (bytes.length > 2 * 1024 * 1024) {
        _toast('语音文件过大，请重新录制');
        return;
      }
      if (!mounted) return;
      final api = context.read<DimiApi>();
      final res = await api.uploadImage('chat_voice', bytes, 'm4a');
      if (!mounted) return;
      await api.sendMessage(
        convId: widget.conversation.convId,
        content: jsonEncode({'url': res['url'] ?? '', 'duration': seconds}),
        msgType: 'voice',
        clientMsgId:
            'c-${DateTime.now().millisecondsSinceEpoch}-${Random().nextInt(0x7fffffff)}',
      );
      if (!mounted) return;
      await _poll(forceScroll: true);
    } on ApiException catch (e) {
      if (!mounted) return;
      _toast(e.message);
    } on Exception {
      if (!mounted) return;
      _toast('语音发送失败，请重试');
    } finally {
      _deleteVoiceFile(path);
      if (mounted) setState(() => _sending = false);
    }
  }

  void _deleteVoiceFile(String? path) {
    if (path == null) return;
    try {
      File(path).deleteSync();
    } on Exception {
      // 临时文件清理失败静默
    }
  }

  void _showRecordOverlay() {
    _recordOverlay?.remove();
    _recordOverlay = OverlayEntry(builder: (_) => _buildRecordOverlay());
    Overlay.of(context).insert(_recordOverlay!);
  }

  void _hideRecordOverlay() {
    _recordOverlay?.remove();
    _recordOverlay = null;
  }

  Widget _buildRecordOverlay() {
    final cancel = _recordCancel;
    return IgnorePointer(
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 20),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.75),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.mic,
                size: 44,
                color: cancel ? kDimiDanger : Colors.white,
              ),
              const SizedBox(height: 8),
              Text(
                '$_recordSeconds″ / $_maxRecordSeconds″',
                style: const TextStyle(color: Colors.white, fontSize: 16),
              ),
              const SizedBox(height: 6),
              Text(
                cancel ? '松开手指，取消发送' : '上滑取消',
                style: TextStyle(
                  fontSize: 14,
                  color: cancel ? kDimiDanger : Colors.white70,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 语音气泡点击：播放/暂停；同时只播一条，播放结束恢复图标
  Future<void> _toggleVoice(Message message) async {
    final v = _parseVoiceContent(message.content);
    if (v == null) return;
    if (_playingMsgId == message.msgId) {
      setState(() => _playingMsgId = null);
      await _voicePlayer?.stop();
      return;
    }
    final player = _voicePlayer ??= AudioPlayer();
    _voiceCompleteSub ??= player.onPlayerComplete.listen((_) {
      if (mounted) setState(() => _playingMsgId = null);
    });
    await player.stop();
    if (!mounted) return;
    setState(() => _playingMsgId = message.msgId);
    try {
      await player.play(UrlSource(ApiConfig.resolveMediaUrl(v.url)));
    } on Exception {
      if (mounted) {
        setState(() => _playingMsgId = null);
        _toast('语音播放失败');
      }
    }
  }

  /// 滚到底部（reverse 列表底部即 offset 0）；首屏直接 jump，新消息用 300ms 动画
  void _scrollToBottom({bool animate = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollCtrl.hasClients) return;
      if (animate) {
        _scrollCtrl.animateTo(0,
            duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
      } else {
        _scrollCtrl.jumpTo(0);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final conv = widget.conversation;
    return Scaffold(
      backgroundColor: kDimiChatBg,
      appBar: AppBar(
        title: Text(_titleText()),
        actions: [
          if (conv.isGroup)
            IconButton(
              icon: const Icon(Icons.more_horiz),
              tooltip: '群资料',
              onPressed: () =>
                  Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => GroupInfoScreen(
                  convId: conv.convId,
                  title: conv.title,
                  memberCount: conv.memberCount,
                  // group_kind 缺失（旧服务端/未知群）按班级群兜底
                  groupKind: conv.groupKind ?? 'class',
                ),
              )),
            ),
        ],
      ),
      body: Column(
        children: [
          // 顶部交集提示条降级为兜底：消息流中已存在破冰系统消息
          // （ice_breaker，随消息流持久存在）时由消息流承载交集文案，
          // 避免与消息流重复展示同一段「你们的经历显示同为…」；
          // 老会话无破冰消息（历史数据）时仍显示常驻横幅兜底
          if (!_messages.any(_isIceBreakerMessage))
            IntersectionBanner(conv.intersectionBanner, compact: true),
          Expanded(
            child: _loading
                // 聊天气泡形态骨架：左右交替的「头像 + 气泡条」
                ? ListView(
                    padding: const EdgeInsets.symmetric(
                        horizontal: kDimiSpace12, vertical: kDimiSpace16),
                    physics: const NeverScrollableScrollPhysics(),
                    children: const [
                      _SkeletonBubble(width: 180),
                      SizedBox(height: kDimiSpace16),
                      _SkeletonBubble(mine: true, width: 140),
                      SizedBox(height: kDimiSpace16),
                      _SkeletonBubble(width: 220, tall: true),
                      SizedBox(height: kDimiSpace16),
                      _SkeletonBubble(mine: true, width: 100),
                      SizedBox(height: kDimiSpace16),
                      _SkeletonBubble(width: 160),
                    ],
                  )
                : _loadError != null
                    ? DimiErrorView(message: _loadError!, onRetry: _retryLoad)
                    : _messages.isEmpty
                        ? _IceBreakCard(banner: conv.intersectionBanner)
                        : Stack(
                            children: [
                              // reverse：index 0 在底部（最新消息），
                              // 末项在顶部，放「加载更早消息」指示
                              ListView.builder(
                                controller: _scrollCtrl,
                                reverse: true,
                                padding:
                                    const EdgeInsets.symmetric(vertical: 8),
                                itemCount:
                                    _messages.length + (_loadingMore ? 1 : 0),
                                itemBuilder: (_, i) {
                                  if (i >= _messages.length) {
                                    return const Padding(
                                      padding:
                                          EdgeInsets.symmetric(vertical: 10),
                                      child: Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        children: [
                                          SizedBox(
                                            width: 14,
                                            height: 14,
                                            child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                                color: kDimiPrimary),
                                          ),
                                          SizedBox(width: 6),
                                          Text('加载更早消息…',
                                              style: TextStyle(
                                                  fontSize: 14,
                                                  color: kDimiGray99)),
                                        ],
                                      ),
                                    );
                                  }
                                  final message =
                                      _messages[_messages.length - 1 - i];
                                  return _MessageBubble(
                                    message: message,
                                    myUserId: context
                                        .read<Session>()
                                        .currentUser
                                        ?.userId,
                                    onRecall: () => _confirmRecall(message),
                                    isPlaying: _playingMsgId == message.msgId,
                                    onPlay: () => _toggleVoice(message),
                                    isGroup: widget.conversation.isGroup,
                                    onOpenRedPacket: _openRedPacket,
                                  );
                                },
                              ),
                              // 用户不在底部时的「有新消息」浮动胶囊，点击下滚
                              if (_pendingNew > 0)
                                Positioned(
                                  left: 0,
                                  right: 0,
                                  bottom: 12,
                                  child: Center(
                                    child: Material(
                                      color: kDimiPrimaryFill,
                                      borderRadius: BorderRadius.circular(24),
                                      child: InkWell(
                                        onTap: () {
                                          setState(() => _pendingNew = 0);
                                          _scrollToBottom();
                                        },
                                        borderRadius: BorderRadius.circular(24),
                                        child: Container(
                                          constraints: const BoxConstraints(
                                              minHeight: 48),
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 16),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              const Icon(Icons.arrow_downward,
                                                  size: 14,
                                                  color: kDimiPrimary),
                                              const SizedBox(width: 4),
                                              Text(
                                                _pendingNew > 1
                                                    ? '有 $_pendingNew 条新消息'
                                                    : '有新消息',
                                                style: const TextStyle(
                                                    fontSize: 14,
                                                    color: kDimiPrimary),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
          ),
          // 输入栏（微信式）：语音切换 / 文本或按住说话 / 表情 / ⊕（有文字时让位给发送）
          Container(
            color: kDimiBg,
            padding: const EdgeInsets.fromLTRB(4, 8, 10, 8),
            child: SafeArea(
              top: false,
              child: Row(
                children: [
                  IconButton(
                    onPressed: _toggleVoiceMode,
                    icon: Icon(
                      _voiceMode
                          ? Icons.keyboard_outlined
                          : Icons.mic_none_outlined,
                      color: kDimiGray66,
                    ),
                    tooltip: '语音',
                  ),
                  Expanded(
                    child: _voiceMode
                        ? GestureDetector(
                            onLongPressStart: _startRecord,
                            onLongPressMoveUpdate: _updateRecord,
                            onLongPressEnd: (_) =>
                                _finishRecording(cancelled: _recordCancel),
                            onLongPressCancel: () =>
                                _finishRecording(cancelled: true),
                            child: Container(
                              // 中老年友好触达区：52dp（≥48）
                              height: 52,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: _recording
                                    ? kDimiPrimarySoft
                                    : Colors.white,
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(color: kDimiHairline),
                              ),
                              child: Text(
                                _recording ? '松开 发送' : '按住 说话',
                                style: const TextStyle(
                                    fontSize: 17, color: kDimiText),
                              ),
                            ),
                          )
                        : TextField(
                            controller: _inputCtrl,
                            // 面板打开时点输入框（弹键盘）即收起面板
                            onTap: () {
                              if (_emojiOpen || _plusOpen) {
                                setState(() {
                                  _emojiOpen = false;
                                  _plusOpen = false;
                                });
                              }
                            },
                            decoration: InputDecoration(
                              hintText: '说点什么…',
                              filled: true,
                              fillColor: Colors.white,
                              isDense: true,
                              contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 9),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(6),
                                borderSide:
                                    const BorderSide(color: kDimiHairline),
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(6),
                                borderSide:
                                    const BorderSide(color: kDimiHairline),
                              ),
                            ),
                            onSubmitted: (_) => _send(),
                          ),
                  ),
                  IconButton(
                    onPressed: _voiceMode ? null : _toggleEmojiPanel,
                    icon: Icon(
                      _emojiOpen
                          ? Icons.keyboard_outlined
                          : Icons.emoji_emotions_outlined,
                      color: kDimiGray66,
                    ),
                    tooltip: '表情',
                  ),
                  // 微信行为：有文字时 ⊕ 让位给发送；语音模式下 ⊕ 常显
                  if (!_voiceMode && _hasText)
                    Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: FilledButton(
                        onPressed: _sending ? null : _send,
                        style: FilledButton.styleFrom(
                          backgroundColor: kDimiPrimaryFill,
                          foregroundColor: kDimiPrimary,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 9),
                          minimumSize: Size.zero,
                        ),
                        child: const Text('发送'),
                      ),
                    )
                  else
                    IconButton(
                      onPressed: _togglePlusPanel,
                      icon: const Icon(Icons.add_circle_outline_rounded,
                          color: kDimiGray66),
                      tooltip: '更多',
                    ),
                ],
              ),
            ),
          ),
          // 表情面板（微信式网格，点选插入光标处）
          if (_emojiOpen) _EmojiPanel(onSelect: _insertEmoji),
          // 功能面板（⊕）：图片/视频等已实现的发送能力入口
          if (_plusOpen)
            _PlusPanel(
              sendingImage: _sendingImage,
              sendingVideo: _sendingVideo,
              onPickImage: _sendImage,
              onPickVideo: _pickVideoSource,
              onSendRedPacket: () {
                setState(() => _plusOpen = false);
                _showRedPacketSheet();
              },
            ),
        ],
      ),
    );
  }
}

/// 空会话破冰卡（服务端通过申请时自动生成交集破冰消息，此处为兜底展示）：
/// kDimiPrimarySoft 浅底圆角卡 + 挥手图标 + 分级文案
class _IceBreakCard extends StatelessWidget {
  const _IceBreakCard({this.banner});

  final String? banner;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        margin: const EdgeInsets.all(24),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        decoration: BoxDecoration(
          color: kDimiPrimarySoft,
          borderRadius: BorderRadius.circular(kDimiRadiusCard),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.waving_hand_outlined,
                size: 32, color: kDimiPrimary),
            const SizedBox(height: kDimiSpace12),
            Text(
              banner ?? '你们已成为好友',
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  color: kDimiText,
                  height: 1.5),
            ),
            const SizedBox(height: kDimiSpace4),
            const Text(
              '打个招呼吧，聊聊当年的事',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 15, color: kDimiGray66, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }
}

/// 首屏加载骨架行：头像方块 + 气泡灰条，mine 时右对齐模拟自己发的消息
class _SkeletonBubble extends StatelessWidget {
  const _SkeletonBubble(
      {required this.width, this.mine = false, this.tall = false});

  final double width;

  /// 是否模拟自己发送的气泡（右对齐）
  final bool mine;

  /// 加高气泡条，模拟多行文本
  final bool tall;

  @override
  Widget build(BuildContext context) {
    const avatar =
        DimiSkeleton(width: 40, height: 40, radius: kDimiRadiusAvatar);
    final bubble = DimiSkeleton(
        width: width, height: tall ? 64 : 40, radius: kDimiRadiusBubble);
    return Row(
      mainAxisAlignment: mine ? MainAxisAlignment.end : MainAxisAlignment.start,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: mine
          ? [bubble, const SizedBox(width: kDimiSpace8), avatar]
          : [avatar, const SizedBox(width: kDimiSpace8), bubble],
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble(
      {required this.message,
      this.myUserId,
      this.onRecall,
      this.isPlaying = false,
      this.onPlay,
      this.isGroup = false,
      this.onOpenRedPacket});

  final Message message;
  final int? myUserId;
  final VoidCallback? onRecall;

  /// 语音消息：是否正在播放本条 / 点击播放回调
  final bool isPlaying;
  final VoidCallback? onPlay;

  /// 群会话：他人气泡上方显示发送者昵称
  final bool isGroup;

  /// 红包卡：点按拆开/查看详情（传 packet_id）
  final ValueChanged<String>? onOpenRedPacket;

  /// 群聊中他人气泡上方显示发送者昵称（小字灰色）；单聊/自己消息原样返回
  Widget _wrapSender(bool isMe, UserBrief? sender, Widget bubble) {
    if (!isGroup || isMe) return bubble;
    final name = sender?.realName ?? sender?.nickname ?? '';
    if (name.isEmpty) return bubble;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 2, bottom: 2),
          child: Text(name,
              style: const TextStyle(fontSize: 13, color: kDimiGray99)),
        ),
        bubble,
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    // 系统消息（如「你们已成为好友」）：主色浅底胶囊
    if (message.isSystem) {
      return Center(
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 8),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(
            color: kDimiPrimarySoft,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            displayMessageText(message.msgType, message.content),
            style: const TextStyle(fontSize: 14, color: kDimiGray66),
          ),
        ),
      );
    }
    final isMe = myUserId != null && message.sender?.userId == myUserId;
    final sender = message.sender;
    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: kDimiSpace12, vertical: kDimiSpace8),
      child: Row(
        mainAxisAlignment:
            isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isMe) ...[
            DimiAvatar(
              name: sender?.nickname,
              avatarUrl: sender?.avatarUrl,
              size: 40,
              seed: sender?.userId,
            ),
            const SizedBox(width: kDimiSpace8),
          ],
          Flexible(
            child: _wrapSender(
              isMe,
              sender,
              GestureDetector(
                // 长按自己的消息可撤回（2 分钟内，契约 /messages/{id}/recall）
                onLongPress:
                    isMe && message.status != 'recalled' ? onRecall : null,
                child: Builder(builder: (context) {
                  final isImage = message.msgType == 'image' &&
                      message.status != 'recalled';
                  final isVoice = message.msgType == 'voice' &&
                      message.status != 'recalled';
                  final voice =
                      isVoice ? _parseVoiceContent(message.content) : null;
                  final isVideo = message.msgType == 'video' &&
                      message.status != 'recalled';
                  final videoUrl =
                      isVideo ? _parseVideoUrl(message.content) : null;
                  final isRedPacket = message.msgType == 'red_packet' &&
                      message.status != 'recalled';
                  final rpContent = isRedPacket
                      ? RedPacketContent.tryParse(message.content)
                      : null;
                  return Container(
                    // 气泡限宽屏宽 72%，长文本留呼吸感
                    constraints: BoxConstraints(
                        maxWidth: MediaQuery.of(context).size.width * 0.72),
                    // 图片/视频/红包气泡去掉内边距，圆角贴边更美观
                    padding: (isImage || isVideo || isRedPacket)
                        ? EdgeInsets.zero
                        : const EdgeInsets.symmetric(
                            horizontal: kDimiSpace12, vertical: kDimiSpace10),
                    decoration: BoxDecoration(
                      color: isMe ? kDimiPrimarySoft : Colors.white,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: message.status == 'recalled'
                        ? const Text('消息已撤回',
                            style: TextStyle(
                                fontSize: 15,
                                color: kDimiGray99,
                                fontStyle: FontStyle.italic))
                        : isRedPacket
                            ? (rpContent == null
                                ? const Padding(
                                    padding: EdgeInsets.symmetric(
                                        horizontal: kDimiSpace12,
                                        vertical: kDimiSpace10),
                                    child: Text('[红包]',
                                        style: TextStyle(
                                            fontSize: 15, color: kDimiGray99)),
                                  )
                                : _RedPacketCard(
                                    content: rpContent,
                                    onTap: () => onOpenRedPacket
                                        ?.call(rpContent.packetId),
                                  ))
                            : isVoice
                                ? (voice == null
                                    ? const Text('[语音]',
                                        style: TextStyle(
                                            fontSize: 15, color: kDimiGray99))
                                    : _VoiceMessageContent(
                                        duration: voice.duration,
                                        isPlaying: isPlaying,
                                        onTap: onPlay,
                                      ))
                                : isVideo
                                    ? (videoUrl == null
                                        ? const Padding(
                                            padding: EdgeInsets.symmetric(
                                                horizontal: kDimiSpace12,
                                                vertical: kDimiSpace10),
                                            child: Text('[视频]',
                                                style: TextStyle(
                                                    fontSize: 15,
                                                    color: kDimiGray99)),
                                          )
                                        : _VideoMessageContent(url: videoUrl))
                                    : isImage
                                        ? _ImageMessageContent(
                                            url: message.content)
                                        : Text(
                                            message.content,
                                            style: const TextStyle(
                                                fontSize: 16,
                                                color: kDimiText,
                                                height: 1.5),
                                          ),
                  );
                }),
              ),
            ),
          ),
          if (isMe) ...[
            const SizedBox(width: kDimiSpace8),
            DimiAvatar(
              name: sender?.nickname ?? '我',
              avatarUrl: sender?.avatarUrl,
              size: 40,
              seed: sender?.userId,
            ),
          ],
        ],
      ),
    );
  }
}

/// 图片消息气泡：限宽 200 圆角缩略图，点击全屏查看（可缩放）
class _ImageMessageContent extends StatelessWidget {
  const _ImageMessageContent({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    final fullUrl = ApiConfig.resolveMediaUrl(url);
    return GestureDetector(
      onTap: () => _showFullImage(context, fullUrl),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: CachedNetworkImage(
          imageUrl: fullUrl,
          width: 200,
          fit: BoxFit.cover,
          placeholder: (_, __) => const SizedBox(
            width: 200,
            height: 140,
            child: Center(
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: kDimiPrimary),
            ),
          ),
          errorWidget: (_, __, ___) => const SizedBox(
            width: 200,
            height: 140,
            child: Center(
              child: Icon(Icons.broken_image_outlined,
                  size: 32, color: kDimiGrayCC),
            ),
          ),
        ),
      ),
    );
  }

  void _showFullImage(BuildContext context, String url) {
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.black,
        insetPadding: EdgeInsets.zero,
        child: GestureDetector(
          onTap: () => Navigator.of(ctx).pop(),
          child: InteractiveViewer(
            maxScale: 5,
            child: Center(
              child: CachedNetworkImage(
                imageUrl: url,
                fit: BoxFit.contain,
                errorWidget: (_, __, ___) => const Icon(
                    Icons.broken_image_outlined,
                    size: 48,
                    color: Colors.white54),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 表情面板：常用 emoji 网格（微信式 8 列），点选回调插入输入框
class _EmojiPanel extends StatelessWidget {
  const _EmojiPanel({required this.onSelect});

  final ValueChanged<String> onSelect;

  static const List<String> emojis = [
    '😀',
    '😁',
    '😂',
    '🤣',
    '😃',
    '😄',
    '😅',
    '😆',
    '😉',
    '😊',
    '😋',
    '😎',
    '😍',
    '😘',
    '🥰',
    '😗',
    '😙',
    '😚',
    '🙂',
    '🤗',
    '🤩',
    '🤔',
    '🤨',
    '😐',
    '😑',
    '😶',
    '🙄',
    '😏',
    '😣',
    '😥',
    '😮',
    '🤐',
    '😯',
    '😪',
    '😫',
    '🥱',
    '😴',
    '😌',
    '😛',
    '😜',
    '😝',
    '🤤',
    '😒',
    '😓',
    '😔',
    '😕',
    '🙃',
    '🤑',
    '😲',
    '🙁',
    '😖',
    '😞',
    '😟',
    '😤',
    '😢',
    '😭',
    '😦',
    '😧',
    '😨',
    '😩',
    '🤯',
    '😬',
    '😰',
    '😱',
    '🥵',
    '🥶',
    '😳',
    '🤪',
    '😵',
    '😡',
    '😠',
    '🤬',
    '😷',
    '🤒',
    '🤕',
    '🤢',
    '🤮',
    '🥴',
    '😇',
    '🥳',
    '👍',
    '👎',
    '👌',
    '✌️',
    '🤞',
    '🤟',
    '🤘',
    '👏',
    '🙌',
    '🙏',
    '🤝',
    '💪',
    '❤️',
    '💔',
    '💯',
    '🎉',
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 220,
      color: kDimiBg,
      child: SafeArea(
        top: false,
        child: GridView.builder(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 8,
          ),
          itemCount: emojis.length,
          itemBuilder: (_, i) => InkWell(
            onTap: () => onSelect(emojis[i]),
            borderRadius: BorderRadius.circular(6),
            child: Center(
              child: Text(emojis[i], style: const TextStyle(fontSize: 22)),
            ),
          ),
        ),
      ),
    );
  }
}

/// 功能面板（⊕，与表情面板同区同高）：4 列网格，只放客户端已实现的
/// 发送能力入口——图片（相册选图）、视频（拍摄/相册）。新增能力在此加项。
class _PlusPanel extends StatelessWidget {
  const _PlusPanel({
    required this.sendingImage,
    required this.sendingVideo,
    required this.onPickImage,
    required this.onPickVideo,
    required this.onSendRedPacket,
  });

  final bool sendingImage;
  final bool sendingVideo;
  final VoidCallback onPickImage;
  final VoidCallback onPickVideo;
  final VoidCallback onSendRedPacket;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 220,
      color: kDimiBg,
      child: SafeArea(
        top: false,
        child: GridView.count(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
          crossAxisCount: 4,
          mainAxisSpacing: 16,
          crossAxisSpacing: 12,
          children: [
            _PlusPanelItem(
              icon: Icons.image_outlined,
              label: '图片',
              busy: sendingImage,
              onTap: onPickImage,
            ),
            _PlusPanelItem(
              icon: Icons.videocam_outlined,
              label: '视频',
              busy: sendingVideo,
              onTap: onPickVideo,
            ),
            _PlusPanelItem(
              icon: Icons.redeem,
              label: '红包',
              onTap: onSendRedPacket,
            ),
          ],
        ),
      ),
    );
  }
}

/// 功能面板单项：kDimiPrimarySoft 圆角底衬 + kDimiPrimary 图标 + 小字标签
class _PlusPanelItem extends StatelessWidget {
  const _PlusPanelItem({
    required this.icon,
    required this.label,
    required this.onTap,
    this.busy = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  /// 发送中：图标位显示 spinner，防重复点击
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: busy ? null : onTap,
      borderRadius: BorderRadius.circular(12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: kDimiPrimarySoft,
              borderRadius: BorderRadius.circular(12),
            ),
            alignment: Alignment.center,
            child: busy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: kDimiPrimary),
                  )
                : Icon(icon, size: 28, color: kDimiPrimary),
          ),
          const SizedBox(height: 6),
          Text(label, style: const TextStyle(fontSize: 13, color: kDimiGray66)),
        ],
      ),
    );
  }
}

/// 红包消息气泡卡：kDimiDanger→kDimiApricot 渐变底 + 红包图标 +
/// 祝福语 +「觅豆红包」小字（对齐微信红包气泡气质，全部用主题常量）
class _RedPacketCard extends StatelessWidget {
  const _RedPacketCard({required this.content, this.onTap});

  final RedPacketContent content;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 200,
        padding: const EdgeInsets.symmetric(
            horizontal: kDimiSpace12, vertical: kDimiSpace10),
        decoration: BoxDecoration(
          color: kDimiDangerSoft,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.redeem, color: kDimiDanger, size: 26),
                const SizedBox(width: kDimiSpace8),
                Expanded(
                  child: Text(
                    content.greeting == null || content.greeting!.isEmpty
                        ? '恭喜发财，大吉大利'
                        : content.greeting!,
                    style: const TextStyle(fontSize: 16, color: kDimiDanger),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: kDimiSpace8),
            const Text('觅豆红包',
                style: TextStyle(fontSize: 12, color: kDimiDanger)),
          ],
        ),
      ),
    );
  }
}

/// 发红包弹层：私聊只填金额+祝福语（固定普通红包 1 份）；
/// 群聊可选拼手气/普通 + 金额 + 个数 + 祝福语。
/// 提交走 POST /red-packets（幂等键），服务端同事务代发消息卡。
class _RedPacketSheet extends StatefulWidget {
  const _RedPacketSheet({required this.convId, required this.isGroup});

  final int convId;
  final bool isGroup;

  @override
  State<_RedPacketSheet> createState() => _RedPacketSheetState();
}

class _RedPacketSheetState extends State<_RedPacketSheet> {
  final _amountCtrl = TextEditingController();
  final _countCtrl = TextEditingController();
  final _greetingCtrl = TextEditingController();

  String _type = 'luck'; // 群聊默认拼手气；私聊固定 normal
  int? _balance;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _loadBalance();
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    _countCtrl.dispose();
    _greetingCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadBalance() async {
    try {
      final w = await context.read<DimiApi>().wallet();
      if (mounted) setState(() => _balance = w.balance);
    } on ApiException {
      // 余额拉取失败不阻塞（服务端兜底校验）
    }
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _submit() async {
    if (_submitting) return;
    final amount = int.tryParse(_amountCtrl.text.trim());
    final count =
        widget.isGroup ? int.tryParse(_countCtrl.text.trim()) : 1; // 私聊固定 1 份
    final type = widget.isGroup ? _type : 'normal';
    if (amount == null || amount <= 0) {
      _toast('请输入正确的红包金额（整数觅豆）');
      return;
    }
    if (count == null || count < 1) {
      _toast('请输入正确的红包个数');
      return;
    }
    if (widget.isGroup && type == 'luck' && count < 2) {
      _toast('拼手气红包至少 2 个');
      return;
    }
    setState(() => _submitting = true);
    try {
      await context.read<DimiApi>().sendRedPacket(
            convId: widget.convId,
            type: type,
            totalAmount: amount,
            count: count,
            greeting: _greetingCtrl.text.trim(),
          );
      if (mounted) Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (mounted) {
        setState(() => _submitting = false);
        _toast(e.message);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      // 键盘弹起时弹层整体上移
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Center(
                child: Text('发觅豆红包',
                    style:
                        TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
              ),
              const SizedBox(height: 16),
              if (widget.isGroup) ...[
                Row(
                  children: [
                    _typeChip('luck', '拼手气'),
                    const SizedBox(width: 10),
                    _typeChip('normal', '普通红包'),
                  ],
                ),
                const SizedBox(height: 12),
              ],
              TextField(
                controller: _amountCtrl,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: widget.isGroup ? '总金额' : '金额',
                  suffixText: '觅豆',
                  isDense: true,
                  border: const OutlineInputBorder(),
                ),
              ),
              if (widget.isGroup) ...[
                const SizedBox(height: 12),
                TextField(
                  controller: _countCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '红包个数',
                    suffixText: '个',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              TextField(
                controller: _greetingCtrl,
                maxLength: 20,
                decoration: const InputDecoration(
                  labelText: '祝福语',
                  hintText: '恭喜发财，大吉大利',
                  counterText: '',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              Text('我的余额：${_balance ?? '—'} 觅豆',
                  style: const TextStyle(fontSize: 14, color: kDimiGray99)),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _submitting ? null : _submit,
                  style: FilledButton.styleFrom(
                    backgroundColor: kDimiDangerSoft,
                    foregroundColor: kDimiDanger,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  child: Text(_submitting ? '发出中…' : '发出红包'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _typeChip(String value, String label) {
    final selected = _type == value;
    return Expanded(
      child: InkWell(
        onTap: () => setState(() => _type = value),
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 9),
          decoration: BoxDecoration(
            color: selected ? kDimiPrimarySoft : Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: selected ? kDimiPrimary : kDimiGrayCC),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 15,
              color: selected ? kDimiPrimary : kDimiGray66,
              fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
        ),
      ),
    );
  }
}

/// 语音消息 content 约定为 JSON {"url": "<媒体地址>", "duration": <秒>}，
/// 解析失败返回 null（气泡兜底显示 [语音]）
({String url, int duration})? _parseVoiceContent(String content) {
  try {
    final m = jsonDecode(content);
    if (m is Map && m['url'] is String) {
      return (url: m['url'] as String, duration: asInt(m['duration']) ?? 0);
    }
  } on Exception {
    // 非约定 JSON，走兜底
  }
  return null;
}

/// 语音气泡内容：播放/暂停图标 + 时长文案，宽度随时长 1–60s 映射 60–180px
class _VoiceMessageContent extends StatelessWidget {
  const _VoiceMessageContent({
    required this.duration,
    required this.isPlaying,
    this.onTap,
  });

  final int duration;
  final bool isPlaying;
  final VoidCallback? onTap;

  static double widthFor(int duration) =>
      60.0 + (duration.clamp(1, 60) - 1) * (120.0 / 59.0);

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: widthFor(duration),
        child: Row(
          children: [
            Icon(
              isPlaying ? Icons.pause : Icons.play_arrow,
              size: 20,
              color: kDimiPrimary,
            ),
            const SizedBox(width: 4),
            Text(
              '$duration″',
              style: const TextStyle(fontSize: 16, color: kDimiText),
            ),
          ],
        ),
      ),
    );
  }
}

/// 视频消息 content 约定为 JSON {"url": "<媒体地址>"}，
/// 解析失败返回 null（气泡兜底显示 [视频]）
String? _parseVideoUrl(String content) {
  try {
    final m = jsonDecode(content);
    if (m is Map && m['url'] is String) return m['url'] as String;
  } on Exception {
    // 非约定 JSON，走兜底
  }
  return null;
}

/// 视频气泡：200×120 精致占位——kDimiText→kDimiPrimary 对角渐变底 +
/// 居中白色圆形播放按钮（柔和阴影）+ 左下「视频」标签，点击全屏播放。
/// （Message 模型暂无封面字段，有封面后再换网络缩略图 cacheWidth: 480）
class _VideoMessageContent extends StatelessWidget {
  const _VideoMessageContent({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    final fullUrl = ApiConfig.resolveMediaUrl(url);
    return GestureDetector(
      onTap: () => showDialog<void>(
        context: context,
        builder: (_) => _VideoPlayerDialog(url: fullUrl),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(kDimiRadiusBubble),
        child: Container(
          width: 200,
          height: 120,
          decoration: const BoxDecoration(
            color: kDimiPrimary,
          ),
          child: Stack(
            children: [
              Center(
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.play_arrow,
                      size: 26, color: kDimiPrimary),
                ),
              ),
              const Positioned(
                left: 8,
                bottom: 6,
                child: Text('视频',
                    style: TextStyle(fontSize: 14, color: Colors.white70)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 视频全屏播放：按实际宽高比显示，点击播放/暂停，
/// 底部可拖动进度条，右上角关闭；关闭时释放 controller
class _VideoPlayerDialog extends StatefulWidget {
  const _VideoPlayerDialog({required this.url});

  final String url;

  @override
  State<_VideoPlayerDialog> createState() => _VideoPlayerDialogState();
}

class _VideoPlayerDialogState extends State<_VideoPlayerDialog> {
  late final VideoPlayerController _ctrl;
  bool _ctrlCreated = false;
  bool _initialized = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    final Uri uri;
    try {
      uri = Uri.parse(widget.url);
    } on FormatException {
      // URL 非法：直接置失败态，不创建 controller
      _failed = true;
      return;
    }
    _ctrl = VideoPlayerController.networkUrl(uri);
    _ctrlCreated = true;
    _ctrl.initialize().then((_) {
      if (!mounted) return;
      setState(() => _initialized = true);
      _ctrl.play();
    }).catchError((_) {
      if (mounted) setState(() => _failed = true);
    });
    // 播放中进度条与播放态刷新
    _ctrl.addListener(_onTick);
  }

  void _onTick() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    if (_ctrlCreated) {
      _ctrl.removeListener(_onTick);
      _ctrl.dispose();
    }
    super.dispose();
  }

  void _togglePlay() {
    if (!_initialized) return;
    setState(() {
      _ctrl.value.isPlaying ? _ctrl.pause() : _ctrl.play();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.black,
      insetPadding: EdgeInsets.zero,
      child: Stack(
        children: [
          Center(
            child: _failed
                ? const Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.broken_image_outlined,
                          size: 48, color: Colors.white54),
                      SizedBox(height: 8),
                      Text('视频加载失败',
                          style:
                              TextStyle(color: Colors.white70, fontSize: 15)),
                    ],
                  )
                : !_initialized
                    ? const CircularProgressIndicator(color: Colors.white)
                    : GestureDetector(
                        onTap: _togglePlay,
                        child: AspectRatio(
                          aspectRatio: _ctrl.value.aspectRatio,
                          child: VideoPlayer(_ctrl),
                        ),
                      ),
          ),
          if (_initialized)
            Positioned(
              left: 0,
              right: 0,
              bottom: 24,
              child: VideoProgressIndicator(
                _ctrl,
                allowScrubbing: true,
                padding: const EdgeInsets.symmetric(horizontal: 16),
              ),
            ),
          Positioned(
            top: 8,
            right: 8,
            child: SafeArea(
              child: IconButton(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close, color: Colors.white),
                tooltip: '关闭',
              ),
            ),
          ),
          if (_initialized && !_ctrl.value.isPlaying)
            const Center(
              child: IgnorePointer(
                child: Icon(Icons.play_circle_outline,
                    size: 64, color: Colors.white70),
              ),
            ),
        ],
      ),
    );
  }
}
