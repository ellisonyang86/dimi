/// 登录设备管理（契约 /auth/devices）：
/// 列出当前账号的活跃会话；本机标注绿色标签，其余设备可确认后下线。
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../theme.dart';
import '../widgets/common/dimi_section.dart';

class DevicesScreen extends StatefulWidget {
  const DevicesScreen({super.key});

  static const routeName = '/devices';

  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen> {
  List<DeviceSession> _items = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await context.read<DimiApi>().devices();
      if (!mounted) return;
      setState(() => _items = list);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _revoke(DeviceSession d) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('下线设备'),
        content: Text('确定下线「${d.deviceInfo}」吗？该设备需重新登录。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(backgroundColor: kDimiPrimaryFill),
            child: const Text('下线'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await context.read<DimiApi>().revokeDevice(d.deviceId);
      if (!mounted) return;
      _toast('已下线「${d.deviceInfo}」');
      _load();
    } on ApiException catch (e) {
      _toast(e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kDimiBg,
      appBar: AppBar(title: const Text('登录设备管理')),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: kDimiPrimary),
      );
    }
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
    if (_items.isEmpty) {
      return const Center(
        child: Text('暂无活跃设备', style: TextStyle(color: kDimiGray99)),
      );
    }
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 7),
      children: [
        // 微信式分组排版：整块白底 + 组内发丝分隔线
        DimiSection(
          dividerIndent: kDimiSectionDividerIndentTile,
          children: [for (final d in _items) _deviceTile(d)],
        ),
        const Padding(
          padding: EdgeInsets.all(10),
          child: Text(
            '下线后该设备的登录态立即失效。本机设备请使用「退出登录」。',
            style: TextStyle(fontSize: 14, color: kDimiGray99, height: 1.6),
          ),
        ),
      ],
    );
  }

  Widget _deviceTile(DeviceSession d) {
    return ListTile(
      leading: const Icon(Icons.phone_android_outlined, color: kDimiPrimary),
      title: Row(
        children: [
          Flexible(
            child: Text(d.deviceInfo,
                style: const TextStyle(fontSize: 17, color: kDimiText),
                overflow: TextOverflow.ellipsis),
          ),
          if (d.current) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: kDimiPrimarySoft,
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Text('本机',
                  style: TextStyle(fontSize: 14, color: kDimiPrimary)),
            ),
          ],
        ],
      ),
      subtitle: d.loginAt == null
          ? null
          : Text('登录时间：${d.loginAt}', style: const TextStyle(fontSize: 14)),
      trailing: d.current
          ? null
          : TextButton(
              onPressed: () => _revoke(d),
              child: const Text('下线', style: TextStyle(color: kDimiDanger)),
            ),
    );
  }
}
