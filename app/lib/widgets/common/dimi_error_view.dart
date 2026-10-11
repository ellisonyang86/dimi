/// 加载失败视图：离线云图标 + 错误说明 + 重试按钮（DimiButton secondary）。
/// 用于网络异常、接口报错等可恢复错误的整页/区块占位。
///
/// 用法示例：
/// ```dart
/// if (_error != null) {
///   return DimiErrorView(message: _error!, onRetry: _load);
/// }
/// ```
library;

import 'package:flutter/material.dart';

import '../../theme.dart';
import 'dimi_button.dart';

class DimiErrorView extends StatelessWidget {
  const DimiErrorView({
    super.key,
    this.message = '加载失败，请稍后重试',
    this.onRetry,
  });

  /// 错误说明（13pt 灰）
  final String message;

  /// 重试回调；为 null 时不显示重试按钮
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_outlined, size: 64, color: kDimiGray66),
            const SizedBox(height: 16),
            Text(
              message,
              style: const TextStyle(fontSize: 15, color: kDimiGray66),
              textAlign: TextAlign.center,
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 24),
              DimiButton(
                label: '重试',
                variant: DimiButtonVariant.secondary,
                icon: Icons.refresh,
                onPressed: onRetry,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
