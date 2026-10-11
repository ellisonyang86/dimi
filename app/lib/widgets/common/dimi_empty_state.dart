/// 空状态占位组件：图标置于 kDimiPrimarySoft 圆形底衬上，
/// 标题 + 说明 + 可选行动按钮，用于列表为空、搜索无结果等场景。
///
/// 用法示例：
/// ```dart
/// DimiEmptyState(
///   icon: Icons.inbox_outlined,
///   title: '暂无消息',
///   message: '去广场看看，主动打个招呼吧',
///   actionLabel: '去广场',
///   onAction: () => Navigator.pushNamed(context, '/discover'),
/// )
/// ```
library;

import 'package:flutter/material.dart';

import '../../theme.dart';
import 'dimi_button.dart';

class DimiEmptyState extends StatelessWidget {
  const DimiEmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.actionLabel,
    this.onAction,
  });

  /// 顶部图标（64px，置于主色浅底圆形衬底上）
  final IconData icon;

  /// 主标题（17pt w600）
  final String title;

  /// 补充说明（13pt 灰）
  final String? message;

  /// 可选行动按钮文字；与 [onAction] 成对出现
  final String? actionLabel;

  /// 行动按钮回调
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 96,
              height: 96,
              decoration: const BoxDecoration(
                color: kDimiPrimarySoft,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Icon(icon, size: 64, color: kDimiPrimary),
            ),
            const SizedBox(height: 20),
            Text(
              title,
              style: const TextStyle(
                fontSize: 19,
                fontWeight: FontWeight.w600,
                color: kDimiText,
              ),
              textAlign: TextAlign.center,
            ),
            if (message != null && message!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                message!,
                style: const TextStyle(fontSize: 15, color: kDimiGray66),
                textAlign: TextAlign.center,
              ),
            ],
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 24),
              DimiButton(
                label: actionLabel!,
                onPressed: onAction,
                variant: DimiButtonVariant.secondary,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
