import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../theme/app_tokens.dart';

// ---------------------------------------------------------------------------
// METERS — sparkline.
//
// It takes values from the network or from user input, so handling 0,
// negatives, NaN and empty series without throwing is the job, not a
// convenience.
// ---------------------------------------------------------------------------

/// Axis-free polyline for trends (weight, kcal per week).
class Sparkline extends StatelessWidget {
  const Sparkline({
    super.key,
    required this.values,
    this.stroke,
    this.dotFill,
    this.height = 74,
  });

  /// Fewer than two points make no line — the area stays empty instead of
  /// throwing.
  final List<double> values;

  final Color? stroke;
  final Color? dotFill;
  final double height;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(
        size: Size.infinite,
        painter: _SparklinePainter(
          values: values,
          stroke: stroke ?? t.accent,
          dotFill: dotFill ?? t.surf,
        ),
      ),
    );
  }
}

class _SparklinePainter extends CustomPainter {
  _SparklinePainter({
    required this.values,
    required this.stroke,
    required this.dotFill,
  });

  final List<double> values;
  final Color stroke, dotFill;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;

    final minV = values.reduce((a, b) => a < b ? a : b);
    final maxV = values.reduce((a, b) => a > b ? a : b);
    if (!minV.isFinite || !maxV.isFinite) return;
    final range = (maxV - minV).abs() < 0.001 ? 1.0 : maxV - minV;

    const pad = 6.0;
    final points = <Offset>[];
    for (var i = 0; i < values.length; i++) {
      final x = pad + (size.width - pad * 2) * (i / (values.length - 1));
      final y = pad + (size.height - pad * 2) * (1 - (values[i] - minV) / range);
      points.add(Offset(x, y));
    }

    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (final p in points.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }

    canvas.drawPath(
      path,
      Paint()
        ..color = stroke
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );

    final last = points.last;
    canvas.drawCircle(last, 5, Paint()..color = dotFill);
    canvas.drawCircle(
      last,
      5,
      Paint()
        ..color = stroke
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );
  }

  // The store hands over a freshly built list, so an identity check would
  // repaint on every rebuild; compare elements instead.
  @override
  bool shouldRepaint(_SparklinePainter old) =>
      old.stroke != stroke ||
      old.dotFill != dotFill ||
      !listEquals(old.values, values);
}
