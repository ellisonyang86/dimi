/// 注册页：手机号 + 验证码 + 昵称 + 出生年份（必填，未成年人门槛由服务端判定）。
/// <14 周岁不予注册；14–18 周岁提示暂不提供服务 —— 服务端返回 40001 时
/// 直接展示其 message（见 V0.9 计划书 §4 未成年人边界）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../state/session.dart';
import '../theme.dart';
import '../widgets/common/agreement_row.dart';
import '../widgets/common/dimi_brand_logo.dart';
import '../widgets/common/dimi_button.dart';
import '../widgets/slider_captcha.dart';
import 'onboarding_education.dart';

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  static const routeName = '/register';

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _phoneCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  final _nicknameCtrl = TextEditingController();
  final _inviteCtrl = TextEditingController();
  final _phoneFocus = FocusNode();
  final _codeFocus = FocusNode();
  final _nicknameFocus = FocusNode();
  int? _birthYear;
  bool _agreed = false;
  bool _sending = false;
  bool _submitting = false;
  int _countdown = 0;
  Timer? _timer;

  /// 失焦标记：字段失焦后才展示内联报错，避免边输入边报错打扰
  bool _phoneTouched = false;
  bool _codeTouched = false;
  bool _nicknameTouched = false;

  static final _phoneReg = RegExp(r'^1[3-9]\d{9}$');
  static final _codeReg = RegExp(r'^\d{6}$');

  List<int> get _yearOptions {
    final now = DateTime.now().year;
    return List<int>.generate(now - 1939, (i) => now - i);
  }

  bool get _phoneValid => _phoneReg.hasMatch(_phoneCtrl.text.trim());
  bool get _codeValid => _codeReg.hasMatch(_codeCtrl.text.trim());

  bool get _nicknameValid {
    final len = _nicknameCtrl.text.trim().length;
    return len >= 1 && len <= 24;
  }

  /// 表单是否全部合法（决定提交按钮是否可用）
  bool get _formValid =>
      _phoneValid && _codeValid && _nicknameValid && _birthYear != null;

  String? get _phoneError => _phoneValid ? null : '请输入正确的 11 位手机号';
  String? get _codeError => _codeValid ? null : '请输入 6 位短信验证码';
  String? get _nicknameError => _nicknameValid ? null : '请输入 1–24 字的昵称';

  @override
  void initState() {
    super.initState();
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
    _nicknameFocus.addListener(() {
      if (!_nicknameFocus.hasFocus && !_nicknameTouched) {
        setState(() => _nicknameTouched = true);
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _phoneCtrl.dispose();
    _codeCtrl.dispose();
    _nicknameCtrl.dispose();
    _inviteCtrl.dispose();
    _phoneFocus.dispose();
    _codeFocus.dispose();
    _nicknameFocus.dispose();
    super.dispose();
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _sendCode() async {
    final phone = _phoneCtrl.text.trim();
    if (!_phoneReg.hasMatch(phone)) {
      _toast('请输入正确的手机号');
      return;
    }
    setState(() => _sending = true);
    try {
      final sent = await sendSmsWithCaptcha(context, phone, scene: 'register');
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

  Future<void> _register() async {
    final phone = _phoneCtrl.text.trim();
    final code = _codeCtrl.text.trim();
    final nickname = _nicknameCtrl.text.trim();
    if (!_phoneReg.hasMatch(phone)) {
      _toast('请输入正确的手机号');
      return;
    }
    if (!_codeReg.hasMatch(code)) {
      _toast('请输入 6 位短信验证码');
      return;
    }
    if (nickname.isEmpty || nickname.length > 24) {
      _toast('请输入 1–24 字的昵称');
      return;
    }
    if (_birthYear == null) {
      _toast('请选择出生年份');
      return;
    }
    if (!_agreed) {
      _toast('请先阅读并勾选同意《用户服务协议》和《隐私政策》');
      return;
    }
    setState(() => _submitting = true);
    try {
      final token = await context.read<DimiApi>().register(
            phone: phone,
            smsCode: code,
            nickname: nickname,
            birthYear: _birthYear,
            inviteChannel: _inviteCtrl.text.trim(),
            agreementVersion: kAgreementVersion,
          );
      if (!mounted) return;
      await context.read<Session>().login(token);
      if (!mounted) return;
      // 注册成功后进入经历填写引导（V0.9 主链路第二环）
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute<void>(
            builder: (_) => const OnboardingEducationScreen()),
        (route) => false,
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      // <14 周岁 / 14–18 周岁的拒绝文案由服务端 message 携带，直接展示
      _toast(e.message);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  /// 出生年份滚轮选择：底部弹层 + ListWheelScrollView，默认停在 1985
  Future<void> _pickBirthYear() async {
    final years = _yearOptions;
    var temp = _birthYear ?? 1985;
    final picked = await showModalBottomSheet<int>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(kDimiRadiusSheet)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('取消'),
                    ),
                    const Text(
                      '选择出生年份',
                      style:
                          TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, temp),
                      child: const Text('确定'),
                    ),
                  ],
                ),
              ),
              SizedBox(
                height: 220,
                child: ListWheelScrollView(
                  itemExtent: 44,
                  physics: const FixedExtentScrollPhysics(),
                  controller: FixedExtentScrollController(
                      initialItem: years.indexOf(temp)),
                  onSelectedItemChanged: (i) => temp = years[i],
                  children: [
                    for (final y in years)
                      Center(
                        child:
                            Text('$y 年', style: const TextStyle(fontSize: 17)),
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
    if (picked != null) setState(() => _birthYear = picked);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('注册')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          children: [
            const SizedBox(height: 16),
            // 品牌区：城门图形标识 + 标题 / slogan 分级排版（紧凑横向布局）
            Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const DimiBrandLogo(size: 48),
                  const SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('DIMI · 围城',
                          style: Theme.of(context).textTheme.titleLarge),
                      const Text(
                        '走出通讯录的围城，找回走散的人',
                        style: TextStyle(fontSize: 15, color: kDimiGray99),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            // 表单卡片化
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    TextField(
                      controller: _phoneCtrl,
                      focusNode: _phoneFocus,
                      keyboardType: TextInputType.phone,
                      maxLength: 11,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                        labelText: '手机号',
                        counterText: '',
                        prefixIcon: const Icon(Icons.phone_iphone),
                        errorText: _phoneTouched ? _phoneError : null,
                      ),
                    ),
                    const SizedBox(height: 12),
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
                    const SizedBox(height: 12),
                    TextField(
                      controller: _nicknameCtrl,
                      focusNode: _nicknameFocus,
                      maxLength: 24,
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                        labelText: '昵称',
                        hintText: '老同学将通过昵称与真名认出你',
                        counterText: '',
                        prefixIcon: const Icon(Icons.person_outline),
                        errorText: _nicknameTouched ? _nicknameError : null,
                      ),
                    ),
                    const SizedBox(height: 12),
                    // 出生年份：点击弹出滚轮选择（替代 86 项下拉）
                    InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: _pickBirthYear,
                      child: InputDecorator(
                        decoration: const InputDecoration(
                          labelText: '出生年份',
                          prefixIcon: Icon(Icons.cake_outlined),
                        ),
                        child: Text(
                          _birthYear == null ? '请选择' : '$_birthYear 年',
                          style: TextStyle(
                            fontSize: 17,
                            color: _birthYear == null ? kDimiGray99 : kDimiText,
                          ),
                        ),
                      ),
                    ),
                    const Padding(
                      padding: EdgeInsets.only(top: 6, bottom: 4),
                      child: Text(
                        '本产品不向未满 14 周岁用户提供服务；14–18 周岁用户暂不提供注册。',
                        style: TextStyle(fontSize: 14, color: kDimiGray99),
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _inviteCtrl,
                      decoration: const InputDecoration(
                        labelText: '邀请码（选填）',
                        hintText: '召集令 / 校友会渠道码',
                        prefixIcon: Icon(Icons.card_giftcard_outlined),
                      ),
                    ),
                    const SizedBox(height: 8),
                    AgreementRow(
                      agreed: _agreed,
                      onChanged: (v) => setState(() => _agreed = v),
                    ),
                    const SizedBox(height: 16),
                    DimiButton(
                      label: '注册并登录',
                      onPressed: _formValid ? _register : null,
                      loading: _submitting,
                      expanded: true,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}
