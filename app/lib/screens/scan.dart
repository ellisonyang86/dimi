/// 扫一扫：全屏相机扫码加好友。
/// 识别 `dimi://u/{userId}` → 进对方资料卡（加好友在资料卡内完成）并移除本页；
/// 非 DIMI 二维码 → toast 提示并继续扫；
/// 相机权限被拒 → 整页错误视图引导去系统设置（原生侧 MainActivity 提供跳转）。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../theme.dart';
import '../widgets/common/dimi_button.dart';
import '../widgets/common/dimi_error_view.dart';
import 'profile_card.dart';

class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> with WidgetsBindingObserver {
  /// 跳转系统设置的桥（MainActivity.kt 实现 openAppSettings）
  static const _settingsChannel = MethodChannel('dimi/settings');

  /// 相机控制器，必须 dispose（否则相机资源泄漏）
  final MobileScannerController _controller = MobileScannerController();

  /// 相机错误（权限被拒 / 启动失败）；非空时整页切到错误视图
  MobileScannerException? _cameraError;

  /// 已识别并跳转资料卡：锁定后续回调，避免资料卡重复入栈
  bool _navigated = false;

  /// 同一内容 500ms 节流（识别回调可能连续多帧触发同一结果）
  String? _lastValue;
  DateTime? _lastAt;

  @override
  void initState() {
    super.initState();
    // 外部传入 controller 时插件不自动处理前后台切换，需自行暂停/恢复
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // 从系统设置返回（可能刚授予相机权限）：清错误并重启相机
      setState(() => _cameraError = null);
      unawaited(_startSafely());
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      unawaited(_stopSafely());
    }
  }

  Future<void> _startSafely() async {
    try {
      await _controller.start();
    } on MobileScannerException catch (e) {
      // 已在运行（切回前台时未真正退后台）无需处理；其余错误上屏
      if (e.errorCode == MobileScannerErrorCode.controllerAlreadyInitialized) {
        return;
      }
      if (mounted) setState(() => _cameraError = e);
    } catch (_) {
      // 相机竞争启动等瞬时异常忽略，依赖下一帧错误回调兜底
    }
  }

  Future<void> _stopSafely() async {
    try {
      await _controller.stop();
    } catch (_) {
      // 未启动（如权限被拒从未成功起流）时忽略
    }
  }

  /// 识别回调：取首个有效条码，500ms 内同一结果不重复处理
  void _onDetect(BarcodeCapture capture) {
    if (_navigated) return;
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;
      if (value == null || value.isEmpty) continue;
      final now = DateTime.now();
      if (value == _lastValue &&
          _lastAt != null &&
          now.difference(_lastAt!).inMilliseconds < 500) {
        return;
      }
      _lastValue = value;
      _lastAt = now;
      _handleValue(value);
      return;
    }
  }

  /// 解析扫码内容：dimi://u/{userId} 进资料卡，其余 toast 后继续扫
  void _handleValue(String value) {
    final match = RegExp(r'^dimi://u/(\d+)$').firstMatch(value);
    if (match == null) {
      final messenger = ScaffoldMessenger.of(context);
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('这不是 DIMI 的二维码')));
      return;
    }
    final userId = int.parse(match.group(1)!);
    _navigated = true;
    // 资料卡入栈后把本页从路由栈移除（资料卡返回时直接回入口页）；
    // 若被资料卡 300ms 防抖拦下（栈顶仍是本页）则解锁，允许继续扫
    final scanRoute = ModalRoute.of(context);
    ProfileCardScreen.open(context, userId);
    if (scanRoute != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (scanRoute.isCurrent) {
          _navigated = false;
        } else {
          Navigator.of(context).removeRoute(scanRoute);
        }
      });
    }
  }

  /// 相机错误回调：build 阶段触发，帧末再同步到页面状态整页切换
  Widget _scannerErrorBuilder(BuildContext context, MobileScannerException e) {
    if (_cameraError?.errorCode != e.errorCode) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _cameraError = e);
      });
    }
    return const SizedBox.shrink();
  }

  /// 去系统设置开启相机权限
  Future<void> _openSettings() async {
    try {
      await _settingsChannel.invokeMethod<void>('openAppSettings');
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('无法打开系统设置，请手动前往')));
    }
  }

  /// 重试：清错误重建相机预览（MobileScanner autoStart 重新请求权限/起流）
  void _retry() {
    setState(() => _cameraError = null);
  }

  /// 扫描框区域：正方形，宽屏取 68% 宽（上限 300），纵向偏上 42% 处
  Rect _scanWindow(Size size) {
    final side = math.min(size.width * 0.68, 300.0);
    return Rect.fromCenter(
      center: Offset(size.width / 2, size.height * 0.42),
      width: side,
      height: side,
    );
  }

  @override
  Widget build(BuildContext context) {
    final error = _cameraError;
    return Scaffold(
      backgroundColor: Colors.black,
      body: error != null ? _buildErrorPage(error) : _buildScanner(),
    );
  }

  Widget _buildScanner() {
    return Stack(
      fit: StackFit.expand,
      children: [
        MobileScanner(
          controller: _controller,
          onDetect: _onDetect,
          errorBuilder: _scannerErrorBuilder,
        ),
        LayoutBuilder(
          builder: (context, constraints) {
            final size = Size(constraints.maxWidth, constraints.maxHeight);
            final window = _scanWindow(size);
            return Stack(
              fit: StackFit.expand,
              children: [
                // 镂空遮罩 + 四角黛绿描边（纯展示，不拦截相机手势）
                IgnorePointer(
                  child: CustomPaint(painter: _ScanOverlayPainter(window)),
                ),
                Positioned(
                  top: window.bottom + 24,
                  left: 0,
                  right: 0,
                  child: const IgnorePointer(
                    child: Text(
                      '将二维码放入框内，即可自动扫描',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 16, color: Colors.white),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
        // 顶部返回 + 标题（压相机预览，白字）
        SafeArea(
          child: SizedBox(
            height: kToolbarHeight,
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back, color: Colors.white),
                  tooltip: '返回',
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
                const Expanded(
                  child: Text(
                    '扫一扫',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                ),
                // 与左侧返回钮对称留白，保证标题居中
                const SizedBox(width: 48),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 相机错误整页：权限被拒 → 引导去系统设置；其余 → DimiErrorView 重试
  Widget _buildErrorPage(MobileScannerException error) {
    final denied = error.errorCode == MobileScannerErrorCode.permissionDenied;
    return Container(
      color: kDimiBg,
      child: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: [
            Align(
              alignment: Alignment.topLeft,
              child: IconButton(
                icon: const Icon(Icons.arrow_back, color: kDimiText),
                tooltip: '返回',
                onPressed: () => Navigator.of(context).maybePop(),
              ),
            ),
            if (denied)
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.photo_camera_outlined,
                          size: 64, color: kDimiGray66),
                      const SizedBox(height: 16),
                      const Text(
                        '相机权限未开启，无法扫码\n请在系统设置中允许 DIMI 使用相机',
                        style: TextStyle(fontSize: 15, color: kDimiGray66),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 24),
                      DimiButton(
                        label: '去设置开启',
                        icon: Icons.settings_outlined,
                        onPressed: _openSettings,
                      ),
                      const SizedBox(height: 12),
                      DimiButton(
                        label: '重试',
                        variant: DimiButtonVariant.secondary,
                        icon: Icons.refresh,
                        onPressed: _retry,
                      ),
                    ],
                  ),
                ),
              )
            else
              DimiErrorView(message: '相机启动失败，请稍后重试', onRetry: _retry),
          ],
        ),
      ),
    );
  }
}

/// 扫描区遮罩：半透明黑罩中间镂空，四角黛绿（kDimiPrimary）圆角描边
class _ScanOverlayPainter extends CustomPainter {
  _ScanOverlayPainter(this.window);

  final Rect window;

  /// 遮罩透明度（对齐微信扫一扫的压暗强度）
  static const _maskColor = Color(0x80000000);

  /// 四角描边臂长 / 线宽 / 圆角
  static const _cornerArm = 26.0;
  static const _cornerWidth = 4.0;
  static const _cornerRadius = 12.0;

  @override
  void paint(Canvas canvas, Size size) {
    // 镂空遮罩：整屏矩形减去扫描框（evenOdd）
    final maskPath = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRRect(RRect.fromRectAndRadius(
          window, const Radius.circular(_cornerRadius)));
    canvas.drawPath(maskPath, Paint()..color = _maskColor);

    // 四角黛绿描边（L 形圆角短线）
    final cornerPaint = Paint()
      ..color = kDimiPrimary
      ..style = PaintingStyle.stroke
      ..strokeWidth = _cornerWidth
      ..strokeCap = StrokeCap.round;
    const half = _cornerWidth / 2;
    final rect = window.deflate(-half); // 描边中线压在框边
    final corners = [
      // 左上：右、下两臂
      [rect.topLeft, rect.topLeft + const Offset(_cornerArm, 0)],
      [rect.topLeft, rect.topLeft + const Offset(0, _cornerArm)],
      // 右上
      [rect.topRight, rect.topRight + const Offset(-_cornerArm, 0)],
      [rect.topRight, rect.topRight + const Offset(0, _cornerArm)],
      // 左下
      [rect.bottomLeft, rect.bottomLeft + const Offset(_cornerArm, 0)],
      [rect.bottomLeft, rect.bottomLeft + const Offset(0, -_cornerArm)],
      // 右下
      [rect.bottomRight, rect.bottomRight + const Offset(-_cornerArm, 0)],
      [rect.bottomRight, rect.bottomRight + const Offset(0, -_cornerArm)],
    ];
    for (final arm in corners) {
      canvas.drawLine(arm[0], arm[1], cornerPaint);
    }
  }

  @override
  bool shouldRepaint(_ScanOverlayPainter oldDelegate) =>
      oldDelegate.window != window;
}
