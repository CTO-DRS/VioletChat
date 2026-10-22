import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// v0.1.0 — WhatsApp-style swipe-to-reply wrapper, RTL-safe.
///
/// Dragging a bubble horizontally past [threshold] (logical px) fires
/// [onReply]. BOTH physical directions trigger, so the gesture feels
/// identical in the Arabic RTL layout and in any future LTR locale —
/// the reveal arrow follows the drag from the trailing side.
class SwipeToReply extends StatefulWidget {
  final Widget child;
  final VoidCallback onReply;
  final double threshold;
  final double maxDrag;

  const SwipeToReply({
    super.key,
    required this.child,
    required this.onReply,
    this.threshold = 72,
    this.maxDrag = 96,
  });

  /// Pure drag shaping (testable): clamp magnitude to [maxDrag],
  /// preserve the direction sign.
  static double shapeDrag(double dx, {double maxDrag = 96}) {
    if (dx.isNaN) return 0;
    final sign = dx.isNegative ? -1.0 : 1.0;
    final mag = dx.abs();
    return mag > maxDrag ? sign * maxDrag : dx;
  }

  /// Whether a release at drag offset [dx] crosses [threshold].
  static bool crossesThreshold(double dx, double threshold) =>
      dx.abs() >= threshold;

  @override
  State<SwipeToReply> createState() => _SwipeToReplyState();
}

class _SwipeToReplyState extends State<SwipeToReply>
    with SingleTickerProviderStateMixin {
  late final AnimationController _snap = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
    value: 1,
  );
  double _drag = 0;

  void _onUpdate(DragUpdateDetails d) {
    setState(() => _drag = SwipeToReply.shapeDrag(
          _drag + d.delta.dx,
          maxDrag: widget.maxDrag,
        ));
  }

  void _onEnd(DragEndDetails d) {
    final fired = SwipeToReply.crossesThreshold(_drag, widget.threshold);
    if (fired) HapticFeedback.selectionClick();
    _snap.forward(from: 0);
    _drag = 0;
    if (fired) widget.onReply();
  }

  @override
  void dispose() {
    _snap.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = CurvedAnimation(parent: _snap, curve: Curves.easeOutCubic);
    final progress = (_drag.abs() / widget.maxDrag).clamp(0.0, 1.0);
    final revealIcon = Icon(
      Icons.reply_rounded,
      size: 22,
      color: Theme.of(context)
          .colorScheme
          .onSurfaceVariant
          .withValues(alpha: 0.35 + 0.65 * progress),
    );

    return AnimatedBuilder(
      animation: _snap,
      builder: (context, child) {
        final dx = _drag * (1 - t.value);
        final dragging = _drag != 0;
        return Stack(
          alignment: AlignmentDirectional.centerStart,
          children: [
            // Reveal behind: reply arrow slides in from the side the
            // bubble is being pulled away from.
            PositionedDirectional(
              start: dx > 0 ? 0 : null,
              end: dx > 0 ? null : 0,
              child: Opacity(opacity: dragging ? progress : 0, child: revealIcon),
            ),
            Transform.translate(
              offset: Offset(dx, 0),
              child: child,
            ),
          ],
        );
      },
      child: GestureDetector(
        behavior: HitTestBehavior.deferToChild,
        onHorizontalDragUpdate: _onUpdate,
        onHorizontalDragEnd: _onEnd,
        child: widget.child,
      ),
    );
  }
}
