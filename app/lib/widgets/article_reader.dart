import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../api/models.dart';
import '../theme.dart';
import 'article_format.dart';
export 'article_format.dart';
import 'dimi_avatar.dart';
import 'moment_card.dart' show formatMomentTime;

class ArticleContent extends StatelessWidget {
  const ArticleContent(
      {super.key,
      required this.body,
      this.title = '',
      this.media = const [],
      this.author,
      this.createdAt,
      this.label,
      this.metadata,
      this.onAuthorTap,
      this.imageBuilder,
      this.imageCount});
  final String title, body;
  final List<String> media;
  final UserBrief? author;
  final String? createdAt, label, metadata;
  final VoidCallback? onAuthorTap;
  final Widget Function(int)? imageBuilder;
  final int? imageCount;

  @override
  Widget build(BuildContext context) {
    final name = author?.realName ?? author?.nickname ?? '未命名';
    final minutes =
        (articleExcerpt(body).runes.length / 400).ceil().clamp(1, 999);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 8),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (label != null) ...[
              Text(label!,
                  style: const TextStyle(fontSize: 14, color: kDimiPrimary)),
              const SizedBox(height: 12),
            ],
            if (title.isNotEmpty) ...[
              SelectableText(title,
                  style: const TextStyle(
                      fontSize: 26,
                      height: 1.45,
                      fontWeight: FontWeight.w600,
                      color: kDimiText)),
              const SizedBox(height: 16),
            ],
            if (author != null) ...[
              InkWell(
                  onTap: onAuthorTap,
                  borderRadius: BorderRadius.circular(8),
                  child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 48),
                      child: Row(children: [
                        DimiAvatar(
                            name: name,
                            avatarUrl: author?.avatarUrl,
                            seed: author?.userId,
                            size: 36),
                        const SizedBox(width: 10),
                        Expanded(
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                              Text(name,
                                  style: const TextStyle(
                                      fontSize: 15, color: kDimiPrimary)),
                              Text(
                                  [
                                    formatMomentTime(createdAt),
                                    if (metadata != null) metadata!
                                  ].where((s) => s.isNotEmpty).join(' · '),
                                  style: const TextStyle(
                                      fontSize: 14, color: kDimiGray99)),
                            ])),
                      ]))),
              const SizedBox(height: 12),
            ],
            if (body.runes.length > 400) ...[
              Text('约 $minutes 分钟读完',
                  style: const TextStyle(fontSize: 14, color: kDimiGray99)),
              const SizedBox(height: 16),
            ],
            ArticleBody(
                body: body,
                media: media,
                imageBuilder: imageBuilder,
                imageCount: imageCount),
          ]),
        ),
      ),
    );
  }
}

/// Native paragraphs, headings, emphasis, quotes, lists and uploaded images.
/// HTML and URLs remain literal text; no WebView or arbitrary remote embeds.
class ArticleBody extends StatelessWidget {
  const ArticleBody(
      {super.key,
      required this.body,
      this.media = const [],
      this.imageBuilder,
      this.imageCount});
  final String body;
  final List<String> media;
  final Widget Function(int)? imageBuilder;
  final int? imageCount;

  List<InlineSpan> _spans(String text) {
    final spans = <InlineSpan>[];
    var offset = 0;
    for (final m in RegExp(r'\*\*([^*\n]+)\*\*').allMatches(text)) {
      spans.add(TextSpan(text: text.substring(offset, m.start)));
      spans.add(TextSpan(
          text: m[1], style: const TextStyle(fontWeight: FontWeight.w600)));
      offset = m.end;
    }
    spans.add(TextSpan(text: text.substring(offset)));
    return spans;
  }

  Widget _image(BuildContext context, int index) {
    if (imageBuilder != null) return imageBuilder!(index);
    return Semantics(
        label: '文章配图 ${index + 1}，点击放大',
        button: true,
        child: InkWell(
          onTap: () => showDialog<void>(
              context: context,
              builder: (ctx) => Dialog.fullscreen(
                  backgroundColor: Colors.black,
                  child: Stack(children: [
                    Positioned.fill(
                        child: InteractiveViewer(
                            minScale: 0.8,
                            maxScale: 4,
                            child: CachedNetworkImage(
                                imageUrl: media[index],
                                fit: BoxFit.contain,
                                errorWidget: (_, __, ___) => const Center(
                                    child: Text('图片加载失败',
                                        style:
                                            TextStyle(color: Colors.white)))))),
                    SafeArea(
                        child: IconButton(
                            tooltip: '关闭图片',
                            onPressed: () => Navigator.pop(ctx),
                            icon:
                                const Icon(Icons.close, color: Colors.white))),
                  ]))),
          child: CachedNetworkImage(
              imageUrl: media[index],
              width: double.infinity,
              fit: BoxFit.contain,
              memCacheWidth: 1440,
              placeholder: (_, __) => const AspectRatio(
                  aspectRatio: 4 / 3,
                  child: ColoredBox(color: kDimiNeutralSoft)),
              errorWidget: (_, __, ___) => const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('图片暂时无法加载',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: kDimiGray99)))),
        ));
  }

  @override
  Widget build(BuildContext context) {
    final blocks = <Widget>[];
    final usedImages = <int>{};
    final count = imageCount ?? media.length;
    for (final raw in body.replaceAll('\r\n', '\n').split('\n')) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      final image = RegExp(r'^\[图片(\d+)\]$').firstMatch(line);
      if (image != null) {
        final index = (int.tryParse(image[1]!) ?? 0) - 1;
        if (index >= 0 && index < count) {
          blocks.add(Padding(
              padding: const EdgeInsets.only(bottom: 20),
              child: _image(context, index)));
          usedImages.add(index);
          continue;
        }
      }
      if (line == '---') {
        blocks.add(const Divider(height: 32));
        continue;
      }
      final heading = RegExp(r'^(#{1,3})\s+(.+)$').firstMatch(line);
      final quote = line.startsWith('> ');
      final bullet = line.startsWith('- ') || line.startsWith('* ');
      final text = heading?[2] ?? (quote || bullet ? line.substring(2) : line);
      Widget paragraph = Text.rich(
          TextSpan(children: _spans(bullet ? '•  $text' : text)),
          style: TextStyle(
              fontSize:
                  heading != null ? (heading[1]!.length == 1 ? 24 : 21) : 18,
              height: heading != null ? 1.5 : 1.85,
              letterSpacing: 0.3,
              color: kDimiText,
              fontWeight: heading != null ? FontWeight.w600 : FontWeight.w400));
      if (quote) {
        paragraph = Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: const BoxDecoration(
                color: kDimiPrimarySoft,
                border:
                    Border(left: BorderSide(color: kDimiPrimary, width: 3))),
            child: paragraph);
      }
      blocks.add(Padding(
          padding: EdgeInsets.only(top: heading != null ? 12 : 0, bottom: 18),
          child: paragraph));
    }
    for (var i = 0; i < count; i++) {
      if (!usedImages.contains(i)) {
        blocks.add(Padding(
            padding: const EdgeInsets.only(bottom: 20),
            child: _image(context, i)));
      }
    }
    return SelectionArea(
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch, children: blocks));
  }
}

class ArticleToolbar extends StatelessWidget {
  const ArticleToolbar(
      {super.key,
      required this.controller,
      required this.onPreview,
      this.imageCount = 0,
      this.enabled = true});
  final TextEditingController controller;
  final VoidCallback onPreview;
  final int imageCount;
  final bool enabled;

  void _insert(String before, String placeholder, [String after = '']) {
    final value = controller.value;
    final selection = value.selection;
    final start = selection.isValid ? selection.start : value.text.length;
    final end = selection.isValid ? selection.end : value.text.length;
    final selected = value.text.substring(start, end);
    final content = selected.isEmpty ? placeholder : selected;
    final replacement = '$before$content$after';
    controller.value = TextEditingValue(
        text: value.text.replaceRange(start, end, replacement),
        selection: TextSelection(
            baseOffset: start + before.length,
            extentOffset: start + before.length + content.length));
  }

  @override
  Widget build(BuildContext context) => Wrap(spacing: 4, children: [
        TextButton(
            onPressed: enabled ? () => _insert('\n\n## ', '小标题', '\n\n') : null,
            child: const Text('小标题')),
        TextButton(
            onPressed: enabled ? () => _insert('**', '重点文字', '**') : null,
            child: const Text('加粗')),
        TextButton(
            onPressed: enabled ? () => _insert('\n\n> ', '引用文字', '\n\n') : null,
            child: const Text('引用')),
        if (imageCount > 0)
          TextButton(
              onPressed: !enabled
                  ? null
                  : () async {
                      final index = await showModalBottomSheet<int>(
                          context: context,
                          isScrollControlled: true,
                          builder: (ctx) => SafeArea(
                                  child: SingleChildScrollView(
                                      child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                    const Padding(
                                        padding: EdgeInsets.all(16),
                                        child: Text('选择插入的配图')),
                                    for (var i = 0; i < imageCount; i++)
                                      ListTile(
                                          leading:
                                              const Icon(Icons.image_outlined),
                                          title: Text('图片 ${i + 1}'),
                                          onTap: () => Navigator.pop(ctx, i)),
                                  ]))));
                      if (index != null && context.mounted) {
                        _insert('\n\n', '[图片${index + 1}]', '\n\n');
                      }
                    },
              child: const Text('插图')),
        TextButton.icon(
            onPressed: enabled ? onPreview : null,
            icon: const Icon(Icons.visibility_outlined, size: 18),
            label: const Text('预览')),
      ]);
}

void showArticlePreview(BuildContext context,
    {required String title,
    required String body,
    List<Uint8List> images = const []}) {
  final snapshots = List<Uint8List>.of(images);
  Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => Scaffold(
            backgroundColor: Colors.white,
            appBar: AppBar(title: const Text('阅读预览')),
            body: ListView(children: [
              ArticleContent(
                  title: title,
                  body: body,
                  label: '预览 · 尚未发布',
                  imageCount: snapshots.length,
                  imageBuilder: (i) =>
                      Image.memory(snapshots[i], fit: BoxFit.contain))
            ]),
          )));
}
