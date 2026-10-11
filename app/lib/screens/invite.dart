/// 召集令分享页（V0.9 主链路最后一环）：
/// 展示班级名册（已注册 + 点亮占位，/discover/placeholders）与召集进度（≥3 人），
/// 生成分享文案（复制到剪贴板，链接来自 rally_card_url 解析的召集令码）。
/// 正式版接入系统分享 / 微信 SDK 与渠道码归因（见 V0.9 计划书 §7 种子班级计划）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../api/config.dart';
import '../theme.dart';

class InviteScreen extends StatefulWidget {
  const InviteScreen({super.key, this.education});

  static const routeName = '/invite';

  /// 关联的班级经历；为空时拉取第一段经历
  final Education? education;

  @override
  State<InviteScreen> createState() => _InviteScreenState();
}

class _InviteScreenState extends State<InviteScreen> {
  Education? _education;
  int _registeredCount = 0;
  int _placeholderCount = 0;
  String? _rallyCode;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _load() async {
    final api = context.read<DimiApi>();
    var edu = widget.education;
    try {
      if (edu == null) {
        final list = await api.myEducations();
        edu = list.isEmpty ? null : list.first;
      }
      var registered = 0;
      var placeholder = 0;
      String? code;
      if (edu?.id != null) {
        final roster = await api.classRoster(edu!.id!);
        registered = asInt(roster['registered_count']) ?? 0;
        placeholder = asInt(roster['placeholder_count']) ?? 0;
        code = _parseRallyCode(asStr(roster['rally_card_url']));
      }
      if (!mounted) return;
      setState(() {
        _education = edu;
        _registeredCount = registered;
        _placeholderCount = placeholder;
        _rallyCode = code;
        _loading = false;
      });
    } on ApiException {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  /// 从 rally_card_url（形如 /h5/invite.html?code=xxx）解析召集令码
  static String? _parseRallyCode(String? url) {
    if (url == null || url.isEmpty) return null;
    return Uri.tryParse(url)?.queryParameters['code'];
  }

  /// 名册总人数 = 已注册 + 占位名字
  int get _totalCount => _registeredCount + _placeholderCount;

  /// 召集进度：已归队 ≥3 人即可发起召集令
  bool get _rallyReady => _registeredCount >= 3;

  String get _shareText {
    final edu = _education;
    final unit = edu == null ? '我们的班级' : edu.displayLine;
    final code = _rallyCode;
    if (code == null) {
      return '【DIMI·围城】$unit 召集令：已归队 $_registeredCount 人。'
          '先到「找同学」点亮老同学的名字，生成专属召集链接后再分享！';
    }
    return '【DIMI·围城】$unit 召集令：'
        '已归队 $_registeredCount 人，还有 $_placeholderCount 个名字等你唤醒！'
        '老同学，回来报个到 → ${ApiConfig.h5BaseUrl}invite.html?code=$code';
  }

  Future<void> _copy() async {
    try {
      await Clipboard.setData(ClipboardData(text: _shareText));
    } on Exception {
      if (mounted) _toast('复制失败，请长按文案手动复制');
      return;
    }
    if (!mounted) return;
    _toast('分享文案已复制，去微信/QQ 粘贴给老同学吧');
  }

  @override
  Widget build(BuildContext context) {
    final edu = _education;
    return Scaffold(
      backgroundColor: kDimiBg,
      appBar: AppBar(title: const Text('召集令')),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: kDimiPrimary))
          : ListView(
              padding: const EdgeInsets.all(12),
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Column(
                      children: [
                        const Icon(Icons.campaign,
                            size: 40, color: kDimiPrimary),
                        const SizedBox(height: 10),
                        Text(
                          edu == null ? '班级召集令' : '${edu.displayLine} 召集令',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              fontSize: 19, fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 14),
                        Text(
                          '已归队 $_registeredCount 人',
                          style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                            color: kDimiPrimary,
                          ),
                        ),
                        const SizedBox(height: 10),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: (_registeredCount / 3).clamp(0.0, 1.0),
                            minHeight: 8,
                            backgroundColor: kDimiPrimarySoft,
                            valueColor:
                                const AlwaysStoppedAnimation(kDimiPrimary),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _rallyReady
                              ? '已达 3 人，可发起召集令'
                              : '还差 ${3 - _registeredCount} 人即可发起召集令',
                          style:
                              const TextStyle(fontSize: 14, color: kDimiGray99),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '名册共 $_totalCount 人 · $_placeholderCount 个名字待唤醒',
                          style:
                              const TextStyle(fontSize: 14, color: kDimiGray99),
                        ),
                      ],
                    ),
                  ),
                ),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('分享文案',
                            style: TextStyle(fontWeight: FontWeight.w600)),
                        const SizedBox(height: 8),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: kDimiBg,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: SelectableText(
                            _shareText,
                            style: const TextStyle(fontSize: 16, height: 1.7),
                          ),
                        ),
                        const SizedBox(height: 12),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            onPressed: _copy,
                            icon: const Icon(Icons.copy, size: 18),
                            label: const Text('复制分享文案'),
                            style: FilledButton.styleFrom(
                              backgroundColor: kDimiPrimaryFill,
                              foregroundColor: kDimiPrimary,
                              padding: const EdgeInsets.symmetric(vertical: 12),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.all(10),
                  child: Text(
                    '将召集令发给老同学，对方可先预览班级信息。注册后填写对应的学校、入学年份和班级，即可找到本班同学。',
                    style: TextStyle(
                        fontSize: 14, color: kDimiGray99, height: 1.6),
                  ),
                ),
              ],
            ),
    );
  }
}
