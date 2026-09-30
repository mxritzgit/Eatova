import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/app_tokens.dart';
import '../../widgets/common/motion.dart';

/// The calorie card's 270° arc (dark redesign): a track, the eaten share as
/// a violet gradient stroke and a white knob at its end.
///
/// Geometry of the design's 240 px SVG — circle r 100, stroke 18, starting at
/// 135° (bottom left) and sweeping clockwise — scaled to [width]. The box is
/// 214/240 of the width tall: the arc's open bottom needs no more. Passive;
/// the caller supplies the semantics.
class TodayCalorieArc extends StatelessWidget {
  const TodayCalorieArc({super.key, required this.progress, this.width = 240});

  /// Eaten share of the budget, clamped to 0..1.
  final double progress;
  final double width;

  static const double designWidth = 240;
  static const double designHeight = 214;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final safe = progress.isFinite ? progress.clamp(0.0, 1.0) : 0.0;
    return SizedBox(
      width: width,
      height: width * designHeight / designWidth,
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: safe),
        duration: motionDuration(context, const Duration(milliseconds: 420)),
        curve: Curves.easeOutCubic,
        builder: (context, value, _) => CustomPaint(
          painter: TodayArcPainter(
            progress: value,
            track: t.arcTrack,
            start: t.arcStart,
            end: t.arcEnd,
            knob: t.ink,
            // The design's knob halo, rgba(201, 184, 255, 0.22).
            halo: t.accentText.withValues(alpha: 0.22),
          ),
        ),
      ),
    );
  }
}

class TodayArcPainter extends CustomPainter {
  const TodayArcPainter({
    required this.progress,
    required this.track,
    required this.start,
    required this.end,
    required this.knob,
    required this.halo,
  });

  final double progress;
  final Color track, start, end, knob, halo;

  static const Offset _center = Offset(120, 120);
  static const double _radius = 100;
  static const double _stroke = 18;
  static const double _startAngle = 3 * math.pi / 4;
  static const double _sweep = 3 * math.pi / 2;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / TodayCalorieArc.designWidth);
    final rect = Rect.fromCircle(center: _center, radius: _radius);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _stroke
      ..strokeCap = StrokeCap.round
      ..color = track;
    canvas.drawArc(rect, _startAngle, _sweep, false, paint);

    final p = progress.clamp(0.0, 1.0);
    if (p > 0) {
      // The design's objectBoundingBox gradient (0,1)->(1,0), rotated with the
      // circle by 135°, runs top (arcStart) to bottom (arcEnd) over the
      // rotated box's diagonal: 100·√2 either side of the centre.
      const reach = _radius * math.sqrt2;
      paint.shader =
          LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: <Color>[start, end],
          ).createShader(
            Rect.fromLTRB(0, _center.dy - reach, 240, _center.dy + reach),
          );
      canvas.drawArc(rect, _startAngle, _sweep * p, false, paint);
    }

    final angle = _startAngle + _sweep * p;
    final at = _center + Offset(math.cos(angle), math.sin(angle)) * _radius;
    canvas.drawCircle(at, 15, Paint()..color = halo);
    canvas.drawCircle(at, 7, Paint()..color = knob);
    canvas.restore();
  }

  @override
  bool shouldRepaint(TodayArcPainter old) =>
      old.progress != progress ||
      old.track != track ||
      old.start != start ||
      old.end != end ||
      old.knob != knob ||
      old.halo != halo;
}
