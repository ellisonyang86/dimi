/// 帮助与反馈（合规闭环）：意见反馈（多行文字 + 可选联系方式 → POST /feedback），
/// 底部附「账号申诉」次级入口（冻结/内容误判/冒名 → POST /misc/appeal）。
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../theme.dart';
import '../widgets/common/dimi_dialog.dart';

class FeedbackScreen extends StatefulWidget {
  const FeedbackScreen({super.key});

  @override
  State<FeedbackScreen> createState() => _FeedbackScreenState();
}

class _FeedbackScreenState extends State<FeedbackScreen> {
  final _contentCtrl = TextEditingController();
  final _contactCtrl = TextEditingController();
  bool _submitting = false;

  @override
  void dispose() {
    _contentCtrl.dispose();
    _contactCtrl.dispose();
    super.dispose();
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _submit() async {
    final content = _contentCtrl.text.trim();
    if (content.isEmpty) {
      _toast('请填写反馈内容');
      return;
    }
    setState(() => _submitting = true);
    try {
      await context.read<DimiApi>().feedback(
            content: content,
            contact: _contactCtrl.text.trim(),
          );
      if (!mounted) return;
      _toast('感谢反馈，我们会尽快处理');
      Navigator.of(context).pop();
    } on ApiException catch (e) {
      _toast(e.message);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  /// 账号申诉：冻结 / 内容误判 / 冒名 + 说明（≤500 字）
  Future<void> _appeal() async {
    const types = {
      'freeze': '账号冻结申诉（SLA 24h）',
      'content': '内容误判申诉（SLA 72h）',
      'impersonation': '冒名申诉（SLA 3 个工作日）',
    };
    String type = 'freeze';
    final contentCtrl = TextEditingController();
    final ok = await showDimiDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          title: const Text('账号申诉', style: TextStyle(fontSize: 18)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              RadioGroup<String>(
                groupValue: type,
                onChanged: (v) => setDlg(() => type = v ?? type),
                child: Column(
                  children: types.entries
                      .map(
                        (e) => RadioListTile<String>(
                          value: e.key,
                          title: Text(e.value,
                              style: const TextStyle(fontSize: 15)),
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          activeColor: kDimiPrimary,
                        ),
                      )
                      .toList(),
                ),
              ),
              TextField(
                controller: contentCtrl,
                maxLines: 3,
                maxLength: 500,
                decoration: const InputDecoration(
                  hintText: '申诉说明（必填，不超过 500 字）',
                  hintStyle: TextStyle(fontSize: 15),
                  isDense: true,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: kDimiPrimaryFill),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('提交申诉'),
            ),
          ],
        ),
      ),
    );
    final content = contentCtrl.text.trim();
    contentCtrl.dispose();
    if (ok != true || !mounted) return;
    if (content.isEmpty) {
      _toast('请填写申诉说明');
      return;
    }
    try {
      await context.read<DimiApi>().appeal(type: type, content: content);
      _toast('申诉已提交，我们将在承诺时限内处理');
    } on ApiException catch (e) {
      _toast(e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kDimiBg,
      appBar: AppBar(title: const Text('帮助与反馈')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('意见反馈',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _contentCtrl,
                    maxLines: 6,
                    decoration: const InputDecoration(
                      hintText: '说说你遇到的问题或建议…',
                      hintStyle: TextStyle(fontSize: 15),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _contactCtrl,
                    decoration: const InputDecoration(
                      hintText: '联系方式（选填，便于我们回访）',
                      hintStyle: TextStyle(fontSize: 15),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: _submitting ? null : _submit,
                      style: FilledButton.styleFrom(
                          backgroundColor: kDimiPrimaryFill),
                      child: Text(_submitting ? '提交中…' : '提交反馈'),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Center(
            child: TextButton(
              onPressed: _appeal,
              child: const Text('账号被封或内容被误判？点此申诉',
                  style: TextStyle(fontSize: 15, color: kDimiPrimary)),
            ),
          ),
        ],
      ),
    );
  }
}
