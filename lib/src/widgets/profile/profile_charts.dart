import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../theme/app_tokens.dart';

/// Halbkreis-Skala mit Zeiger fuer den BMI.
///
/// Die Farben kommen als Felder herein statt aus einer Konstanten-Datei: der
/// Painter muss in beiden Anzeige-Modi zeichnen. [shouldRepaint] vergleicht sie
/// deshalb ALLE — beim Wechsel Hell/Dunkel aendert sich nur die Farbe, nicht
/// der Wert, und ein Painter, der nur den Wert vergleicht, laesst die alte
/// Zeichnung stehen.
class BMIGaugePainter extends CustomPainter {
  BMIGaugePainter({
    required this.bmi,
    required this.underColor,
    required this.normalColor,
    required this.overColor,
    required this.obeseColor,
    required this.trackColor,
    required this.pointerCoreColor,
    required this.labelColor,
  });

  /// Der uebliche Weg von den Tokens zum Painter. Hier — und nur hier — liegt
  /// die Zuordnung BMI-Zone → Zustandsfarbe.
  factory BMIGaugePainter.fromTokens(AppTokens t, double bmi) =>
      BMIGaugePainter(
        bmi: bmi,
        // Unter- UND Uebergewicht tragen denselben Warnton: der Token-Vertrag
        // kennt als Zustandsfarben nur `warning` und `danger`, die drei
        // Makro-Toene sind fuer Naehrwerte gesperrt. Die Position auf dem
        // Halbkreis (links bzw. rechts der Normalzone) unterscheidet beide
        // eindeutig. Ein eigener, nicht alarmierender „info"-Ton waere hier
        // besser — der gehoert als Token nach AppTokens, nicht hierher.
        underColor: t.warning,
        normalColor: t.accent,
        overColor: t.warning,
        obeseColor: t.danger,
        trackColor: t.tile,
        // Der Zeiger sitzt auf einer Karte, nicht auf dem Seitengrund: sein
        // Kern muss die KARTEN-Flaeche aufnehmen, sonst steht im Hell-Modus
        // ein dunkler Punkt mitten auf der hellen Karte.
        pointerCoreColor: t.surf,
        labelColor: t.ink2,
      );

  final double bmi;
  final Color underColor, normalColor, overColor, obeseColor;
  final Color trackColor, pointerCoreColor, labelColor;

  /// Untere/obere Kante der gezeichneten Skala (der Halbkreis bildet 15–40 ab).
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

    // Ein nicht-endlicher BMI (Groesse 0) darf keinen NaN-Winkel erzeugen —
    // sonst zeichnet der Zeiger ins Nichts.
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
        text: bmi.isFinite ? bmi.toStringAsFixed(1).replaceAll('.', ',') : '–',
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

  /// Die Zonenfarbe fuer einen Chip neben der Skala — dieselbe Zuordnung wie
  /// im Painter, ohne dass der Aufrufer einen bauen muss.
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
      old.underColor != underColor ||
      old.normalColor != normalColor ||
      old.overColor != overColor ||
      old.obeseColor != obeseColor ||
      old.trackColor != trackColor ||
      old.pointerCoreColor != pointerCoreColor ||
      old.labelColor != labelColor;
}
