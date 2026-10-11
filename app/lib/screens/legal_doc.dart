/// 法务文档查看页：拉取服务端托管的 markdown 原文（text/markdown），
/// 按行轻量渲染（# / ## 标题加粗放大，其余正文），不引入 markdown 渲染依赖。
/// 地址规则同 ApiConfig.resolveMediaUrl：/legal/xxx.md 拼 baseUrl 去 /v1 的 host。
library;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../api/config.dart';
import '../theme.dart';

class LegalDocScreen extends StatefulWidget {
  const LegalDocScreen({super.key, required this.title, required this.urlPath});

  final String title;

  /// 文档路径，如 /legal/user-agreement.md
  final String urlPath;

  @override
  State<LegalDocScreen> createState() => _LegalDocScreenState();
}

class _LegalDocScreenState extends State<LegalDocScreen> {
  String? _content;
  String? _error;

  /// markdown 源文件顶部的 HTML 注释（如待填清单）属内部备注，
  /// 不在 App 内展示；按块剔除，支持跨行注释
  static String _stripHtmlComments(String text) =>
      text.replaceAll(RegExp(r'<!--[\s\S]*?-->'), '');

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _content = null;
      _error = null;
    });
    try {
      final uri = Uri.parse(ApiConfig.resolveMediaUrl(widget.urlPath));
      final resp = await http.get(uri).timeout(const Duration(seconds: 15));
      if (!mounted) return;
      if (resp.statusCode == 200) {
        setState(() => _content = _stripHtmlComments(resp.body));
      } else {
        setState(() => _error = '加载失败（HTTP ${resp.statusCode}）');
      }
    } on Exception {
      if (!mounted) return;
      setState(() => _error = '网络异常，请稍后重试');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(title: Text(widget.title)),
      body: SafeArea(child: _buildBody()),
    );
  }

  Widget _buildBody() {
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
    final content = _content;
    if (content == null) {
      return const Center(
        child: CircularProgressIndicator(color: kDimiPrimary),
      );
    }
    final lines = content.split('\n');
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      itemCount: lines.length,
      itemBuilder: (_, i) => _MarkdownLine(lines[i]),
    );
  }
}

/// 单行轻量渲染：ATX 标题加粗放大，分隔线收敛为空行，其余按正文展示
class _MarkdownLine extends StatelessWidget {
  const _MarkdownLine(this.line);

  final String line;

  @override
  Widget build(BuildContext context) {
    final trimmed = line.trimRight();
    if (trimmed.startsWith('#')) {
      final level = trimmed.indexOf(' ');
      final text = level > 0 ? trimmed.substring(level + 1).trim() : trimmed;
      final size = switch (level) {
        1 => 20.0,
        2 => 17.0,
        _ => 15.0,
      };
      return Padding(
        padding: EdgeInsets.only(top: level <= 2 ? 18 : 12, bottom: 6),
        child: Text(
          text,
          style: TextStyle(
            fontSize: size,
            fontWeight: FontWeight.w700,
            color: kDimiText,
            height: 1.5,
          ),
        ),
      );
    }
    if (trimmed == '---' || trimmed == '***') {
      return const Divider(height: 24, color: kDimiHairline);
    }
    // 去掉行内加粗/斜体标记与列表符号的多余星号，保持纯文本可读
    final text = trimmed
        .replaceAll('**', '')
        .replaceAll('__', '')
        .replaceAllMapped(RegExp(r'^[-*]\s+'), (_) => '· ');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Text(
        text,
        style: const TextStyle(fontSize: 16, color: kDimiText, height: 1.7),
      ),
    );
  }
}
