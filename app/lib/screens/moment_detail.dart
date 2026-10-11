// Article-style detail, shared by personal posts and long-form articles.
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../api/client.dart';
import '../api/models.dart';
import '../widgets/article_reader.dart';
import '../widgets/article_interactions.dart';
import '../widgets/common/dimi_error_view.dart';
import '../widgets/gift_sheet.dart';
import '../widgets/report_dialog.dart';
import 'profile_card.dart';

class MomentDetailScreen extends StatefulWidget {
  const MomentDetailScreen({super.key, required this.momentId});
  final int momentId;
  @override
  State<MomentDetailScreen> createState() => _MomentDetailScreenState();
}

class _MomentDetailScreenState extends State<MomentDetailScreen> {
  final _commentFocus = FocusNode();
  Moment? _moment;
  MomentGifts? _gifts;
  bool _loading = true, _likeBusy = false, _giftBusy = false;
  String? _error, _giftsError, _commentsError;
  DimiApi get _api => context.read<DimiApi>();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _commentFocus.dispose();
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
    try {
      final m = await _api.momentDetail(widget.momentId);
      if (!mounted) return;
      setState(() => _moment = m);
      unawaited(_loadGifts());
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _refreshComments() async {
    try {
      final m = await _api.momentDetail(widget.momentId);
      if (mounted) {
        setState(() {
          _moment = m;
          _commentsError = null;
        });
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _commentsError = e.message);
    }
  }

  Future<void> _loadGifts() async {
    try {
      final g = await _api.momentGifts(widget.momentId);
      if (mounted) {
        setState(() {
          _gifts = g;
          _giftsError = null;
        });
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _giftsError = e.message);
    }
  }

  Future<void> _toggleLike() async {
    final m = _moment;
    if (m == null || _likeBusy) return;
    final wasLiked = m.liked;
    final priorCount = m.likeCount;
    setState(() {
      _likeBusy = true;
      m.liked = !wasLiked;
      m.likeCount = (priorCount + (wasLiked ? -1 : 1)).clamp(0, 1 << 30);
    });
    try {
      if (wasLiked) {
        await _api.unlikeMoment(m.momentId);
      } else {
        await _api.likeMoment(m.momentId);
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        m.liked = wasLiked;
        m.likeCount = priorCount;
      });
      _toast(e.message);
    } finally {
      if (mounted) setState(() => _likeBusy = false);
    }
  }

  Future<void> _gift() async {
    if (_giftBusy) return;
    setState(() => _giftBusy = true);
    try {
      await showMomentGiftSheet(context, widget.momentId,
          onSuccess: _loadGifts);
    } finally {
      if (mounted) setState(() => _giftBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.white,
        appBar: AppBar(
            title: Text(_moment?.contentType == 'article' ? '文章详情' : '动态详情'),
            actions: [
              if (_moment != null && !_moment!.isOwn && _error == null)
                IconButton(
                    tooltip: '举报内容',
                    icon: const Icon(Icons.flag_outlined),
                    onPressed: () => showReportDialog(context,
                        targetType: 'moment', targetId: widget.momentId)),
            ]),
        body: _buildBody(),
        bottomNavigationBar: _moment == null || _error != null || _loading
            ? null
            : ArticleCommentInput(
                focusNode: _commentFocus,
                onSend: (text, key) async {
                  await _api.commentMoment(widget.momentId, text,
                      requestKey: key);
                  if (mounted) await _refreshComments();
                }),
      );

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return DimiErrorView(message: _error!, onRetry: _load);
    final m = _moment!;
    final text = m.content ?? '';
    final isArticle = m.contentType == 'article';
    return ListView(key: const PageStorageKey('moment-article'), children: [
      ArticleContent(
          title: isArticle ? articleTitle(text) : '',
          body: isArticle ? articleText(text) : text,
          media: m.media,
          author: m.author,
          createdAt: m.createdAt,
          metadata: m.visibilityLabel,
          label: isArticle ? '个人文章' : null,
          onAuthorTap: m.author == null
              ? null
              : () => ProfileCardScreen.open(context, m.author!.userId)),
      ArticleActions(
          liked: m.liked,
          likeCount: m.likeCount,
          onLike: _likeBusy ? null : _toggleLike,
          onComment: () => _commentFocus.requestFocus(),
          onGift: m.isOwn || _giftBusy ? null : _gift),
      ArticleGiftSummary(
          gifts: _gifts, error: _giftsError, onRetry: _loadGifts),
      ArticleComments(
          comments: m.comments,
          totalCount: m.commentCount,
          error: _commentsError,
          onRetry: _refreshComments),
    ]);
  }
}
