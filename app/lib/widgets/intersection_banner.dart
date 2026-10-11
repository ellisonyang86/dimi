/// 交集横幅：绿色渐变 + 左侧竖条，直接展示服务端返回的分级措辞
/// （含 V0 未验证限定句，如「你们的经历显示同为 92 级 XX 中学（未验证）」）。
library;

import 'package:flutter/material.dart';

import '../theme.dart';

class IntersectionBanner extends StatelessWidget {
  const IntersectionBanner(this.text, {super.key, this.compact = false});

  final String? text;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final t = text;
    if (t == null || t.isEmpty) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(
        horizontal: 12,
        vertical: compact ? 8 : 10,
      ),
      decoration: BoxDecoration(
        color: kDimiPrimarySoft,
        border: const Border(
          left: BorderSide(color: kDimiPrimary, width: 3),
        ),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        '🎓 $t',
        style: TextStyle(
          fontSize: compact ? 12 : 13,
          color: kDimiPrimary,
          height: 1.5,
        ),
      ),
    );
  }
}
