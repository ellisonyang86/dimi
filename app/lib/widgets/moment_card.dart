/// 朋友圈动态卡片：头像 + 署名 + 时间 + 内容（超 6 行折叠「全文」）
/// + 媒体九宫格（1/2/4 张特殊列数，点击全屏预览）
/// + 微信式互动：右侧「···」弹「赞/评论」浅色小气泡；点赞行（♥ N 人）
///   与可见评论逐条收进灰底圆角区块；「评论」就地展开输入框，不跳详情页。
/// feed、详情、相册页共用（相册页不传互动回调时「···」自动隐藏，纯浏览）。
/// 注：服务端 momentOut 暂只下发 like_count/liked（无点赞名单），
/// 点赞行先以「你 等 N 人觉得很赞」的计数形态渲染，名单字段待服务端补。
library;

import 'package:flutter/material.dart';

import '../api/models.dart';
import '../theme.dart';
import 'dimi_avatar.dart';
import 'article_format.dart';

/// 时间格式（对齐会话列表风格）：今天 HH:mm，当年 M月D日，跨年 yyyy/M/d
String formatMomentTime(String? iso) {
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

class MomentCard extends StatefulWidget {
  const MomentCard({
    super.key,
    required this.moment,
    this.onTap,
    this.onLongPress,
    this.onToggleLike,
    this.onComment,
    this.onSendComment,
    this.onViewAllComments,
    this.onDelete,
    this.onGift,
    this.expandContent = false,
    this.separator = true,
    this.onAuthorTap,
  });

  final Moment moment;
  final VoidCallback? onTap;

  /// 长按（他人的动态）：弹出举报入口
  final VoidCallback? onLongPress;

  /// 气泡菜单「赞 / 取消」回调（外层做乐观更新）
  final VoidCallback? onToggleLike;

  /// 气泡菜单「评论」回调：仅当 onSendComment 为空时生效
  /// （详情页用来聚焦底部既有输入框；feed 走 onSendComment 就地展开）
  final VoidCallback? onComment;

  /// 就地评论发送：非空时点「评论」在卡片下方展开输入框；
  /// 外层负责发帖并回灌数据，抛异常时输入框保留文本便于重发
  final Future<void> Function(String content)? onSendComment;

  /// 「查看全部评论」入口（feed 预览可能截断时显示，一般跳详情页）
  final VoidCallback? onViewAllComments;

  /// 自己的动态显示 ⋯ 删除入口
  final VoidCallback? onDelete;

  /// 他人的动态显示「赏」打赏入口（服务端禁止打赏自己的动态）
  final VoidCallback? onGift;

  /// 详情页传 true：内容不折叠、评论区由详情页独立渲染
  /// （卡片内只保留点赞行，不重复渲染评论）
  final bool expandContent;

  /// 卡片底部 8px kDimiBg 间隔带（feed/相册沉浸式分隔）；详情页传 false
  final bool separator;

  /// 点击作者头像/昵称（进资料卡）；null 则不可点
  final VoidCallback? onAuthorTap;

  @override
  State<MomentCard> createState() => _MomentCardState();
}

class _MomentCardState extends State<MomentCard> {
  final _commentCtrl = TextEditingController();
  final _commentFocus = FocusNode();

  /// 就地评论输入框是否展开
  bool _commenting = false;

  /// 发送在途门闩：防连点重复提交
  bool _sending = false;

  Moment get m => widget.moment;

  @override
  void dispose() {
    _commentCtrl.dispose();
    _commentFocus.dispose();
    super.dispose();
  }

  /// 卡片内可见评论：详情数据（comments）优先，否则 feed 预览（≤3 条）
  List<MomentComment> get _visibleComments =>
      m.comments.isNotEmpty ? m.comments : m.commentPreview;

  /// 是否有点赞/评论互动内容可展示
  bool get _hasInteractions =>
      m.likeCount > 0 || (!widget.expandContent && _visibleComments.isNotEmpty);

  /// 「···」是否可用：无任何互动回调时（如相册页）隐藏，保持纯浏览
  bool get _hasActionMenu =>
      widget.onToggleLike != null ||
      widget.onSendComment != null ||
      widget.onComment != null;

  /// 弹出微信同款浅色小气泡（赞 / 评论），定位在按钮上方
  Future<void> _showActionMenu(BuildContext btnCtx) async {
    final overlay =
        Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
    final box = btnCtx.findRenderObject()! as RenderBox;
    final topLeft = box.localToGlobal(Offset.zero, ancestor: overlay);
    final menuWidth =
        (widget.onToggleLike != null && _canComment) ? 184.0 : 96.0;
    final position = RelativeRect.fromLTRB(
      topLeft.dx + box.size.width - menuWidth,
      topLeft.dy - 56,
      overlay.size.width - topLeft.dx - box.size.width,
      overlay.size.height - topLeft.dy,
    );
    final action = await showMenu<String>(
      context: context,
      position: position,
      elevation: 0,
      color: kDimiPrimarySoft,
      menuPadding: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      items: [
        _ActionBubbleEntry(
          liked: m.liked,
          showLike: widget.onToggleLike != null,
          showComment: _canComment,
        ),
      ],
    );
    if (!mounted || action == null) return;
    if (action == 'like') {
      widget.onToggleLike?.call();
    } else if (action == 'comment') {
      _openComment();
    }
  }

  bool get _canComment =>
      widget.onSendComment != null || widget.onComment != null;

  /// 点「评论」：feed 就地展开输入框；详情页（无 onSendComment）聚焦底部输入框
  void _openComment() {
    if (widget.onSendComment != null) {
      setState(() => _commenting = true);
      _commentFocus.requestFocus();
    } else {
      widget.onComment?.call();
    }
  }

  /// 就地发送：交给外层发帖；外层抛异常时保留文本与展开态，便于重发
  Future<void> _sendInline() async {
    final text = _commentCtrl.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await widget.onSendComment!(text);
      if (!mounted) return;
      setState(() {
        _commentCtrl.clear();
        _commenting = false;
      });
      _commentFocus.unfocus();
    } on Exception {
      // 外层已 toast 失败原因（含 45001 内容拦截），这里仅保留输入
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// 回复对象昵称：优先用服务端下发的 reply_to_user 档案，
  /// 老数据缺失时在作者与可见评论名单中反查；查不到则不渲染回复关系
  String? _replyName(MomentComment c) {
    if (c.replyToName != null) return c.replyToName;
    final id = c.replyToUserId;
    if (id == null) return null;
    if (m.author?.userId == id) return m.authorName;
    for (final o in _visibleComments) {
      if (o.fromUser?.userId == id) return o.displayName;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final card = Material(
      color: Colors.white,
      child: InkWell(
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        child: Padding(
          padding: const EdgeInsets.all(kDimiSpace14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  // 作者行可点 → 资料卡（家乡页链路第一跳：动态→资料卡→家乡页）
                  Expanded(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: widget.onAuthorTap,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(minHeight: 48),
                        child: Row(
                          children: [
                            DimiAvatar(
                              name: m.authorName,
                              avatarUrl: m.author?.avatarUrl,
                              seed: m.author?.userId,
                              size: 36,
                            ),
                            const SizedBox(width: kDimiSpace10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(
                                    m.authorName,
                                    style: const TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w500,
                                        color: kDimiGray66),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  Text(
                                    '${formatMomentTime(m.createdAt)} · ${m.visibilityLabel}',
                                    style: const TextStyle(
                                        fontSize: 14, color: kDimiGray66),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (m.isOwn && widget.onDelete != null)
                    IconButton(
                      icon: const Icon(Icons.more_horiz,
                          size: 20, color: kDimiGray99),
                      onPressed: widget.onDelete,
                    ),
                ],
              ),
              if (m.content != null && m.content!.isNotEmpty) ...[
                const SizedBox(height: kDimiSpace10),
                if (m.contentType == 'article' && !widget.expandContent) ...[
                  Text(articleTitle(m.content!),
                      style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w600,
                          height: 1.5)),
                  const SizedBox(height: 8),
                  Text(articleExcerpt(articleText(m.content!)),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 17, height: 1.7)),
                  TextButton(
                      onPressed: widget.onTap, child: const Text('阅读全文')),
                ] else
                  _CollapsibleText(m.content!, expanded: widget.expandContent),
              ],
              if (m.media.isNotEmpty) ...[
                const SizedBox(height: kDimiSpace10),
                _MediaGrid(urls: m.media),
              ],
              if (m.locationPoi != null && m.locationPoi!.isNotEmpty) ...[
                const SizedBox(height: 6),
                Row(
                  children: [
                    const Icon(Icons.place_outlined,
                        size: 14, color: kDimiPrimary),
                    const SizedBox(width: 2),
                    Text(m.locationPoi!,
                        style:
                            const TextStyle(fontSize: 14, color: kDimiPrimary)),
                  ],
                ),
              ],
              const SizedBox(height: kDimiSpace8),
              _buildActionRow(),
              if (_hasInteractions) ...[
                const SizedBox(height: kDimiSpace8),
                _buildInteractionZone(),
              ],
              if (_commenting) ...[
                const SizedBox(height: kDimiSpace8),
                _buildInlineCommentInput(),
              ],
            ],
          ),
        ),
      ),
    );
    if (!widget.separator) return card;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        card,
        Container(height: kDimiSpace8, color: kDimiBg),
      ],
    );
  }

  /// 操作区（微信范式）：左侧「赏」入口，右侧「···」气泡按钮
  Widget _buildActionRow() {
    return Row(
      children: [
        if (!m.isOwn && widget.onGift != null)
          InkWell(
            onTap: widget.onGift,
            borderRadius: BorderRadius.circular(16),
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: Row(
                children: [
                  Icon(Icons.volunteer_activism_outlined,
                      size: 16, color: kDimiApricot),
                  SizedBox(width: kDimiSpace4),
                  Text('赏',
                      style: TextStyle(fontSize: 15, color: kDimiApricot)),
                ],
              ),
            ),
          ),
        const Spacer(),
        if (_hasActionMenu)
          Builder(
            builder: (btnCtx) => GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _showActionMenu(btnCtx),
              // 触控区 ≥48dp：视觉胶囊 34×26，外围透明留白补足
              child: SizedBox(
                width: 48,
                height: 48,
                child: Center(
                  child: Container(
                    width: 34,
                    height: 26,
                    decoration: BoxDecoration(
                      color: kDimiBg,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    alignment: Alignment.center,
                    child: const Icon(Icons.more_horiz,
                        size: 18, color: kDimiGray55),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// 互动区块（微信同款灰底圆角）：点赞行 + 可见评论逐条 + 查看全部
  Widget _buildInteractionZone() {
    final comments = _visibleComments;
    final showComments = !widget.expandContent && comments.isNotEmpty;
    // 「查看全部评论」：服务端下发 comment_count，比当前可见多则给入口进详情页
    final showViewAll = !widget.expandContent &&
        widget.onViewAllComments != null &&
        (m.commentCount > comments.length || comments.length >= 3);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(kDimiSpace10),
      decoration: BoxDecoration(
        color: kDimiBg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (m.likeCount > 0) ...[
            Row(
              children: [
                const Icon(Icons.favorite, size: 14, color: kDimiApricot),
                const SizedBox(width: kDimiSpace4),
                Expanded(
                  child: Text(
                    // 微信式名单「♥ 张三、李四」（服务端仅下发共同好友口径）；
                    // 乐观更新后名单未刷新时回落计数形态
                    m.likes.isNotEmpty
                        ? m.likes
                            .map((u) => u.realName ?? u.nickname ?? '未命名')
                            .join('、')
                        : (m.liked
                            ? (m.likeCount > 1
                                ? '你 等 ${m.likeCount} 人觉得很赞'
                                : '你觉得很赞')
                            : '${m.likeCount} 人觉得很赞'),
                    style: const TextStyle(fontSize: 15, color: kDimiGray55),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            if (showComments)
              Container(
                margin: const EdgeInsets.symmetric(vertical: 6),
                height: 0.5,
                color: const Color(0xFFE4E1DA),
              ),
          ],
          if (showComments)
            ...comments.map((c) {
              final replyName = _replyName(c);
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 1.5),
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: c.displayName,
                        style: const TextStyle(
                            fontSize: 15,
                            color: kDimiPrimary,
                            fontWeight: FontWeight.w500),
                      ),
                      if (replyName != null) ...[
                        const TextSpan(
                          text: ' 回复 ',
                          style: TextStyle(fontSize: 15, color: kDimiGray55),
                        ),
                        TextSpan(
                          text: replyName,
                          style: const TextStyle(
                              fontSize: 15,
                              color: kDimiPrimary,
                              fontWeight: FontWeight.w500),
                        ),
                      ],
                      const TextSpan(
                        text: '：',
                        style: TextStyle(fontSize: 15, color: kDimiGray55),
                      ),
                      TextSpan(
                        text: c.content,
                        style:
                            const TextStyle(fontSize: 15, color: kDimiGray55),
                      ),
                    ],
                  ),
                ),
              );
            }),
          if (showViewAll)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onViewAllComments,
              child: Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                    m.commentCount > comments.length
                        ? '查看全部 ${m.commentCount} 条评论'
                        : '查看全部评论',
                    style: const TextStyle(fontSize: 15, color: kDimiPrimary)),
              ),
            ),
        ],
      ),
    );
  }

  /// 就地评论输入框：微信式卡片内直发，不跳详情页
  Widget _buildInlineCommentInput() {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _commentCtrl,
            focusNode: _commentFocus,
            maxLength: 500,
            decoration: const InputDecoration(
              hintText: '评论',
              counterText: '',
              isDense: true,
              contentPadding:
                  EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            ),
          ),
        ),
        const SizedBox(width: kDimiSpace8),
        FilledButton(
          onPressed: _sending ? null : _sendInline,
          style: FilledButton.styleFrom(
            backgroundColor: kDimiPrimaryFill,
            foregroundColor: kDimiPrimary,
            minimumSize: const Size(64, 40),
            padding: const EdgeInsets.symmetric(horizontal: 16),
          ),
          child: Text(_sending ? '发送中' : '发送'),
        ),
      ],
    );
  }
}

/// 「赞 / 评论」深色气泡菜单项（微信朋友圈同款横排两格，单格时收窄）
class _ActionBubbleEntry extends PopupMenuEntry<String> {
  const _ActionBubbleEntry({
    required this.liked,
    required this.showLike,
    required this.showComment,
  });

  final bool liked;
  final bool showLike;
  final bool showComment;

  @override
  double get height => 48;

  @override
  bool represents(String? value) => value != null;

  @override
  State<_ActionBubbleEntry> createState() => _ActionBubbleEntryState();
}

class _ActionBubbleEntryState extends State<_ActionBubbleEntry> {
  Widget _cell(IconData icon, String label, String value) {
    return InkWell(
      onTap: () => Navigator.of(context).pop(value),
      child: SizedBox(
        height: widget.height,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 18, color: kDimiPrimary),
            const SizedBox(width: 6),
            Text(label,
                style: const TextStyle(fontSize: 16, color: kDimiPrimary)),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.showLike && widget.showComment ? 184 : 96,
      height: widget.height,
      child: Row(
        children: [
          if (widget.showLike)
            Expanded(
              child: _cell(
                widget.liked ? Icons.favorite : Icons.favorite_border,
                widget.liked ? '取消' : '赞',
                'like',
              ),
            ),
          if (widget.showLike && widget.showComment)
            Container(width: 0.5, height: 22, color: kDimiHairline),
          if (widget.showComment)
            Expanded(
              child: _cell(Icons.chat_bubble_outline, '评论', 'comment'),
            ),
        ],
      ),
    );
  }
}

/// 超 6 行折叠的长文本（「全文 / 收起」切换）
class _CollapsibleText extends StatefulWidget {
  const _CollapsibleText(this.text, {this.expanded = false});

  final String text;
  final bool expanded;

  @override
  State<_CollapsibleText> createState() => _CollapsibleTextState();
}

class _CollapsibleTextState extends State<_CollapsibleText> {
  late bool _expanded = widget.expanded;

  static const _style = TextStyle(fontSize: 18, height: 1.6, color: kDimiText);
  static const _maxLines = 6;

  bool _exceeds(double maxWidth) {
    final tp = TextPainter(
      text: TextSpan(text: widget.text, style: _style),
      maxLines: _maxLines,
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
    )..layout(maxWidth: maxWidth);
    return tp.didExceedMaxLines;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (ctx, constraints) {
        final overflow = _exceeds(constraints.maxWidth);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.text,
              style: _style,
              maxLines: _expanded ? null : _maxLines,
              overflow:
                  _expanded ? TextOverflow.visible : TextOverflow.ellipsis,
            ),
            if (overflow)
              GestureDetector(
                onTap: () => setState(() => _expanded = !_expanded),
                child: Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    _expanded ? '收起' : '全文',
                    style: const TextStyle(fontSize: 15, color: kDimiPrimary),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// 媒体九宫格：1 张单图限宽限高；2/4 张两列；其余三列。点击进入全屏预览。
class _MediaGrid extends StatelessWidget {
  const _MediaGrid({required this.urls});

  final List<String> urls;

  static const _spacing = 4.0;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (ctx, constraints) {
        // 对齐微信：多图网格只占内容宽约 2/3
        final gridWidth = constraints.maxWidth * 0.68;
        final cols = (urls.length == 2 || urls.length == 4) ? 2 : 3;
        final cell = (gridWidth - _spacing * (cols - 1)) / cols;
        if (urls.length == 1) {
          final w = gridWidth; // 单图与多图网格同宽，4:3 限高
          return GestureDetector(
            onTap: () => _openViewer(context, 0),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                width: w,
                child: AspectRatio(
                  aspectRatio: 4 / 3,
                  child: _netImage(urls[0]),
                ),
              ),
            ),
          );
        }
        return SizedBox(
          width: gridWidth,
          child: Wrap(
            spacing: _spacing,
            runSpacing: _spacing,
            children: [
              for (var i = 0; i < urls.length; i++)
                GestureDetector(
                  onTap: () => _openViewer(context, i),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: SizedBox(
                      width: cell,
                      height: cell,
                      child: _netImage(urls[i]),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  void _openViewer(BuildContext context, int index) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => _PhotoViewerPage(urls: urls, initialIndex: index),
    ));
  }

  Widget _netImage(String url) {
    return Image.network(
      url,
      fit: BoxFit.cover,
      cacheWidth: 300,
      loadingBuilder: (ctx, child, progress) {
        if (progress == null) return child;
        return Container(color: kDimiChatBg);
      },
      errorBuilder: (ctx, _, __) => Container(
        color: kDimiChatBg,
        alignment: Alignment.center,
        child: const Icon(Icons.broken_image_outlined,
            color: kDimiGrayBB, size: 28),
      ),
    );
  }
}

/// 全屏图片预览：黑底 PageView + 双指缩放，顶部「x/9」，点击关闭
class _PhotoViewerPage extends StatefulWidget {
  const _PhotoViewerPage({required this.urls, required this.initialIndex});

  final List<String> urls;
  final int initialIndex;

  @override
  State<_PhotoViewerPage> createState() => _PhotoViewerPageState();
}

class _PhotoViewerPageState extends State<_PhotoViewerPage> {
  late final PageController _ctrl =
      PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTap: () => Navigator.of(context).pop(),
        child: Stack(
          children: [
            PageView.builder(
              controller: _ctrl,
              itemCount: widget.urls.length,
              onPageChanged: (i) => setState(() => _index = i),
              itemBuilder: (ctx, i) => InteractiveViewer(
                child: Center(
                  child: Image.network(
                    widget.urls[i],
                    fit: BoxFit.contain,
                    cacheWidth: 1080,
                    errorBuilder: (ctx, _, __) => const Icon(
                        Icons.broken_image_outlined,
                        color: Colors.white54,
                        size: 48),
                  ),
                ),
              ),
            ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  '${_index + 1}/${widget.urls.length}',
                  style: const TextStyle(color: Colors.white, fontSize: 17),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
