/// 精确找人（DIMI号 / 手机号）：单输入框 → GET /discover/search-user。
/// 频控（42901）时弹滑块验证，拿到 captcha_token 后重试。
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../widgets/common/dimi_finder.dart';
import '../widgets/common/dimi_button.dart';
import '../widgets/common/dimi_empty_state.dart';
import '../widgets/common/dimi_error_view.dart';
import '../widgets/slider_captcha.dart';
import 'friend_apply.dart';
import 'profile_card.dart';

class ExactSearchView extends StatefulWidget {
  const ExactSearchView({super.key});

  @override
  State<ExactSearchView> createState() => _ExactSearchViewState();
}

class _ExactSearchViewState extends State<ExactSearchView> {
  final _ctrl = TextEditingController();
  bool _loading = false;
  bool _searched = false;
  UserBrief? _hit;
  String? _error;

  static final _phoneReg = RegExp(r'^1[3-9]\d{9}$');

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  bool get _isPhone => _phoneReg.hasMatch(_ctrl.text.trim());

  Future<void> _search({String? captchaToken}) async {
    if (_loading && captchaToken == null) return;
    final q = _ctrl.text.trim();
    if (q.isEmpty) {
      _toast('请输入 DIMI号 或 手机号');
      return;
    }
    setState(() {
      _loading = true;
      _searched = true;
      _hit = null;
      _error = null;
    });
    try {
      final result = await context.read<DimiApi>().searchUserExact(
            dimiNo: _isPhone ? null : q,
            phone: _isPhone ? q : null,
            captchaToken: captchaToken,
          );
      if (!mounted) return;
      setState(() => _hit = result.items.isEmpty ? null : result.items.first);
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.isNeedCaptcha && captchaToken == null) {
        // 精确找人频控（20 次/时）：滑块验证通过后自动重试一次
        final token = await showSliderCaptcha(context);
        if (token != null && mounted) {
          await _search(captchaToken: token);
          return;
        }
        if (mounted) setState(() => _searched = false);
      } else {
        setState(() => _error = e.message);
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListView(
        padding: const EdgeInsets.all(16),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        children: [
          DimiFinderPanel(children: [
            TextField(
                controller: _ctrl,
                enabled: !_loading,
                decoration: const InputDecoration(
                    labelText: 'DIMI 号或手机号', hintText: '输入对方的账号'),
                onChanged: (_) => setState(() {
                      _hit = null;
                      _searched = false;
                      _error = null;
                    }),
                onSubmitted: (_) => _search()),
            const SizedBox(height: 16),
            DimiButton(
                label: '查找',
                icon: Icons.search,
                loading: _loading,
                onPressed: () => _search()),
          ]),
          const SizedBox(height: 24),
          if (_error != null)
            DimiErrorView(message: _error!, onRetry: () => _search())
          else if (!_loading && !_searched)
            const DimiEmptyState(
                icon: Icons.person_search_outlined,
                title: '找到你认识的人',
                message: '输入 DIMI 号或手机号，精确找到 TA')
          else if (!_loading && _hit == null)
            const DimiEmptyState(
                icon: Icons.person_search_outlined,
                title: '未找到该用户',
                message: '请核对账号，或请对方检查添加方式的隐私设置')
          else if (_hit != null)
            DimiPeopleResults(
                items: [_hit!],
                onOpen: (u) => ProfileCardScreen.open(context, u.userId),
                onAdd: (u) => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                        builder: (_) => FriendApplyScreen(target: u)))),
        ],
      );
}
