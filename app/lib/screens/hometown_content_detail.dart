/// 家乡文章：原生长文排版、文末点赞/打赏、评论分页与输入。
/// GET 详情触发浏览去重计数；互动失败独立重试，不打断正文阅读。
library;

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../state/session.dart';
import '../theme.dart';
import '../widgets/common/dimi_error_view.dart';
import '../widgets/common/dimi_skeleton.dart';
import '../widgets/article_reader.dart';
import '../widgets/article_interactions.dart';
import '../widgets/gift_sheet.dart';
import '../widgets/report_dialog.dart';
import 'profile_card.dart';

class HometownContentDetailScreen extends StatefulWidget {
  const HometownContentDetailScreen({super.key, required this.contentId});

  final int contentId;

  @override
  State<HometownContentDetailScreen> createState() =>
      _HometownContentDetailScreenState();
}

class _HometownContentDetailScreenState
    extends State<HometownContentDetailScreen> {
  HometownContent? _content;
  bool _loading = true;
  String? _error;
  final _commentFocus = FocusNode();
  List<MomentComment> _comments = [];
  int _commentCount = 0;
  String? _nextCursor, _commentsError, _giftsError;
  MomentGifts? _gifts;
  bool _commentsLoading = false, _giftBusy = false;
  int _commentsGeneration = 0;

  @override
  void dispose() {
    _commentFocus.dispose();
    super.dispose();
  }

  Future<void> _loadComments({bool reset = true}) async {
    if (!reset && (_commentsLoading || _nextCursor == null)) return;
    final generation = ++_commentsGeneration;
    setState(() {
      _commentsLoading = true;
      _commentsError = null;
    });
    try {
      final page = await _api.hometownComments(widget.contentId,
          cursor: reset ? null : _nextCursor);
      if (!mounted || generation != _commentsGeneration) return;
      setState(() {
        final combined = reset ? page.items : [..._comments, ...page.items];
        _comments = {for (final c in combined) c.id: c}.values.toList();
        _commentCount = page.totalCount;
        _nextCursor = page.nextCursor;
      });
    } on ApiException catch (e) {
      if (mounted && generation == _commentsGeneration) {
        setState(() => _commentsError = e.message);
      }
    } finally {
      if (mounted && generation == _commentsGeneration) {
        setState(() => _commentsLoading = false);
      }
    }
  }

  Future<void> _loadGifts() async {
    try {
      final gifts = await _api.hometownGifts(widget.contentId);
      if (mounted) {
        setState(() {
          _gifts = gifts;
          _giftsError = null;
        });
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _giftsError = e.message);
    }
  }

  Future<void> _gift() async {
    if (_giftBusy || _deleting) return;
    setState(() => _giftBusy = true);
    try {
      await showHometownGiftSheet(context, widget.contentId,
          onSuccess: _loadGifts);
    } finally {
      if (mounted) setState(() => _giftBusy = false);
    }
  }

  Future<void> _deleteComment(MomentComment comment) async {
    final yes = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
              title: const Text('删除这条评论？'),
              content: const Text('删除后将不再展示。'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('取消')),
                TextButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('删除')),
              ],
            ));
    if (yes != true || !mounted || comment.id == null) return;
    try {
      await _api.deleteHometownComment(widget.contentId, comment.id!);
      if (mounted) await _loadComments();
    } on ApiException catch (e) {
      _toast(e.message);
    }
  }

  bool _likeBusy = false;
  bool _deleting = false;

  /// 41001 内容不存在为终态：渲染提示，不给重试按钮
  bool _gone = false;

  DimiApi get _api => context.read<DimiApi>();

  @override
  void initState() {
    super.initState();
    _load();
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
      _gone = false;
    });
    try {
      final c = await _api.hometownContentDetail(widget.contentId);
      if (!mounted) return;
      setState(() => _content = c);
      unawaited(_loadComments());
      unawaited(_loadGifts());
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _gone = e.code == ApiException.notFound;
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 点赞 / 取消点赞（乐观更新 + _likeBusy 门闩防连点漂移，失败回滚 + toast）；
  /// 成功后直接用服务端响应的 like_count/liked 覆盖本地值
  Future<void> _toggleLike() async {
    final c = _content;
    if (c == null || _likeBusy) return;
    final wasLiked = c.liked;
    setState(() {
      _likeBusy = true;
      c.liked = !wasLiked;
      c.likeCount += wasLiked ? -1 : 1;
    });
    try {
      final r = wasLiked
          ? await _api.unlikeHometownContent(c.contentId)
          : await _api.likeHometownContent(c.contentId);
      if (!mounted) return;
      setState(() {
        c.liked = r.liked;
        c.likeCount = r.likeCount;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        c.liked = wasLiked;
        c.likeCount += wasLiked ? 1 : -1;
      });
      _toast(e.message);
    } finally {
      if (mounted) setState(() => _likeBusy = false);
    }
  }

  Future<void> _delete() async {
    if (_deleting || _likeBusy) return;
    setState(() => _deleting = true);
    try {
      final confirmed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
                title: const Text('删除这条投稿？'),
                content: const Text('删除后，家乡页和分享页面都将不再展示，无法恢复。'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('取消')),
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('删除',
                          style: TextStyle(color: kDimiDanger))),
                ],
              ));
      if (confirmed != true || !mounted) return;
      await _api.deleteHometownContent(widget.contentId);
      if (mounted) Navigator.pop(context);
    } on ApiException catch (e) {
      _toast(e.message);
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final mine = _content?.author?.userId ==
        context.watch<Session>().currentUser?.userId;
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(title: const Text('家乡内容'), actions: [
        if (_content != null && !_gone)
          IconButton(
            tooltip: mine ? '删除投稿' : '举报投稿',
            icon: Icon(mine ? Icons.delete_outline : Icons.flag_outlined),
            onPressed: _deleting
                ? null
                : (mine
                    ? _delete
                    : () => showReportDialog(context,
                        targetType: 'hometown_content',
                        targetId: widget.contentId)),
          ),
      ]),
      body: _buildBody(),
      bottomNavigationBar:
          _content == null || _gone || _error != null || _loading
              ? null
              : ArticleCommentInput(
                  focusNode: _commentFocus,
                  onSend: (text, key) async {
                    await _api.commentHometown(widget.contentId, text,
                        requestKey: key);
                    if (mounted) await _loadComments();
                  }),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return ListView(
        padding: const EdgeInsets.all(12),
        children: const [
          DimiSkeleton(height: 220, radius: kDimiRadiusCard),
          SizedBox(height: 10),
          DimiSkeleton(height: 18, width: 200),
          SizedBox(height: 10),
          DimiSkeleton(height: 120, radius: kDimiRadiusCard),
        ],
      );
    }
    if (_error != null) {
      // 41001 内容不存在为终态（重试无意义），对齐 profile_card 锁定态：
      // 图标 + 提示文案，不给重试按钮
      if (_gone) {
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.landscape_outlined,
                  size: 48, color: kDimiGrayCC),
              const SizedBox(height: 12),
              Text(_error!, style: const TextStyle(color: kDimiGray99)),
            ],
          ),
        );
      }
      return DimiErrorView(message: _error!, onRetry: _load);
    }
    final c = _content!;
    final mine =
        c.author?.userId == context.read<Session>().currentUser?.userId;
    return ListView(
      key: const PageStorageKey('hometown-article'),
      padding: const EdgeInsets.only(bottom: 16),
      children: [
        ArticleContent(
            title: c.title,
            body: c.body,
            media: c.media,
            author: c.author,
            createdAt: c.createdAt,
            label: '家乡 · ${c.categoryLabel}',
            metadata: '阅读 ${c.viewCount}',
            onAuthorTap: c.author == null
                ? null
                : () => ProfileCardScreen.open(context, c.author!.userId)),
        ArticleActions(
            liked: c.liked,
            likeCount: c.likeCount,
            onLike: _likeBusy || _deleting ? null : _toggleLike,
            onComment: () => _commentFocus.requestFocus(),
            onGift: mine || _giftBusy || _deleting ? null : _gift),
        ArticleGiftSummary(
            gifts: _gifts, error: _giftsError, onRetry: _loadGifts),
        ArticleComments(
            comments: _comments,
            totalCount: _commentCount,
            loading: _commentsLoading,
            error: _commentsError,
            onRetry: _loadComments,
            onMore:
                _nextCursor == null ? null : () => _loadComments(reset: false),
            onDelete: _deleteComment,
            onReport: (comment) => showReportDialog(context,
                targetType: 'hometown_comment', targetId: comment.id!)),
      ],
    );
  }
}
