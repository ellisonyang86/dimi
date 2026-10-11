String articleTitle(String text) {
  final line = text.trimLeft().split('\n').first;
  return line.startsWith('# ') ? line.substring(2).trim() : '';
}

String articleText(String text) => articleTitle(text).isEmpty
    ? text
    : text.trimLeft().split('\n').skip(1).join('\n').trimLeft();

String articleExcerpt(String text) => text
    .replaceAll(RegExp(r'^#{1,3}\s+|^>\s*|^[-*]\s+', multiLine: true), '')
    .replaceAll('**', '')
    .replaceAll(RegExp(r'\[图片\d+\]'), '')
    .trim();

/// Keep inline references aligned when an attachment is removed in the editor.
String removeArticleImage(String body, int removedIndex) =>
    body.replaceAllMapped(RegExp(r'\[图片(\d+)\]'), (m) {
      final n = int.tryParse(m[1]!);
      if (n == null) return m[0]!;
      if (n == removedIndex + 1) return '';
      return '[图片${n > removedIndex + 1 ? n - 1 : n}]';
    });
