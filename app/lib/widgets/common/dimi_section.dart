/// 微信式分组列表容器与条目（替代「每项一张圆角卡」的生硬排版）。
///
/// DimiSection：白底整块、仅最外侧圆角 12、组内条目间发丝分隔线
/// （indent 对齐文字起点），组与组之间靠页面米白底色（kDimiBg）自然留白。
///
/// DimiSectionItem：图标 + 标题 + 可选副标题 + 右箭头，最小高度 48dp。
///
/// 用法示例：
/// ```dart
/// DimiSection(
///   children: [
///     DimiSectionItem(icon: Icons.people_alt_outlined, title: '我的好友', onTap: ...),
///     DimiSectionItem(icon: Icons.school_outlined, title: '我的教育经历', onTap: ...),
///   ],
/// )
/// ```
library;

import 'package:flutter/material.dart';

import '../../theme.dart';

/// 分隔线默认缩进：左 padding 16 + 图标 22 + 图文间距 12 = 50，对齐文字起点
const double kDimiSectionDividerIndent = 50;

/// ListTile 条目（含 40px leading）的文字起点缩进：16 + 40 + 16 = 72
const double kDimiSectionDividerIndentTile = 72;

class DimiSection extends StatelessWidget {
  const DimiSection({
    super.key,
    required this.children,
    this.margin = const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
    this.dividerIndent = kDimiSectionDividerIndent,
  });

  /// 组内条目（DimiSectionItem / ListTile / SwitchListTile 均可）
  final List<Widget> children;

  /// 组外边距：默认左右 12、上下 5，组间由页面米白底色形成间距
  final EdgeInsetsGeometry margin;

  /// 组内发丝分隔线左侧缩进（对齐文字起点）
  final double dividerIndent;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: margin,
      child: Material(
        color: Colors.white,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(kDimiRadiusCard),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0)
                Divider(
                  height: 1,
                  thickness: 0.5,
                  indent: dividerIndent,
                  color: kDimiHairline,
                ),
              children[i],
            ],
          ],
        ),
      ),
    );
  }
}

class DimiSectionItem extends StatelessWidget {
  const DimiSectionItem({
    super.key,
    this.icon,
    this.iconColor = kDimiPrimary,
    this.iconBackground,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
  });

  /// 左侧图标；为 null 时不占位（分隔线 indent 需相应调小）
  final IconData? icon;

  /// 图标颜色，默认主色黛绿
  final Color iconColor;

  /// 图标底衬色；非空时图标置于 40px 圆角方块底衬上（发现页大入口用法）
  final Color? iconBackground;

  /// 标题（15pt 深色）
  final String title;

  /// 可选副标题（12pt 灰）
  final String? subtitle;

  /// 右侧挂件；缺省为右箭头（chevron）
  final Widget? trailing;

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final icon = this.icon;
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        // 触控目标不小于 48dp（适老化规范）
        constraints: const BoxConstraints(minHeight: 48),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              if (icon != null) ...[
                if (iconBackground != null)
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: iconBackground,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    alignment: Alignment.center,
                    child: Icon(icon, size: 22, color: iconColor),
                  )
                else
                  Icon(icon, size: 22, color: iconColor),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(fontSize: 17, color: kDimiText),
                    ),
                    if (subtitle != null && subtitle!.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle!,
                        style:
                            const TextStyle(fontSize: 14, color: kDimiGray66),
                      ),
                    ],
                  ],
                ),
              ),
              // 右箭头用 kDimiGray99（≥3:1），不用过浅的 kDimiGrayCC
              trailing ??
                  const Icon(Icons.chevron_right, size: 20, color: kDimiGray99),
            ],
          ),
        ),
      ),
    );
  }
}
