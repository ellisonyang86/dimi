/// 首次启动隐私同意页（工信部合规）：同意前不初始化任何业务模块。
/// 非消弹窗说明数据收集用途，《用户服务协议》《隐私政策》可点击阅读
/// （复用 legal_doc.dart 服务端托管 markdown 渲染，版本见 kAgreementVersion）。
/// 同意 → 持久化 privacy_consent_v1 并进入主程序；
/// 不同意 → 再说明，可退出应用或返回重看。
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/client.dart';
import '../theme.dart';
import '../widgets/common/dimi_brand_logo.dart';
import 'legal_doc.dart';

/// 同意状态持久化键：协议版本升级需重新征得同意时，递增后缀（v2、v3…）
const String kPrivacyConsentKey = 'privacy_consent_v1';

/// 是否已完成首启隐私同意
Future<bool> isPrivacyConsented() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getBool(kPrivacyConsentKey) ?? false;
}

/// 同意前置壳：仅承载同意弹窗与协议查看页，同意后回调进入主程序
class PrivacyConsentApp extends StatelessWidget {
  const PrivacyConsentApp({super.key, required this.onAgreed});

  /// 用户同意后调用（持久化已完成，负责启动主程序）
  final Future<void> Function() onAgreed;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DIMI · 围城',
      debugShowCheckedModeBanner: false,
      theme: buildDimiTheme(),
      home: _ConsentGate(onAgreed: onAgreed),
    );
  }
}

class _ConsentGate extends StatefulWidget {
  const _ConsentGate({required this.onAgreed});

  final Future<void> Function() onAgreed;

  @override
  State<_ConsentGate> createState() => _ConsentGateState();
}

class _ConsentGateState extends State<_ConsentGate> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _showConsent());
  }

  Future<void> _showConsent() async {
    final agreed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: const Text('隐私政策与用户协议'),
          content: const _ConsentContent(),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('不同意'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: FilledButton.styleFrom(backgroundColor: kDimiPrimaryFill),
              child: const Text('同意'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (agreed == true) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(kPrivacyConsentKey, true);
      if (!mounted) return;
      await widget.onAgreed();
      return;
    }
    // 不同意：再说明并提供退出入口，返回则重新弹同意框
    await _showDeclined();
    if (mounted) _showConsent();
  }

  Future<void> _showDeclined() {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('需要同意后才能使用'),
        content: const Text('DIMI·围城需依据《隐私政策》收集必要信息才能为您提供服务。'
            '若不同意，将无法继续使用本应用。'),
        actions: [
          TextButton(
            onPressed: () => SystemNavigator.pop(),
            child: const Text('退出应用'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            style: FilledButton.styleFrom(backgroundColor: kDimiPrimaryFill),
            child: const Text('再看看'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 同意前的占位启动页：品牌色底 + 图标，不加载任何业务内容
    return const Scaffold(
      body: Center(
        child: DimiBrandLogo(size: 72),
      ),
    );
  }
}

/// 弹窗正文：数据收集说明 + 可点击的协议链接
class _ConsentContent extends StatefulWidget {
  const _ConsentContent();

  @override
  State<_ConsentContent> createState() => _ConsentContentState();
}

class _ConsentContentState extends State<_ConsentContent> {
  late final TapGestureRecognizer _agreementTap;
  late final TapGestureRecognizer _privacyTap;

  @override
  void initState() {
    super.initState();
    _agreementTap = TapGestureRecognizer()
      ..onTap = () => _openLegal('用户服务协议', kUserAgreementPath);
    _privacyTap = TapGestureRecognizer()
      ..onTap = () => _openLegal('隐私政策', kPrivacyPolicyPath);
  }

  @override
  void dispose() {
    _agreementTap.dispose();
    _privacyTap.dispose();
    super.dispose();
  }

  void _openLegal(String title, String urlPath) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => LegalDocScreen(title: title, urlPath: urlPath),
    ));
  }

  @override
  Widget build(BuildContext context) {
    const base = TextStyle(fontSize: 15, color: kDimiText, height: 1.6);
    const link = TextStyle(fontSize: 15, color: kDimiPrimary, height: 1.6);
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '感谢您使用 DIMI·围城！我们非常重视您的个人信息和隐私保护。'
            '为向您提供校友匹配、好友重逢等核心服务，我们会按照以下协议收集、'
            '使用您的手机号、昵称、出生年份与求学经历等必要信息。',
            style: base,
          ),
          const SizedBox(height: 10),
          Text.rich(
            TextSpan(
              style: base,
              children: [
                const TextSpan(text: '请您在使用前仔细阅读并充分理解'),
                TextSpan(
                    text: '《用户服务协议》', style: link, recognizer: _agreementTap),
                const TextSpan(text: '和'),
                TextSpan(text: '《隐私政策》', style: link, recognizer: _privacyTap),
                const TextSpan(
                    text: '（当前版本 $kAgreementVersion）。点击「同意」即表示您已阅读'
                        '并同意上述协议的全部内容。'),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
