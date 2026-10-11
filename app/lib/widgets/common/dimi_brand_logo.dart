import 'package:flutter/material.dart';

import '../../theme.dart';

/// 与 Android / H5 共用由 gen_launcher_icons.py 生成的重逢标识。
class DimiBrandLogo extends StatelessWidget {
  const DimiBrandLogo({super.key, this.size = 72});
  final double size;

  @override
  Widget build(BuildContext context) => Semantics(
        label: 'DIMI 围城',
        image: true,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
              color: kDimiPrimaryFill,
              borderRadius: BorderRadius.circular(size * .22)),
          child: Image.asset('assets/brand/dimi_mark.png',
              excludeFromSemantics: true),
        ),
      );
}
