/// 骨架屏组件：加载占位用圆角灰条，带 1.2s 呼吸动画
///（kDimiPrimarySoft 与白色渐变往返），灰绿调与全局莫兰迪色系一致。
///
/// 用法示例：
/// ```dart
/// // 单条灰条
/// DimiSkeleton(width: 120, height: 14)
///
/// // 列表骨架：头像 + 两行灰条，共 6 行
/// DimiListSkeleton(itemCount: 6)
/// ```
library;

import 'package:flutter/material.dart';

import '../../theme.dart';

/// 单条骨架：圆角灰条，宽 / 高 / 圆角可配
class DimiSkeleton extends StatefulWidget {
  const DimiSkeleton({
    super.key,
    this.width = double.infinity,
    this.height = 14,
    this.radius = 6,
  });

  /// 宽度，默认撑满父级
  final double width;

  /// 高度
  final double height;

  /// 圆角
  final double radius;

  @override
  State<DimiSkeleton> createState() => _DimiSkeletonState();
}

class _DimiSkeletonState extends State<DimiSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Container(
          width: widget.width,
          height: widget.height,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(widget.radius),
            color: Color.lerp(kDimiPrimarySoft, kDimiBg, _controller.value),
          ),
        );
      },
    );
  }
}

/// 列表骨架：每行为「圆形头像 + 两行灰条」组合，共 [itemCount] 行
class DimiListSkeleton extends StatelessWidget {
  const DimiListSkeleton({super.key, this.itemCount = 6});

  /// 骨架行数
  final int itemCount;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: itemCount,
      separatorBuilder: (_, __) => const SizedBox(height: 16),
      itemBuilder: (_, __) => const _SkeletonRow(),
    );
  }
}

class _SkeletonRow extends StatelessWidget {
  const _SkeletonRow();

  @override
  Widget build(BuildContext context) {
    return const Row(
      children: [
        DimiSkeleton(width: 46, height: 46, radius: 23),
        SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DimiSkeleton(width: 140, height: 14),
              SizedBox(height: 8),
              DimiSkeleton(height: 12),
            ],
          ),
        ),
      ],
    );
  }
}
