/// 登录页：验证码登录（手机号 + 短信验证码）/ 密码登录（grant_type=password）
/// 两种方式切换；登录成功后未 onboarded 的账号先落经历引导页。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../theme.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../state/session.dart';
import '../state/preview_login.dart';
import '../widgets/common/agreement_row.dart';
import '../widgets/common/dimi_brand_logo.dart';
import '../widgets/common/dimi_button.dart';
import '../widgets/slider_captcha.dart';
import 'home.dart';
import 'onboarding_education.dart';
import 'privacy_consent.dart';
import 'register.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, this.previewLoginError});

  final String? previewLoginError;

  static const routeName = '/login';

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _phoneCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _phoneFocus = FocusNode();
  final _codeFocus = FocusNode();
  final _passwordFocus = FocusNode();
  bool _sending = false;
  bool _submitting = false;
  int _countdown = 0;
  Timer? _timer;
  bool _agreed = false;
  bool _enteringPreview = false;
  String? _previewError;

  /// 失焦标记：字段失焦后才展示内联报错，避免边输入边报错打扰
  bool _phoneTouched = false;
  bool _codeTouched = false;
  bool _passwordTouched = false;

  /// 0 验证码登录 / 1 密码登录
  int _mode = 0;

  static final _phoneReg = RegExp(r'^1[3-9]\d{9}$');
  static final _codeReg = RegExp(r'^\d{6}$');

  bool get _phoneValid => _phoneReg.hasMatch(_phoneCtrl.text.trim());
  bool get _codeValid => _codeReg.hasMatch(_codeCtrl.text.trim());

  bool get _passwordValid {
    final len = _passwordCtrl.text.length;
    return len >= 8 && len <= 64;
  }

  /// 当前登录方式下表单是否全部合法（决定提交按钮是否可用）
  bool get _formValid =>
      _phoneValid && (_mode == 0 ? _codeValid : _passwordValid);

  String? get _phoneError => _phoneValid ? null : '请输入正确的 11 位手机号';
  String? get _codeError => _codeValid ? null : '请输入 6 位短信验证码';
  String? get _passwordError => _passwordValid ? null : '密码为 8–64 位';

  @override
  void initState() {
    super.initState();
    _previewError = widget.previewLoginError;
    // 失焦时标记 touched，触发对应字段的内联校验展示
    _phoneFocus.addListener(() {
      if (!_phoneFocus.hasFocus && !_phoneTouched) {
        setState(() => _phoneTouched = true);
      }
    });
    _codeFocus.addListener(() {
      if (!_codeFocus.hasFocus && !_codeTouched) {
        setState(() => _codeTouched = true);
      }
    });
    _passwordFocus.addListener(() {
      if (!_passwordFocus.hasFocus && !_passwordTouched) {
        setState(() => _passwordTouched = true);
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _phoneCtrl.dispose();
    _codeCtrl.dispose();
    _passwordCtrl.dispose();
    _phoneFocus.dispose();
    _codeFocus.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _enterPreview() async {
    if (_enteringPreview || _submitting || _sending) return;
    setState(() {
      _enteringPreview = true;
      _previewError = null;
    });
    try {
      // 体验入口也遵循首启同意流程，不在同意前发送请求。
      final consented = await isPrivacyConsented();
      if (!mounted) return;
      if (!consented) {
        setState(() => _previewError = '请先在首次启动页面阅读并同意隐私政策与用户协议。');
        return;
      }
      final session = context.read<Session>();
      final token = await authenticatePreview(context.read<DimiApi>());
      if (!mounted) return;
      await session.login(token);
      await session.markOnboarded();
      if (!mounted) return;
      Navigator.of(context)
          .pushNamedAndRemoveUntil(MainShell.routeName, (route) => false);
    } on Exception catch (error) {
      if (mounted) setState(() => _previewError = previewLoginMessage(error));
    } finally {
      if (mounted) setState(() => _enteringPreview = false);
    }
  }

  Future<void> _sendCode() async {
    if (_enteringPreview) return;
    final phone = _phoneCtrl.text.trim();
    if (!_phoneReg.hasMatch(phone)) {
      _toast('请输入正确的手机号');
      return;
    }
    if (!_agreed) {
      _toast('请先阅读并勾选同意《用户服务协议》和《隐私政策》');
      return;
    }
    setState(() => _sending = true);
    try {
      final sent = await sendSmsWithCaptcha(context, phone, scene: 'login');
      if (!sent || !mounted) return;
      _toast('验证码已发送');
      setState(() => _countdown = 60);
      _timer?.cancel();
      _timer = Timer.periodic(const Duration(seconds: 1), (t) {
        if (!mounted) {
          t.cancel();
          return;
        }
        setState(() {
          _countdown--;
          if (_countdown <= 0) t.cancel();
        });
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      _toast(e.message);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _login() async {
    if (_enteringPreview || _submitting) return;
    final phone = _phoneCtrl.text.trim();
    if (!_phoneReg.hasMatch(phone)) {
      _toast('请输入正确的手机号');
      return;
    }
    if (_mode == 0 && !_codeReg.hasMatch(_codeCtrl.text.trim())) {
      _toast('请输入 6 位短信验证码');
      return;
    }
    if (_mode == 1 && !_passwordValid) {
      _toast('密码为 8–64 位');
      return;
    }
    if (!_agreed) {
      _toast('请先阅读并勾选同意《用户服务协议》和《隐私政策》');
      return;
    }
    setState(() => _submitting = true);
    try {
      final api = context.read<DimiApi>();
      Future<AuthToken> authenticate([String? captchaToken]) => _mode == 0
          ? api.loginBySms(
              phone: phone,
              smsCode: _codeCtrl.text.trim(),
              captchaToken: captchaToken)
          : api.loginByPassword(
              phone: phone,
              password: _passwordCtrl.text,
              captchaToken: captchaToken);
      AuthToken token;
      try {
        token = await authenticate();
      } on ApiException catch (e) {
        if (!e.isNeedCaptcha || !mounted) rethrow;
        final captcha = await showSliderCaptcha(context);
        if (captcha == null || !mounted) return;
        token = await authenticate(captcha);
      }
      if (!mounted) return;
      final session = context.read<Session>();
      await session.login(token);
      if (!session.onboarded) {
        try {
          if ((await api.myEducations()).isNotEmpty) {
            await session.markOnboarded();
          }
        } on ApiException {/* 经历加载失败时保留引导入口 */}
      }
      if (!mounted) return;
      // 未 onboarded 的账号先补经历引导，消除死状态
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute<void>(
          builder: (_) => session.onboarded
              ? const MainShell()
              : const OnboardingEducationScreen(),
        ),
        (route) => false,
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      _toast(e.message);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          children: [
            const SizedBox(height: 48),
            // 品牌区：城门图形标识 + 标题 / slogan 分级排版
            const Center(child: DimiBrandLogo(size: 76)),
            const SizedBox(height: 16),
            Text(
              'DIMI · 围城',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 4),
            const Text(
              '走出通讯录的围城，找回走散的人',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 15, color: kDimiGray99),
            ),
            const SizedBox(height: 32),
            if (kDevAutoLogin) ...[
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('调试版直接体验',
                          style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 8),
                      const Text('已准备好体验账号，无需注册、填写手机号或接收验证码。'),
                      if (_previewError != null) ...[
                        const SizedBox(height: 12),
                        Text(_previewError!,
                            key: const Key('preview-login-error'),
                            style: const TextStyle(color: kDimiDanger)),
                      ],
                      const SizedBox(height: 16),
                      DimiButton(
                        label: '直接体验（免注册）',
                        onPressed:
                            _submitting || _sending ? null : _enterPreview,
                        loading: _enteringPreview,
                        expanded: true,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],
            // 表单卡片化
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    SegmentedButton<int>(
                      segments: const [
                        ButtonSegment(value: 0, label: Text('验证码登录')),
                        ButtonSegment(value: 1, label: Text('密码登录')),
                      ],
                      selected: {_mode},
                      onSelectionChanged: (sel) =>
                          setState(() => _mode = sel.first),
                    ),
                    const SizedBox(height: 20),
                    TextField(
                      controller: _phoneCtrl,
                      focusNode: _phoneFocus,
                      keyboardType: TextInputType.phone,
                      maxLength: 11,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                        labelText: '手机号',
                        hintText: '请输入 11 位手机号',
                        counterText: '',
                        prefixIcon: const Icon(Icons.phone_iphone),
                        errorText: _phoneTouched ? _phoneError : null,
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (_mode == 1)
                      TextField(
                        controller: _passwordCtrl,
                        focusNode: _passwordFocus,
                        obscureText: true,
                        onChanged: (_) => setState(() {}),
                        decoration: InputDecoration(
                          labelText: '密码',
                          hintText: '请输入登录密码',
                          prefixIcon: const Icon(Icons.lock_outline),
                          errorText: _passwordTouched ? _passwordError : null,
                        ),
                      )
                    else
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _codeCtrl,
                              focusNode: _codeFocus,
                              keyboardType: TextInputType.number,
                              maxLength: 6,
                              inputFormatters: [
                                FilteringTextInputFormatter.digitsOnly
                              ],
                              onChanged: (_) => setState(() {}),
                              decoration: InputDecoration(
                                labelText: '验证码',
                                hintText: '6 位短信验证码',
                                counterText: '',
                                prefixIcon: const Icon(Icons.sms_outlined),
                                errorText: _codeTouched ? _codeError : null,
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: OutlinedButton(
                              onPressed:
                                  (_countdown > 0 || _sending || !_phoneValid)
                                      ? null
                                      : _sendCode,
                              child: Text(_countdown > 0
                                  ? '${_countdown}s 后重发'
                                  : '获取验证码'),
                            ),
                          ),
                        ],
                      ),
                    const SizedBox(height: 24),
                    DimiButton(
                      label: '登录',
                      onPressed: _formValid ? _login : null,
                      loading: _submitting,
                      expanded: true,
                    ),
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: _enteringPreview
                          ? null
                          : () => Navigator.of(context)
                              .pushNamed(RegisterScreen.routeName),
                      child: const Text('没有账号？注册新账号'),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            AgreementRow(
              agreed: _agreed,
              onChanged: (v) => setState(() => _agreed = v),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}
