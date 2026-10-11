/// 好友申请（原型屏④）：验证语必填 ≤50 字 + 真名钥匙勾选。
/// 本地先行拦截手机号/微信号/QQ 等联系方式（正则），
/// 提示「成为好友后即可交换联系方式」；服务端 45001 同样拦截兜底。
library;

import 'package:flutter/material.dart';

import '../theme.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../widgets/intersection_banner.dart';

class FriendApplyScreen extends StatefulWidget {
  const FriendApplyScreen({super.key, required this.target, this.bannerText});

  final UserBrief target;

  /// 交集横幅文案（从资料卡带入；为空时退化为 match_tags 拼接）
  final String? bannerText;

  @override
  State<FriendApplyScreen> createState() => _FriendApplyScreenState();
}

class _FriendApplyScreenState extends State<FriendApplyScreen> {
  final _msgCtrl = TextEditingController();
  bool _attachRealName = true; // 真名钥匙：老同学需要通过真名认出你
  bool _attachEducation = false;
  bool _sending = false;
  bool _sent = false;

  /// 联系方式本地拦截：手机号 / 微信号 / QQ 号 / 明示交换关键词
  static final _contactPatterns = <RegExp>[
    RegExp(r'1[3-9]\d{9}'),
    RegExp(r'(微信|vx|wechat|wx)[:：\s]?[a-z0-9_-]{4,}', caseSensitive: false),
    RegExp(r'(qq)[:：\s]?\d{5,}', caseSensitive: false),
    RegExp(r'(加我|电话|手机)[:：\s]?\d{5,}'),
  ];

  bool get _containsContact {
    final text = _msgCtrl.text;
    return _contactPatterns.any((p) => p.hasMatch(text));
  }

  bool get _canSubmit {
    final text = _msgCtrl.text.trim();
    return text.isNotEmpty &&
        text.length <= 50 &&
        !_containsContact &&
        !_sending &&
        !_sent;
  }

  @override
  void initState() {
    super.initState();
    _msgCtrl.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _msgCtrl.dispose();
    super.dispose();
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  String get _banner {
    final t = widget.bannerText;
    if (t != null && t.isNotEmpty) return t;
    if (widget.target.matchTags.isNotEmpty) {
      return '共同点：${widget.target.matchTags.join(' · ')}';
    }
    return '';
  }

  Future<void> _send() async {
    final msg = _msgCtrl.text.trim();
    if (msg.isEmpty) {
      _toast('请填写验证语，告诉 TA 你是谁');
      return;
    }
    if (msg.length > 50) {
      _toast('验证语不能超过 50 字');
      return;
    }
    if (_containsContact) {
      _toast('请勿填写联系方式——成为好友后即可交换');
      return;
    }
    setState(() => _sending = true);
    try {
      await context.read<DimiApi>().sendFriendRequest(
            toUserId: widget.target.userId,
            verifyMsg: msg,
            attachRealName: _attachRealName,
            attachEducation: _attachEducation,
            source: 'classmate_search',
          );
      if (!mounted) return;
      setState(() => _sent = true);
      _toast('申请已发送 ✓ 对方将在「新的朋友」中看到你的真名与共同点');
      Navigator.of(context).pop();
    } on ApiException catch (e) {
      // 45001 内容安全拦截：服务端文案同样表达「成为好友后即可交换」
      _toast(e.message);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final target = widget.target;
    return Scaffold(
      backgroundColor: kDimiBg,
      appBar: AppBar(title: const Text('好友申请')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          if (_banner.isNotEmpty) ...[
            IntersectionBanner(_banner),
            const SizedBox(height: 10),
          ],
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '发给 ${target.nickname ?? 'TA'} 的验证语（必填，≤50字）',
                    style: const TextStyle(fontSize: 15, color: kDimiGray99),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _msgCtrl,
                    maxLines: 3,
                    maxLength: 50,
                    decoration: const InputDecoration(
                      hintText: '如：我是1996届六年2班的王丽',
                      border: OutlineInputBorder(),
                      counterStyle: TextStyle(fontSize: 14, color: kDimiGray99),
                    ),
                  ),
                  if (_containsContact)
                    const Padding(
                      padding: EdgeInsets.only(top: 4),
                      child: Text(
                        '⚠ 请勿填写手机号/微信号——成为好友后即可交换联系方式',
                        style: TextStyle(fontSize: 14, color: kDimiWarningDeep),
                      ),
                    ),
                ],
              ),
            ),
          ),
          Card(
            child: Column(
              children: [
                CheckboxListTile(
                  value: _attachRealName,
                  onChanged: (v) => setState(() => _attachRealName = v ?? true),
                  activeColor: kDimiPrimary,
                  title:
                      const Text('向对方公开我的真实姓名', style: TextStyle(fontSize: 16)),
                  subtitle: const Text('老同学需要通过真名认出你（真名钥匙）',
                      style: TextStyle(fontSize: 14)),
                ),
                const Divider(height: 1, indent: 16, endIndent: 16),
                CheckboxListTile(
                  value: _attachEducation,
                  onChanged: (v) =>
                      setState(() => _attachEducation = v ?? false),
                  activeColor: kDimiPrimary,
                  title: const Text('允许对方查看我的教育经历',
                      style: TextStyle(fontSize: 16)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          FilledButton(
            onPressed: _canSubmit ? _send : null,
            style: FilledButton.styleFrom(
              backgroundColor: kDimiPrimaryFill,
              foregroundColor: kDimiPrimary,
              padding: const EdgeInsets.symmetric(vertical: 13),
            ),
            child: Text(
              _sending ? '发送中…' : '发送申请',
              style: const TextStyle(fontSize: 17),
            ),
          ),
        ],
      ),
    );
  }
}
