/// 统一按钮组件：封装 primary / secondary / danger 三种语义变体，
/// 自带 loading 态（禁用 + 18px 转圈）与最小 48 高触达区（中老年友好）。
///
/// 用法示例：
/// ```dart
/// DimiButton(label: '登录', onPressed: _submit, loading: _submitting, expanded: true)
/// DimiButton(label: '再想想', variant: DimiButtonVariant.secondary, onPressed: _back)
/// DimiButton(label: '删除', variant: DimiButtonVariant.danger, icon: Icons.delete_outline, onPressed: _delete)
/// ```
library;

import 'package:flutter/material.dart';

import '../../theme.dart';

/// 按钮语义变体
enum DimiButtonVariant {
  /// 主按钮：浅鼠尾草底，用于主流程操作
  primary,

  /// 次按钮：更浅的柔和底色，用于重试、取消等操作
  secondary,

  /// 危险按钮：浅陶粉底，用于删除、拉黑等操作
  danger,
}

class DimiButton extends StatelessWidget {
  const DimiButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.variant = DimiButtonVariant.primary,
    this.loading = false,
    this.icon,
    this.expanded = false,
  });

  /// 按钮文字
  final String label;

  /// 点击回调；传 null 或 loading 中时禁用
  final VoidCallback? onPressed;

  /// 语义变体，默认 [DimiButtonVariant.primary]
  final DimiButtonVariant variant;

  /// 加载中：禁用点击并显示 18px 转圈（替代文字）
  final bool loading;

  /// 可选前置图标
  final IconData? icon;

  /// 是否撑满父级宽度（表单页主按钮常用）
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final child = loading
        ? SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: variant == DimiButtonVariant.danger
                  ? kDimiDanger
                  : kDimiPrimary,
            ),
          )
        : Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 18),
                const SizedBox(width: 6),
              ],
              Text(label),
            ],
          );
    final effectiveOnPressed = loading ? null : onPressed;
    final button = switch (variant) {
      DimiButtonVariant.primary => FilledButton(
          onPressed: effectiveOnPressed,
          child: child,
        ),
      DimiButtonVariant.secondary => OutlinedButton(
          onPressed: effectiveOnPressed,
          // 转圈描边按钮下用主色，避免白转圈隐形
          child: loading
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: kDimiPrimary,
                  ),
                )
              : child,
        ),
      DimiButtonVariant.danger => FilledButton(
          onPressed: effectiveOnPressed,
          style: FilledButton.styleFrom(
              backgroundColor: kDimiDangerSoft, foregroundColor: kDimiDanger),
          child: child,
        ),
    };
    if (!expanded) return button;
    return SizedBox(width: double.infinity, child: button);
  }
}
