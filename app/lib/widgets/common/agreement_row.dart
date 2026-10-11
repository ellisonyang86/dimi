/// 协议同意行：Checkbox（默认不勾）+ 可点击的《用户服务协议》《隐私政策》链接
///（服务端托管 markdown 原文，见 screens/legal_doc.dart），未勾选时由业务侧阻断提交。
/// 抽取自登录页 / 注册页的内联实现；整行可点击切换勾选，热区扩到 48dp 高。
///
/// 用法示例：
/// ```dart
/// AgreementRow(
///   agreed: _agreed,
///   onChanged: (v) => setState(() => _agreed = v),
/// )
/// ```
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../screens/legal_doc.dart';
import '../../theme.dart';

class AgreementRow extends StatefulWidget {
  const AgreementRow(
      {super.key, required this.agreed, required this.onChanged});

  /// 当前勾选状态
  final bool agreed;

  /// 勾选状态变化回调（业务侧一般 setState 更新并据此阻断提交）
  final ValueChanged<bool> onChanged;

  @override
  State<AgreementRow> createState() => _AgreementRowState();
}

class _AgreementRowState extends State<AgreementRow> {
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
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => widget.onChanged(!widget.agreed),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: SizedBox(
                width: 24,
                height: 24,
                child: Checkbox(
                  value: widget.agreed,
                  onChanged: (v) => widget.onChanged(v ?? false),
                  activeColor: kDimiPrimary,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 15),
                child: Text.rich(
                  TextSpan(
                    style: const TextStyle(
                        fontSize: 14, color: kDimiGray99, height: 1.5),
                    children: [
                      const TextSpan(text: '我已阅读并同意'),
                      TextSpan(
                        text: '《用户服务协议》',
                        style: const TextStyle(color: kDimiPrimary),
                        recognizer: _agreementTap,
                      ),
                      const TextSpan(text: '和'),
                      TextSpan(
                        text: '《隐私政策》',
                        style: const TextStyle(color: kDimiPrimary),
                        recognizer: _privacyTap,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
