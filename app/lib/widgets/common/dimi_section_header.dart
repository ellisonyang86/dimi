/// 分区标题：列表分组、表单分节的小标题（13pt w600 灰），
/// 右侧可挂 trailing（如「查看更多」文字按钮）。
///
/// 用法示例：
/// ```dart
/// DimiSectionHeader(title: '共同经历')
/// DimiSectionHeader(title: '新的朋友', trailing: TextButton(...))
/// ```
library;

import 'package:flutter/material.dart';

import '../../theme.dart';

class DimiSectionHeader extends StatelessWidget {
  const DimiSectionHeader({super.key, required this.title, this.trailing});

  /// 标题文字（13pt w600 kDimiGray66）
  final String title;

  /// 右侧可选挂件（通常是「查看更多」之类的轻操作）
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: kDimiGray66,
              ),
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}
