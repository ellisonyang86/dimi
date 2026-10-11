import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../theme.dart';
import '../widgets/common/dimi_button.dart';

/// 隐私设置中的低频操作；仅主动生成，完整数据可复制备份。
class DataExportScreen extends StatefulWidget {
  const DataExportScreen({super.key});
  @override
  State<DataExportScreen> createState() => _DataExportScreenState();
}

class _DataExportScreenState extends State<DataExportScreen> {
  bool _loading = false;
  Map<String, dynamic>? _data;
  String? _error;
  Future<void> _generate() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await context.read<DimiApi>().exportData();
      if (mounted) setState(() => _data = data);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('个人信息导出')),
        body: ListView(padding: const EdgeInsets.all(24), children: [
          const Text('查看和备份你的资料',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
          const SizedBox(height: 12),
          const Text('包含个人资料、教育经历、家乡、好友列表和隐私设置。每小时可生成一次。',
              style: TextStyle(fontSize: 17, height: 1.7, color: kDimiGray66)),
          const SizedBox(height: 24),
          if (_error != null)
            Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child:
                    Text(_error!, style: const TextStyle(color: kDimiDanger))),
          if (_data == null)
            DimiButton(label: '生成我的数据', loading: _loading, onPressed: _generate)
          else ...[
            Card(
                margin: EdgeInsets.zero,
                child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                        '数据已就绪\n教育经历：${(_data!['educations'] as List?)?.length ?? 0} 条\n好友：${(_data!['friends'] as List?)?.length ?? 0} 人',
                        style: const TextStyle(fontSize: 17, height: 1.8)))),
            const SizedBox(height: 16),
            DimiButton(
                label: '复制完整数据',
                icon: Icons.copy_outlined,
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(
                      text: const JsonEncoder.withIndent('  ').convert(_data)));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('完整数据已复制，可粘贴保存为文件')));
                  }
                }),
          ],
        ]),
      );
}
