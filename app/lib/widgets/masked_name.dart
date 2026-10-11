/// 真名展示组件。
/// real_name 由服务端按「真名渐显矩阵」判定后直接返回展示值
/// （全名 / 掩码「李*娟」/ null），本组件只做透传展示，不得二次加工。
library;

import 'package:flutter/material.dart';

import '../theme.dart';

class MaskedName extends StatelessWidget {
  const MaskedName(this.realName, {super.key, this.style});

  final String? realName;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final name = realName;
    if (name == null || name.isEmpty) return const SizedBox.shrink();
    return Text(
      name,
      style: style ?? const TextStyle(color: kDimiGray99, fontSize: 15),
      overflow: TextOverflow.ellipsis,
    );
  }
}
