import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/app_tokens.dart';
import '../../widgets/common/motion.dart';

/// Passive progress display; callers supply the localized semantics.
class TodayProgressRing extends StatelessWidget {
  const TodayProgressRing({
    super.key,
    required this.progress,
    required this.size,
    required this.child,
    this.fillCenter = false,
  });

  final double progress;
  final double size;
  final Widget child;
  final bool fillCenter;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final safe = progress.isFinite ? progress.clamp(0.0, 1.0) : 0.0;
    return SizedBox.square(
      dimension: size,
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: safe),
        duration: motionDuration(context, const Duration(milliseconds: 320)),
        curve: Curves.easeOutCubic,
        child: Center(child: child),
        builder: (context, value, child) => CustomPaint(
          painter: _RingPainter(
            progress: value,
            fill: t.progressAccent,
            track: t.surf,
            fillCenter: fillCenter,
          ),
          child: child,
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  const _RingPainter({
    required this.progress,
    required this.fill,
    required this.track,
    required this.fillCenter,
  });
  final double progress;
  final Color fill, track;
  final bool fillCenter;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.shortestSide * 0.075;
    final rect = (Offset.zero & size).deflate(stroke / 2);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..color = track;
    if (fillCenter) {
      canvas.drawCircle(
        rect.center,
        size.shortestSide / 2 - stroke * 1.7,
        Paint()..color = track,
      );
    }
    canvas.drawOval(rect, paint);
    if (progress <= 0) return;
    paint.color = fill;
    if (progress >= 1) {
      canvas.drawOval(rect, paint);
    } else {
      canvas.drawArc(rect, -math.pi / 2, 2 * math.pi * progress, false, paint);
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.progress != progress ||
      old.fill != fill ||
      old.track != track ||
      old.fillCenter != fillCenter;
}
