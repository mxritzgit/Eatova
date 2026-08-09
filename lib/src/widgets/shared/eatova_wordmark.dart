import 'package:flutter/material.dart';

import '../../theme/app_tokens.dart';

/// Eatova-Wortmarke: „eat" + Kamera-Fokusring als „o" + „va".
///
/// Der Fokusring (Kreis, Mittelpunkt-Dot, vier Ticks auf 12/3/6/9 Uhr) ist
/// das Scan-Motiv des Brandings (Logo-Entscheid 2026-08); gezeichnet als
/// CustomPaint statt Bild-Asset, damit die Marke in jeder Größe und
/// Pixeldichte scharf bleibt.
class EatovaWordmark extends StatelessWidget {
  const EatovaWordmark({
    super.key,
    this.fontSize = 24,
    this.textColor,
    this.ringColor,
  });

  final double fontSize;

  /// Ohne Angabe nimmt die Marke das **Marken-Flächenpaar** aus [AppTokens]:
  /// `onForest` für die Schrift, `lime` für den Ring.
  ///
  /// Bewusst NICHT `ink`/`accent`: die Wortmarke steht heute ausschließlich
  /// auf `auth_screen.dart`, und dieser Screen ist in beiden Anzeige-Modi
  /// dunkel (`backgroundColor: bg` aus `app_colors.dart`, unmigriert und in
  /// dieser Runde tabu). Mit `ink`/`accent` wäre die Marke im Hellmodus
  /// nahezu schwarz auf nahezu schwarz — also unsichtbar. `onForest` und
  /// `lime` sind in beiden Paletten hell und kontrast-gesichert; das ist
  /// dieselbe Begründung, aus der `welcome_screen.dart` dem Anzeige-Modus
  /// bewusst nicht folgt (DESIGN_REFACTOR §2, Nachtrag).
  ///
  /// Wer die Marke auf eine helle Karte setzt, übergibt beide Farben selbst.
  final Color? textColor;
  final Color? ringColor;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final style = AppType.display(
      fontSize,
      weight: FontWeight.w800,
      letterSpacing: fontSize * -0.02,
      height: 1.0,
      color: textColor ?? t.onForest,
    );
    // Ring etwas größer als die x-Höhe und leicht nach unten versetzt,
    // damit er optisch auf der Mittellinie der Kleinbuchstaben sitzt.
    final ringBox = fontSize * 0.82;
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text('eat', style: style),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: fontSize * 0.05),
          child: Transform.translate(
            offset: Offset(0, fontSize * 0.09),
            child: CustomPaint(
              size: Size.square(ringBox),
              painter: _FocusRingPainter(ringColor ?? t.lime),
            ),
          ),
        ),
        Text('va', style: style),
      ],
    );
  }
}

class _FocusRingPainter extends CustomPainter {
  const _FocusRingPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final w = size.width;
    final stroke = w * 0.105;
    final tick = w * 0.115;
    final gap = w * 0.075;
    // Ticks enden am Rand der Box; daraus ergibt sich der Ring-Radius.
    final ringRadius = w / 2 - tick - gap - stroke / 2;

    canvas.drawCircle(
      c,
      ringRadius,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke,
    );
    canvas.drawCircle(c, w * 0.10, Paint()..color = color);

    final tickPaint = Paint()
      ..color = color
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.butt;
    final inner = ringRadius + stroke / 2 + gap;
    final outer = inner + tick;
    for (final d in const [Offset(0, -1), Offset(1, 0), Offset(0, 1), Offset(-1, 0)]) {
      canvas.drawLine(c + d * inner, c + d * outer, tickPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _FocusRingPainter oldDelegate) =>
      oldDelegate.color != color;
}
