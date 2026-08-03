import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../models/weight_log.dart';
import '../../theme/app_colors.dart';

class WeightLineChartPainter extends CustomPainter {
  WeightLineChartPainter({required this.entries, required this.accent});

  final List<WeightLogEntry> entries;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final gridPaint = Paint()
      ..color = hairline
      ..strokeWidth = 1;

    const padding = EdgeInsets.fromLTRB(8, 12, 8, 18);
    final inner = Rect.fromLTWH(
      padding.left,
      padding.top,
      size.width - padding.horizontal,
      size.height - padding.vertical,
    );

    for (var i = 0; i <= 3; i++) {
      final y = inner.top + inner.height * (i / 3);
      canvas.drawLine(Offset(inner.left, y), Offset(inner.right, y), gridPaint);
    }

    if (entries.length < 2) {
      _drawEmptyHint(canvas, size);
      return;
    }

    final values = entries.map((e) => e.weightKg).toList();
    final minV = values.reduce(math.min);
    final maxV = values.reduce(math.max);
    final pad = math.max((maxV - minV) * 0.25, 0.6);
    final lo = minV - pad;
    final hi = maxV + pad;
    final range = math.max(hi - lo, 0.001);

    final path = Path();
    final fillPath = Path();
    final dots = <Offset>[];

    for (var i = 0; i < entries.length; i++) {
      final t = entries.length == 1 ? 0.5 : i / (entries.length - 1);
      final x = inner.left + inner.width * t;
      final y = inner.bottom - ((entries[i].weightKg - lo) / range) * inner.height;
      final point = Offset(x, y);
      dots.add(point);
      if (i == 0) {
        path.moveTo(x, y);
        fillPath.moveTo(x, inner.bottom);
        fillPath.lineTo(x, y);
      } else {
        path.lineTo(x, y);
        fillPath.lineTo(x, y);
      }
    }
    fillPath.lineTo(dots.last.dx, inner.bottom);
    fillPath.close();

    final fillPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          accent.withValues(alpha: 0.32),
          accent.withValues(alpha: 0.02),
        ],
      ).createShader(inner);
    canvas.drawPath(fillPath, fillPaint);

    final linePaint = Paint()
      ..color = accent
      ..strokeWidth = 2.2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(path, linePaint);

    final ringPaint = Paint()
      ..color = bg
      ..style = PaintingStyle.fill;
    final dotPaint = Paint()..color = accent;
    for (final p in dots) {
      canvas.drawCircle(p, 3.4, ringPaint);
      canvas.drawCircle(p, 2.2, dotPaint);
    }

    _drawAxisLabel(
      canvas,
      '${hi.toStringAsFixed(1)} kg',
      Offset(inner.left, padding.top - 6),
      Alignment.topLeft,
    );
    _drawAxisLabel(
      canvas,
      '${lo.toStringAsFixed(1)} kg',
      Offset(inner.left, size.height - padding.bottom + 2),
      Alignment.bottomLeft,
    );
  }

  void _drawAxisLabel(Canvas canvas, String text, Offset anchor, Alignment a) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(
          color: textMuted,
          fontSize: 10,
          fontWeight: FontWeight.w500,
          fontFeatures: [FontFeature.tabularFigures()],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final dx = a == Alignment.bottomRight || a == Alignment.topRight
        ? anchor.dx - tp.width
        : anchor.dx;
    final dy = a == Alignment.bottomLeft || a == Alignment.bottomRight
        ? anchor.dy
        : anchor.dy;
    tp.paint(canvas, Offset(dx, dy));
  }

  void _drawEmptyHint(Canvas canvas, Size size) {
    final tp = TextPainter(
      text: const TextSpan(
        text: 'Logge dein Gewicht regelmÃ¤ÃŸig\nfÃ¼r eine Verlaufslinie.',
        style: TextStyle(
          color: textMuted,
          fontSize: 12,
          height: 1.4,
          fontWeight: FontWeight.w500,
        ),
      ),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: size.width - 24);
    tp.paint(
      canvas,
      Offset((size.width - tp.width) / 2, (size.height - tp.height) / 2),
    );
  }

  @override
  bool shouldRepaint(covariant WeightLineChartPainter old) =>
      old.entries != entries || old.accent != accent;
}

class BMIGaugePainter extends CustomPainter {
  BMIGaugePainter({required this.bmi});

  final double bmi;

  static const List<({double upper, Color color})> _zones = [
    (upper: 18.5, color: cyan),
    (upper: 25.0, color: lime),
    (upper: 30.0, color: orange),
    (upper: 40.0, color: danger),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 12.0;
    final center = Offset(size.width / 2, size.height - 6);
    final radius = math.min(size.width / 2 - stroke, size.height - stroke - 4);
    if (radius <= 0) return;
    final rect = Rect.fromCircle(center: center, radius: radius);

    final basePaint = Paint()
      ..color = surfaceSoft
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.butt;
    canvas.drawArc(rect, math.pi, math.pi, false, basePaint);

    const lo = 15.0;
    const hi = 40.0;
    const totalSpan = hi - lo;
    double cursor = lo;
    for (final zone in _zones) {
      final segStart = (cursor - lo) / totalSpan;
      final segEnd = (math.min(zone.upper, hi) - lo) / totalSpan;
      final startAngle = math.pi + math.pi * segStart;
      final sweep = math.pi * (segEnd - segStart);
      if (sweep <= 0) continue;
      final paint = Paint()
        ..color = zone.color.withValues(alpha: 0.85)
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.butt;
      canvas.drawArc(rect, startAngle, sweep, false, paint);
      cursor = zone.upper;
    }

    final clamped = bmi.clamp(lo, hi).toDouble();
    final t = (clamped - lo) / totalSpan;
    final pointerAngle = math.pi + math.pi * t;
    final activeColor = _colorFor(clamped);

    final pointerPaint = Paint()
      ..color = bg
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final tipOuter = Offset(
      center.dx + math.cos(pointerAngle) * (radius + stroke / 2 + 4),
      center.dy + math.sin(pointerAngle) * (radius + stroke / 2 + 4),
    );
    final tipInner = Offset(
      center.dx + math.cos(pointerAngle) * (radius - stroke / 2 - 2),
      center.dy + math.sin(pointerAngle) * (radius - stroke / 2 - 2),
    );
    canvas.drawLine(tipInner, tipOuter, pointerPaint);
    pointerPaint
      ..color = activeColor
      ..strokeWidth = 1.6;
    canvas.drawLine(tipInner, tipOuter, pointerPaint);

    canvas.drawCircle(center, 5, Paint()..color = bg);
    canvas.drawCircle(center, 3, Paint()..color = activeColor);

    final valueTp = TextPainter(
      text: TextSpan(
        text: bmi.toStringAsFixed(1),
        style: TextStyle(
          color: activeColor,
          fontSize: 24,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.6,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final labelTp = TextPainter(
      text: const TextSpan(
        text: 'BMI',
        style: TextStyle(
          color: textMuted,
          fontSize: 10,
          fontWeight: FontWeight.w600,
          letterSpacing: 1.2,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    labelTp.paint(
      canvas,
      Offset(center.dx - labelTp.width / 2, center.dy - radius * 0.55),
    );
    valueTp.paint(
      canvas,
      Offset(center.dx - valueTp.width / 2, center.dy - radius * 0.42),
    );
  }

  static Color _colorFor(double v) {
    for (final z in _zones) {
      if (v < z.upper) return z.color;
    }
    return danger;
  }

  static String labelFor(double v) {
    if (v < 18.5) return 'Untergewicht';
    if (v < 25.0) return 'Normal';
    if (v < 30.0) return 'Ãœbergewicht';
    return 'AdipÃ¶s';
  }

  static Color colorFor(double v) => _colorFor(v);

  @override
  bool shouldRepaint(covariant BMIGaugePainter old) => old.bmi != bmi;
}

class MiniRingPainter extends CustomPainter {
  MiniRingPainter({required this.value, required this.color, this.stroke = 6});

  final double value;
  final Color color;
  final double stroke;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2 - stroke / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);
    final base = Paint()
      ..color = surfaceSoft
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke;
    canvas.drawArc(rect, 0, math.pi * 2, false, base);

    final v = value.clamp(0.0, 1.0);
    if (v <= 0) return;
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, -math.pi / 2, math.pi * 2 * v, false, p);
  }

  @override
  bool shouldRepaint(covariant MiniRingPainter old) =>
      old.value != value || old.color != color || old.stroke != stroke;
}
