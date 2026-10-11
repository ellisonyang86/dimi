/// 举报理由选择弹层（合规闭环）：骚扰/冒名/欺诈/违规内容/其他 + 可选说明，
/// 提交 POST /misc/report（人工复核 SLA 24h）。动态长按、资料卡 ⋯ 菜单共用。
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../theme.dart';

/// 可选举报理由（reason 与服务端枚举对齐；违规内容暂归 other）
const _reasons = <String, String>{
  'harassment': '骚扰',
  'impersonation': '冒名顶替',
  'fraud': '欺诈',
  'other': '违规内容',
  'other2': '其他',
};

/// 弹出举报流程。targetType：user / moment / message / group / article / hometown_content
Future<void> showReportDialog(
  BuildContext context, {
  required String targetType,
  required int targetId,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => _ReportSheet(targetType: targetType, targetId: targetId),
  );
}

class _ReportSheet extends StatefulWidget {
  const _ReportSheet({required this.targetType, required this.targetId});

  final String targetType;
  final int targetId;

  @override
  State<_ReportSheet> createState() => _ReportSheetState();
}

class _ReportSheetState extends State<_ReportSheet> {
  String _reason = 'harassment';
  final _detailCtrl = TextEditingController();
  bool _submitting = false;

  @override
  void dispose() {
    _detailCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting) return;
    setState(() => _submitting = true);
    try {
      // other2 为界面区分项，提交时归一到服务端枚举 other
      final reason = _reason == 'other2' ? 'other' : _reason;
      await context.read<DimiApi>().report(
            targetType: widget.targetType,
            targetId: widget.targetId,
            reason: reason,
            detail: _detailCtrl.text.trim(),
          );
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已收到举报，将在 24 小时内处理')));
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('举报',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          RadioGroup<String>(
            groupValue: _reason,
            onChanged: (v) => setState(() => _reason = v ?? _reason),
            child: Column(
              children: _reasons.entries
                  .map(
                    (e) => RadioListTile<String>(
                      value: e.key,
                      title:
                          Text(e.value, style: const TextStyle(fontSize: 16)),
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      activeColor: kDimiPrimary,
                    ),
                  )
                  .toList(),
            ),
          ),
          TextField(
            controller: _detailCtrl,
            maxLines: 3,
            maxLength: 500,
            decoration: const InputDecoration(
              hintText: '补充说明（选填，不超过 500 字）',
              hintStyle: TextStyle(fontSize: 15),
              isDense: true,
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _submitting ? null : _submit,
              style: FilledButton.styleFrom(backgroundColor: kDimiPrimaryFill),
              child: Text(_submitting ? '提交中…' : '提交举报'),
            ),
          ),
        ],
      ),
    );
  }
}
