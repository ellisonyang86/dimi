import 'dart:async';

import 'package:flutter/material.dart';

import '../../theme.dart';

/// 每个列表共用一个控制器，始终只展开一行。
class DimiSwipeController extends ValueNotifier<Object?> {
  DimiSwipeController() : super(null);
  void close() => value = null;
}

class DimiSwipeAction {
  const DimiSwipeAction(
      {required this.label,
      required this.icon,
      required this.onPressed,
      this.color = kDimiPrimary,
      this.backgroundColor});
  final String label;
  final IconData icon;
  final Color color;
  final Color? backgroundColor;
  Color get fill =>
      backgroundColor ??
      (color == kDimiDanger
          ? kDimiDangerSoft
          : color == kDimiPrimary
              ? kDimiPrimaryFill
              : kDimiNeutralSoft);
  final FutureOr<void> Function() onPressed;
}

/// 左滑露出可点击按钮；拖动本身不执行操作，也不弹出菜单。
class DimiSwipeRow extends StatefulWidget {
  const DimiSwipeRow(
      {super.key,
      required this.id,
      required this.controller,
      required this.actions,
      required this.child});
  final Object id;
  final DimiSwipeController controller;
  final List<DimiSwipeAction> actions;
  final Widget child;

  @override
  State<DimiSwipeRow> createState() => _DimiSwipeRowState();
}

class _DimiSwipeRowState extends State<DimiSwipeRow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animation;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _animation = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 180));
    widget.controller.addListener(_onOpenChanged);
  }

  void _onOpenChanged() {
    if (widget.controller.value != widget.id) _animation.reverse();
  }

  @override
  void didUpdateWidget(covariant DimiSwipeRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onOpenChanged);
      widget.controller.addListener(_onOpenChanged);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onOpenChanged);
    _animation.dispose();
    super.dispose();
  }

  Future<void> _run(DimiSwipeAction action) async {
    if (_busy) return;
    setState(() => _busy = true);
    widget.controller.close();
    try {
      await _animation.reverse();
      if (mounted) await action.onPressed();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final extent =
          (widget.actions.length * 84.0).clamp(0.0, constraints.maxWidth * .78);
      return TapRegion(
        onTapOutside: (_) {
          if (widget.controller.value == widget.id) widget.controller.close();
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: _busy
              ? null
              : (_) {
                  widget.controller.value = widget.id;
                  _animation.stop();
                },
          onHorizontalDragUpdate: _busy
              ? null
              : (event) {
                  if (extent > 0) _animation.value -= event.delta.dx / extent;
                },
          onHorizontalDragEnd: _busy
              ? null
              : (event) {
                  final velocity = event.primaryVelocity ?? 0;
                  final open = velocity < -350 ||
                      (velocity <= 350 && _animation.value > .45);
                  if (open) {
                    _animation.forward();
                  } else {
                    widget.controller.close();
                  }
                },
          onHorizontalDragCancel: () => widget.controller.close(),
          child: AnimatedBuilder(
            animation: _animation,
            builder: (context, _) => ClipRect(
              child: Stack(children: [
                Positioned.fill(
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: SizedBox(
                      width: extent,
                      height: double.infinity,
                      child: IgnorePointer(
                        ignoring: _animation.value < .99 || _busy,
                        child: ExcludeSemantics(
                          excluding: _animation.value < .99,
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: widget.actions
                                .map((action) => Expanded(
                                      child: Material(
                                        color: action.fill,
                                        child: InkWell(
                                          onTap: () => _run(action),
                                          child: Padding(
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 4, vertical: 8),
                                            child: Center(
                                                child: Text(action.label,
                                                    textAlign: TextAlign.center,
                                                    maxLines: 2,
                                                    style: TextStyle(
                                                        color: action.color,
                                                        fontSize: 15,
                                                        fontWeight:
                                                            FontWeight.w600))),
                                          ),
                                        ),
                                      ),
                                    ))
                                .toList(),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Transform.translate(
                  offset: Offset(-extent * _animation.value, 0),
                  child: GestureDetector(
                    onTap:
                        _animation.value > 0 ? widget.controller.close : null,
                    child: AbsorbPointer(
                        absorbing: _animation.value > 0,
                        child:
                            Material(color: Colors.white, child: widget.child)),
                  ),
                ),
              ]),
            ),
          ),
        ),
      );
    });
  }
}
