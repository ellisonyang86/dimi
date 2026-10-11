/// 滑块验证码组件（契约 /captcha/slider + /captcha/verify）：
/// 拉取挑战后按 width/height/notch_y 用 CustomPainter 画背景（bg_seed 做
/// 确定性渐变/图形）+ 缺口示意；底部滑轨拖动拼图块，松手把偏移 x 提交
/// /captcha/verify；成功回调 captcha_token，失败自动刷新挑战重试。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../theme.dart';

/// 弹出滑块验证对话框，成功返回 captcha_token，取消返回 null
Future<String?> showSliderCaptcha(BuildContext context) {
  return showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      title: const Text('安全验证', style: TextStyle(fontSize: 18)),
      contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      content: SliderCaptcha(
        onVerified: (token) => Navigator.of(ctx).pop(token),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('取消'),
        ),
      ],
    ),
  );
}

/// 发送短信验证码（滑块兜底）：sms/send 触发频控（42901）时弹滑块验证，
/// 拿到 captcha_token 后带 token 重试一次。返回是否发送成功；
/// 非频控错误原样抛 ApiException（调用方展示 message）。
Future<bool> sendSmsWithCaptcha(
  BuildContext context,
  String phone, {
  String scene = 'login',
}) async {
  try {
    await context.read<DimiApi>().sendSms(phone, scene: scene);
    return true;
  } on ApiException catch (e) {
    if (!e.isNeedCaptcha || !context.mounted) rethrow;
    final token = await showSliderCaptcha(context);
    if (token == null || !context.mounted) return false;
    await context.read<DimiApi>().sendSms(
          phone,
          scene: scene,
          captchaToken: token,
        );
    return true;
  }
}

class SliderCaptcha extends StatefulWidget {
  const SliderCaptcha({super.key, required this.onVerified});

  /// 验证成功回调 captcha_token
  final ValueChanged<String> onVerified;

  @override
  State<SliderCaptcha> createState() => _SliderCaptchaState();
}

class _SliderCaptchaState extends State<SliderCaptcha> {
  SliderChallenge? _challenge;
  bool _loading = true;
  bool _verifying = false;
  bool _verifyFailed = false; // 上一次校验失败（展示引导文案，拖动即清除）
  String? _error;
  double _dx = 0;

  static const _handleW = 44.0;

  /// 缺口横坐标客户端不可知（服务端持有），此处仅按 seed 画视觉参考位
  int get _seed => _challenge == null ? 0 : _challenge!.bgSeed.hashCode.abs();

  double get _notchX {
    if (_challenge == null) return 180;
    final w = _challenge!.width;
    return (w * 0.45 + _seed % (w ~/ 3)).clamp(w * 0.4, w - 40.0);
  }

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
      _dx = 0;
    });
    try {
      final c = await context.read<DimiApi>().sliderCaptcha();
      if (!mounted) return;
      setState(() => _challenge = c);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _submit() async {
    final c = _challenge;
    if (c == null || _verifying) return;
    setState(() => _verifying = true);
    try {
      final token =
          await context.read<DimiApi>().verifySlider(c.captchaId, _dx.round());
      if (!mounted) return;
      widget.onVerified(token);
    } on ApiException {
      // 校验失败：提示引导文案并自动刷新挑战重试
      if (!mounted) return;
      setState(() => _verifyFailed = true);
      await _refresh();
    } finally {
      if (mounted) setState(() => _verifying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = _challenge;
    return SizedBox(
      width: 280,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_loading)
            const SizedBox(
              height: 160,
              child: Center(
                child: CircularProgressIndicator(color: kDimiPrimary),
              ),
            )
          else if (_error != null || c == null)
            SizedBox(
              height: 160,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_error ?? '挑战加载失败，请检查网络后重试',
                        textAlign: TextAlign.center,
                        style:
                            const TextStyle(fontSize: 15, color: kDimiGray66)),
                    const SizedBox(height: 8),
                    OutlinedButton(
                        onPressed: _refresh, child: const Text('重试')),
                  ],
                ),
              ),
            )
          else ...[
            // 挑战图：背景 + 缺口参考位 + 随拖动平移的拼图块
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: c.width.toDouble(),
                height: c.height.toDouble(),
                child: CustomPaint(
                  painter: _CaptchaPainter(
                    seed: _seed,
                    notchX: _notchX,
                    notchY: c.notchY.toDouble(),
                    pieceDx: _dx,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            // 滑轨
            LayoutBuilder(
              builder: (ctx, constraints) {
                // 块宽 40，对齐 painter；width<=40 属挑战数据异常，maxDx 兜底按 1 算
                final maxDx = math.max(1.0, c.width.toDouble() - 40);
                final trackW = constraints.maxWidth;
                return Container(
                  height: _handleW,
                  decoration: BoxDecoration(
                    color: kDimiBg,
                    borderRadius: BorderRadius.circular(_handleW / 2),
                    border: Border.all(color: kDimiHairline),
                  ),
                  child: Stack(
                    alignment: Alignment.centerLeft,
                    children: [
                      const Center(
                        child: Text(
                          '向右拖动滑块完成验证',
                          style: TextStyle(fontSize: 14, color: kDimiGray99),
                        ),
                      ),
                      Positioned(
                        left: _dx / maxDx * (trackW - _handleW),
                        child: GestureDetector(
                          onHorizontalDragUpdate: _verifying
                              ? null
                              : (d) => setState(() {
                                    _dx = (_dx +
                                            d.delta.dx /
                                                (trackW - _handleW) *
                                                maxDx)
                                        .clamp(0.0, maxDx);
                                    // 重新拖动视为新一轮尝试，清除失败提示
                                    _verifyFailed = false;
                                  }),
                          onHorizontalDragEnd:
                              _verifying ? null : (_) => _submit(),
                          child: Container(
                            width: _handleW,
                            height: _handleW,
                            decoration: const BoxDecoration(
                              color: kDimiPrimary,
                              shape: BoxShape.circle,
                            ),
                            child: _verifying
                                ? const Padding(
                                    padding: EdgeInsets.all(12),
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2, color: Colors.white),
                                  )
                                : const Icon(Icons.double_arrow,
                                    color: Colors.white, size: 20),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
            // 校验失败引导文案（占位行高固定，避免弹出时布局跳动）
            const SizedBox(height: 8),
            SizedBox(
              height: 18,
              child: _verifyFailed
                  ? const Text('再试一次，把拼图对齐缺口即可',
                      style: TextStyle(fontSize: 14, color: kDimiWarningDeep))
                  : null,
            ),
          ],
        ],
      ),
    );
  }
}

/// 挑战图画笔：bg_seed 确定性渐变 + 装饰图形 + 缺口示意 + 拼图块
class _CaptchaPainter extends CustomPainter {
  _CaptchaPainter({
    required this.seed,
    required this.notchX,
    required this.notchY,
    required this.pieceDx,
  });

  final int seed;
  final double notchX;
  final double notchY;
  final double pieceDx;

  static const _piece = 40.0;

  @override
  void paint(Canvas canvas, Size size) {
    final rand = math.Random(seed);
    // 背景：seed 决定的两个色相做线性渐变
    final h1 = (seed % 360).toDouble();
    final h2 = (h1 + 60 + rand.nextInt(60)) % 360;
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = LinearGradient(
          colors: [
            HSVColor.fromAHSV(1, h1, 0.35, 0.85).toColor(),
            HSVColor.fromAHSV(1, h2, 0.45, 0.7).toColor(),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ).createShader(Offset.zero & size),
    );
    // 装饰圆（确定性随机）
    final deco = Paint()..color = Colors.white.withValues(alpha: 0.12);
    for (var i = 0; i < 6; i++) {
      canvas.drawCircle(
        Offset(rand.nextDouble() * size.width, rand.nextDouble() * size.height),
        12 + rand.nextDouble() * 26,
        deco,
      );
    }
    final top = (notchY - _piece / 2).clamp(0.0, size.height - _piece);
    // 缺口参考位（空心阴影示意）
    canvas.drawRRect(
      RRect.fromRectAndRadius(
          Rect.fromLTWH(notchX, top, _piece, _piece), const Radius.circular(6)),
      Paint()..color = Colors.black.withValues(alpha: 0.25),
    );
    // 拼图块（随滑块平移）
    final pieceLeft = pieceDx.clamp(0.0, size.width - _piece);
    final pieceRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(pieceLeft, top, _piece, _piece),
        const Radius.circular(6));
    canvas.drawRRect(
        pieceRect, Paint()..color = Colors.white.withValues(alpha: 0.9));
    canvas.drawRRect(
      pieceRect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = kDimiPrimary,
    );
  }

  @override
  bool shouldRepaint(_CaptchaPainter old) =>
      old.pieceDx != pieceDx || old.seed != seed;
}
