import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../theme/app_tokens.dart';
import '../common/motion.dart';

// ---------------------------------------------------------------------------
// MESSGERAETE — Tick-Anzeige, Makro-Balken, Mahlzeiten-Avatar, Sparkline,
// Punktraster.
//
// Alle vier rechnen mit Werten aus dem Netz oder aus Nutzereingaben. Sie
// muessen deshalb auch mit 0, negativ, groesser als das Ziel, NaN und leeren
// Reihen umgehen, ohne zu werfen — das ist hier kein Komfort, sondern die
// eigentliche Aufgabe.
// ---------------------------------------------------------------------------

/// Die Kalorien-Anzeige: eine Reihe Striche, die sich mit Lime fuellt.
class TickGauge extends StatelessWidget {
  const TickGauge({
    super.key,
    required this.progress,
    this.height = 28,
    this.fillColor,
    this.trackColor,
  });

  /// 0..1; alles darueber, darunter oder Nicht-Zahlen werden eingefangen.
  final double progress;

  final double height;

  /// Standard: [AppTokens.lime] auf einer abgedunkelten [AppTokens.onForest]-
  /// Spur — die Anzeige sitzt in der Vorlage auf der Forest-Hero-Karte.
  final Color? fillColor;
  final Color? trackColor;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final safe = progress.isFinite ? progress.clamp(0.0, 1.0) : 0.0;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: safe),
      // DESIGN_REFACTOR §5: „Bewegung reduzieren" laesst den Balken sofort
      // auf seinem Wert stehen, statt ihn ueber eine halbe Sekunde
      // hochlaufen zu lassen.
      duration: motionDuration(context, const Duration(milliseconds: 550)),
      curve: Curves.easeOutCubic,
      builder: (context, value, _) => SizedBox(
        height: height,
        width: double.infinity,
        child: CustomPaint(
          painter: _TickGaugePainter(
            progress: value,
            trackColor: trackColor ?? t.onForest.withValues(alpha: 0.20),
            fillColor: fillColor ?? t.lime,
          ),
        ),
      ),
    );
  }
}

class _TickGaugePainter extends CustomPainter {
  _TickGaugePainter({
    required this.progress,
    required this.trackColor,
    required this.fillColor,
  });

  final double progress;
  final Color trackColor, fillColor;

  static const double tickWidth = 4;
  static const double gap = 5;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..style = PaintingStyle.fill;
    final count = ((size.width + gap) / (tickWidth + gap)).floor();
    final filledUpTo = size.width * progress;

    for (var i = 0; i < count; i++) {
      final x = i * (tickWidth + gap);
      paint.color = (x + tickWidth) <= filledUpTo ? fillColor : trackColor;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, 0, tickWidth, size.height),
          const Radius.circular(2),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_TickGaugePainter old) =>
      old.progress != progress ||
      old.fillColor != fillColor ||
      old.trackColor != trackColor;
}

/// Eine Makro-Zeile: Name, Balken, „Wert / Ziel Einheit".
class MacroBar extends StatelessWidget {
  const MacroBar({
    super.key,
    required this.label,
    required this.value,
    required this.goal,
    required this.unit,
    required this.color,
  });

  final String label;
  final int value, goal;
  final String unit;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final pct = goal <= 0 ? 0.0 : (value / goal).clamp(0.0, 1.0);

    // Abweichung von der Vorlage: dort stehen hier feste 52 px bzw. 68 px.
    // Bei textScaler 2.0 blieben davon zwei Zeichen pro Zeile uebrig, deshalb
    // wachsen die beiden Spalten mit der Systemschrift — gedeckelt, damit der
    // Balken dazwischen nicht verschwindet.
    //
    // Die 52 der Vorlage sind fuer „Carbs" gerechnet. Auf Deutsch heisst das
    // Makro „Kohlenhydrate" und braucht bei AppType.ui(12) rund 80 px — es
    // brach deshalb SCHON BEI SYSTEMSCHRIFT 1.0 zweizeilig um, waehrend
    // „Protein" und „Fett" einzeilig blieben; die drei Balken standen dadurch
    // sichtbar versetzt. Grundbreite deshalb 84 (nachgemessen: der laengste
    // deutsche Makroname passt, mit etwas Luft fuer breitere Schriftschnitte).
    // Der Deckel steigt mit: bei 2.0 bleiben 124/120 fuer die Spalten und
    // rund 49 px Balken auf einem 393er Telefon.
    final scaler = MediaQuery.textScalerOf(context);
    final labelWidth = scaler.scale(84).clamp(84.0, 124.0);
    final valueWidth = scaler.scale(68).clamp(68.0, 120.0);

    return Padding(
      padding: const EdgeInsets.only(bottom: 13),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: labelWidth,
            child: Text(
              label,
              style: AppType.ui(12, weight: FontWeight.w600, color: t.ink),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: 0, end: pct),
              duration: motionDuration(
                context,
                const Duration(milliseconds: 500),
              ),
              curve: Curves.easeOutCubic,
              builder: (context, v, _) => ClipRRect(
                borderRadius: BorderRadius.circular(5),
                child: LinearProgressIndicator(
                  value: v,
                  minHeight: 9,
                  backgroundColor: t.tile,
                  valueColor: AlwaysStoppedAnimation<Color>(color),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: valueWidth,
            child: Text.rich(
              TextSpan(
                text: '$value',
                style: AppType.ui(12, weight: FontWeight.w600, color: t.ink),
                children: <InlineSpan>[
                  TextSpan(
                    text: ' / $goal$unit',
                    style:
                        AppType.ui(12, weight: FontWeight.w500, color: t.ink2),
                  ),
                ],
              ),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }
}

/// Der Buchstaben-Avatar vor einer Mahlzeit.
class MealAvatar extends StatelessWidget {
  const MealAvatar({
    super.key,
    required this.letter,
    required this.color,
    this.size = 40,
  });

  final String letter;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(size * 0.33),
      ),
      alignment: Alignment.center,
      // Abweichung von der Vorlage: FittedBox. Die Kachel hat eine feste
      // Kantenlaenge, der Buchstabe waechst aber mit der Systemschrift — ohne
      // Schrumpfen liefe er bei 2.0 aus der Kachel heraus.
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          letter,
          style: AppType.display(
            size * 0.38,
            weight: FontWeight.w700,
            // Nicht die volle Slot-Farbe: die traegt auf ihrer eigenen
            // 16-%-Tint im Hell-Modus nur 2.15:1 (Kohlenhydrat-Amber).
            color: t.readableOnTint(color),
          ),
        ),
      ),
    );
  }
}

/// Linienzug ohne Achsen fuer Verlaeufe (Gewicht, Kalorien je Woche).
class Sparkline extends StatelessWidget {
  const Sparkline({
    super.key,
    required this.values,
    this.stroke,
    this.dotFill,
    this.height = 74,
  });

  /// Weniger als zwei Punkte ergeben keine Linie — die Flaeche bleibt dann
  /// leer, statt zu werfen.
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

  // Die Reihe kommt als frisch gebaute Liste aus dem Store; ein
  // Identitaetsvergleich wuerde bei jedem Rebuild neu zeichnen lassen,
  // obwohl sich kein Wert geaendert hat — deshalb Elementvergleich.
  @override
  bool shouldRepaint(_SparklinePainter old) =>
      old.stroke != stroke ||
      old.dotFill != dotFill ||
      !listEquals(old.values, values);
}

/// Das Punktraster hinter den Marken-Flaechen (Hero-Karten, Banner).
/// Fuer `Positioned.fill` gebaut: es nimmt sich immer die volle Flaeche.
class DotGridBackground extends StatelessWidget {
  const DotGridBackground({super.key, required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size.infinite,
      painter: _DotGridPainter(color: color),
    );
  }
}

class _DotGridPainter extends CustomPainter {
  _DotGridPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final dot = Paint()..color = color;
    for (double y = 7; y < size.height; y += 14) {
      for (double x = 7; x < size.width; x += 14) {
        canvas.drawCircle(Offset(x, y), 1, dot);
      }
    }
  }

  @override
  bool shouldRepaint(_DotGridPainter old) => old.color != color;
}
