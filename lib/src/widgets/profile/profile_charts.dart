import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../theme/app_tokens.dart';

/// Half-circle BMI gauge with a pointer.
///
/// Colors arrive as fields because the painter draws in both display modes;
/// [shouldRepaint] must compare all of them, since a light/dark switch changes
/// only the colors, not the value.
class BMIGaugePainter extends CustomPainter {
  BMIGaugePainter({
    required this.bmi,
    required this.valueLabel,
    required this.underColor,
    required this.normalColor,
    required this.overColor,
    required this.obeseColor,
    required this.trackColor,
    required this.pointerCoreColor,
    required this.labelColor,
  });

  /// The usual path from tokens to painter; the only place mapping BMI zone
  /// to state color. [valueLabel] arrives pre-formatted because a
  /// [CustomPainter] has no access to the active language while painting.
  factory BMIGaugePainter.fromTokens(
    AppTokens t,
    double bmi,
    String valueLabel,
  ) =>
      BMIGaugePainter(
        bmi: bmi,
        valueLabel: valueLabel,
        // Under- and overweight share `warning`: the token contract offers
        // only `warning` and `danger` as state colors, and position on the
        // arc already tells them apart. A calmer "info" token would be better.
        underColor: t.warning,
        normalColor: t.accent,
        overColor: t.warning,
        obeseColor: t.danger,
        trackColor: t.tile,
        // The pointer sits on a card, not the page background, so its core
        // must pick up the card surface.
        pointerCoreColor: t.surf,
        labelColor: t.ink2,
      );

  final double bmi;
  final String valueLabel;
  final Color underColor, normalColor, overColor, obeseColor;
  final Color trackColor, pointerCoreColor, labelColor;

  /// Lower/upper edge of the drawn scale; the arc maps 15–40.
  static const double _lo = 15.0;
  static const double _hi = 40.0;

  List<({double upper, Color color})> get _zones =>
      <({double upper, Color color})>[
        (upper: 18.5, color: underColor),
        (upper: 25.0, color: normalColor),
        (upper: 30.0, color: overColor),
        (upper: _hi, color: obeseColor),
      ];

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 12.0;
    final center = Offset(size.width / 2, size.height - 6);
    final radius = math.min(size.width / 2 - stroke, size.height - stroke - 4);
    if (radius <= 0) return;
    final rect = Rect.fromCircle(center: center, radius: radius);

    final basePaint = Paint()
      ..color = trackColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.butt;
    canvas.drawArc(rect, math.pi, math.pi, false, basePaint);

    const totalSpan = _hi - _lo;
    var cursor = _lo;
    for (final zone in _zones) {
      final segStart = (cursor - _lo) / totalSpan;
      final segEnd = (math.min(zone.upper, _hi) - _lo) / totalSpan;
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

    // A non-finite BMI (height 0) must not produce a NaN angle.
    final safeBmi = bmi.isFinite ? bmi : _lo;
    final clamped = safeBmi.clamp(_lo, _hi).toDouble();
    final position = (clamped - _lo) / totalSpan;
    final pointerAngle = math.pi + math.pi * position;
    final activeColor = _colorFor(clamped);

    final pointerPaint = Paint()
      ..color = pointerCoreColor
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

    canvas.drawCircle(center, 5, Paint()..color = pointerCoreColor);
    canvas.drawCircle(center, 3, Paint()..color = activeColor);

    final valueTp = TextPainter(
      text: TextSpan(
        text: valueLabel,
        style: AppType.display(24, color: activeColor),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final labelTp = TextPainter(
      text: TextSpan(text: 'BMI', style: AppType.eyebrow(labelColor)),
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

  Color _colorFor(double v) {
    for (final z in _zones) {
      if (v < z.upper) return z.color;
    }
    return obeseColor;
  }

  /// Zone color for a chip beside the gauge; same mapping as the painter,
  /// without having to construct one.
  static Color colorFor(AppTokens t, double v) {
    if (!v.isFinite) return t.ink2;
    if (v < 18.5) return t.warning;
    if (v < 25.0) return t.accent;
    if (v < 30.0) return t.warning;
    return t.danger;
  }

  static String labelFor(double v, AppLocalizations l10n) {
    if (v < 18.5) return l10n.profileBmiZoneUnder;
    if (v < 25.0) return l10n.profileBmiZoneNormal;
    if (v < 30.0) return l10n.profileBmiZoneOver;
    return l10n.profileBmiZoneObese;
  }

  @override
  bool shouldRepaint(covariant BMIGaugePainter old) =>
      old.bmi != bmi ||
      old.valueLabel != valueLabel ||
      old.underColor != underColor ||
      old.normalColor != normalColor ||
      old.overColor != overColor ||
      old.obeseColor != obeseColor ||
      old.trackColor != trackColor ||
      old.pointerCoreColor != pointerCoreColor ||
      old.labelColor != labelColor;
}
