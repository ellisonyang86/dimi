/// 验证等级徽标（V0 自述 / V1 同窗互证 / V2 证据验证 / V3 组织背书）。
/// V0 不展示已验证徽标（对应交集横幅降级为「未验证」限定句的场景）。
library;

import 'package:flutter/material.dart';

import '../theme.dart';

class VerifyBadge extends StatelessWidget {
  const VerifyBadge(this.level, {super.key, this.label});

  final int level;

  /// 可附加上下文，如「同班」→「✓ 已验证同班」
  final String? label;

  @override
  Widget build(BuildContext context) {
    if (level <= 0) {
      // 深警示色压浅底：kDimiWarning 压 kDimiWarningSoft 仅 2.7:1 不达标
      return _tag('未验证', kDimiWarningSoft, kDimiWarningDeep);
    }
    final suffix = (label != null && label!.isNotEmpty) ? label! : '';
    return _tag(
      '✓ 已验证$suffix',
      kDimiPrimarySoft,
      kDimiPrimary,
    );
  }

  Widget _tag(String text, Color bg, Color fg) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(text, style: TextStyle(fontSize: 14, color: fg)),
    );
  }
}
