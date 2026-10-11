import 'package:flutter/material.dart';
import '../api/client.dart';
import '../api/models.dart';
import '../theme.dart';
import 'dimi_avatar.dart';
import 'moment_card.dart' show formatMomentTime;

class ArticleActions extends StatelessWidget {
  const ArticleActions(
      {super.key,
      required this.liked,
      required this.likeCount,
      required this.onLike,
      required this.onComment,
      this.onGift});
  final bool liked;
  final int likeCount;
  final VoidCallback? onLike, onGift;
  final VoidCallback onComment;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: Column(children: [
          const Divider(height: 24),
          Wrap(
              alignment: WrapAlignment.center,
              spacing: 12,
              runSpacing: 8,
              children: [
                Semantics(
                    toggled: liked,
                    child: TextButton.icon(
                        onPressed: onLike,
                        icon: Icon(
                            liked
                                ? Icons.favorite_rounded
                                : Icons.favorite_border_rounded,
                            color: liked ? kDimiDanger : kDimiPrimary),
                        label: Text('${liked ? '已赞' : '点赞'} $likeCount'))),
                TextButton.icon(
                    onPressed: onComment,
                    icon: const Icon(Icons.chat_bubble_outline),
                    label: const Text('写评论')),
                if (onGift != null)
                  FilledButton.icon(
                      onPressed: onGift,
                      icon: const Icon(Icons.volunteer_activism_outlined),
                      label: const Text('打赏作者')),
              ]),
        ]),
      );
}

class ArticleGiftSummary extends StatelessWidget {
  const ArticleGiftSummary({super.key, this.gifts, this.error, this.onRetry});
  final MomentGifts? gifts;
  final String? error;
  final VoidCallback? onRetry;
  @override
  Widget build(BuildContext context) {
    if (error != null) {
      return TextButton(onPressed: onRetry, child: const Text('打赏记录加载失败，点击重试'));
    }
    if (gifts == null || gifts!.totalCount == 0) return const SizedBox.shrink();
    return Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: Column(children: [
          Text('${gifts!.totalCount} 人次送出心意 · ${gifts!.totalCoins} 觅豆',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 14, color: kDimiGray66)),
          const SizedBox(height: 10),
          Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: gifts!.items
                  .take(8)
                  .map((g) => Tooltip(
                      message: '${g.displayName} · ${g.coinAmount} 觅豆',
                      child: DimiAvatar(
                          name: g.displayName,
                          avatarUrl: g.fromUser?.avatarUrl,
                          seed: g.fromUser?.userId,
                          size: 32)))
                  .toList()),
        ]));
  }
}

class ArticleComments extends StatelessWidget {
  const ArticleComments(
      {super.key,
      required this.comments,
      required this.totalCount,
      this.loading = false,
      this.error,
      this.onRetry,
      this.onMore,
      this.onDelete,
      this.onReport});
  final List<MomentComment> comments;
  final int totalCount;
  final bool loading;
  final String? error;
  final VoidCallback? onRetry, onMore;
  final void Function(MomentComment)? onDelete, onReport;

  @override
  Widget build(BuildContext context) => Container(
        color: kDimiBg,
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('评论 $totalCount',
              style:
                  const TextStyle(fontSize: 19, fontWeight: FontWeight.w600)),
          const SizedBox(height: 12),
          if (!loading && error == null && comments.isEmpty)
            const Padding(
                padding: EdgeInsets.symmetric(vertical: 20),
                child: Text('还没有评论，聊聊你的感受吧',
                    style: TextStyle(fontSize: 16, color: kDimiGray99))),
          for (final c in comments)
            Padding(
                padding: const EdgeInsets.symmetric(vertical: 14),
                child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      DimiAvatar(
                          name: c.displayName,
                          avatarUrl: c.fromUser?.avatarUrl,
                          seed: c.fromUser?.userId,
                          size: 32),
                      const SizedBox(width: 10),
                      Expanded(
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                            Text(c.displayName,
                                style: const TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w500,
                                    color: kDimiPrimary)),
                            const SizedBox(height: 6),
                            if (c.replyToName != null)
                              Text('回复 ${c.replyToName}',
                                  style: const TextStyle(
                                      fontSize: 14, color: kDimiGray66)),
                            SelectableText(c.content,
                                style: const TextStyle(
                                    fontSize: 17, height: 1.65)),
                            const SizedBox(height: 6),
                            Text(formatMomentTime(c.createdAt),
                                style: const TextStyle(
                                    fontSize: 14, color: kDimiGray99)),
                          ])),
                      if ((c.canDelete && onDelete != null) || onReport != null)
                        PopupMenuButton<String>(
                            tooltip: '评论操作',
                            onSelected: (value) {
                              if (value == 'delete') {
                                onDelete?.call(c);
                              } else {
                                onReport?.call(c);
                              }
                            },
                            itemBuilder: (_) => [
                                  if (c.canDelete && onDelete != null)
                                    const PopupMenuItem(
                                        value: 'delete', child: Text('删除评论')),
                                  if (onReport != null)
                                    const PopupMenuItem(
                                        value: 'report', child: Text('举报评论')),
                                ]),
                    ])),
          if (loading)
            const Center(
                child: Padding(
                    padding: EdgeInsets.all(12),
                    child: CircularProgressIndicator())),
          if (error != null) ...[
            Text(error!, style: const TextStyle(color: kDimiGray66)),
            TextButton(onPressed: onRetry, child: const Text('重试评论加载')),
          ] else if (!loading && onMore != null)
            Center(
                child:
                    TextButton(onPressed: onMore, child: const Text('查看更多评论'))),
        ]),
      );
}

/// The same request key survives an uncertain network result and a manual retry.
class ArticleCommentInput extends StatefulWidget {
  const ArticleCommentInput(
      {super.key, required this.onSend, required this.focusNode});
  final Future<void> Function(String text, String requestKey) onSend;
  final FocusNode focusNode;
  @override
  State<ArticleCommentInput> createState() => _ArticleCommentInputState();
}

class _ArticleCommentInputState extends State<ArticleCommentInput> {
  final _controller = TextEditingController();
  bool _sending = false;
  String? _requestKey, _lastText;
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _sending) return;
    if (_lastText != text) {
      _requestKey = newIdempotencyKey();
      _lastText = text;
    }
    setState(() => _sending = true);
    try {
      await widget.onSend(text, _requestKey!);
      if (!mounted) return;
      _controller.clear();
      _lastText = null;
      _requestKey = null;
      widget.focusNode.unfocus();
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('评论已发送')));
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding:
            EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: Material(
            color: Colors.white,
            child: SafeArea(
                top: false,
                child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                    child: Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Expanded(
                              child: TextField(
                                  controller: _controller,
                                  focusNode: widget.focusNode,
                                  readOnly: _sending,
                                  maxLength: 500,
                                  minLines: 1,
                                  maxLines: 4,
                                  textInputAction: TextInputAction.newline,
                                  style: const TextStyle(fontSize: 17),
                                  decoration: const InputDecoration(
                                      hintText: '写下你的评论…',
                                      counterText: '',
                                      contentPadding: EdgeInsets.symmetric(
                                          horizontal: 12, vertical: 12)))),
                          const SizedBox(width: 8),
                          FilledButton(
                              onPressed: _sending ? null : _send,
                              child: Text(_sending ? '发送中' : '发送')),
                        ])))),
      );
}
