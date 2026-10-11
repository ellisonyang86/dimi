import 'package:flutter/material.dart';

/// 等待弹窗退场及 Overlay 移除后才返回，调用方可安全释放输入控制器。
/// Navigator.pop 的结果会先于退场动画到达，直接 showDialog 后 dispose
/// 会让动画中的 TextField 继续访问已释放的控制器。
Future<T?> showDimiDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  final route = DialogRoute<T>(
    context: context,
    builder: builder,
    barrierDismissible: barrierDismissible,
    themes: InheritedTheme.capture(from: context, to: navigator.context),
    barrierColor: DialogTheme.of(context).barrierColor ?? Colors.black54,
  );
  final result = await navigator.push(route);
  await route.completed;
  return result;
}
