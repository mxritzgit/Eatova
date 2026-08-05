import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';

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
    this.textColor = textPrimary,
    this.ringColor = lime,
  });

  final double fontSize;
  final Color textColor;
  final Color ringColor;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontSize: fontSize,
      fontWeight: FontWeight.w800,
      letterSpacing: fontSize * -0.02,
      height: 1.0,
      color: textColor,
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
              painter: _FocusRingPainter(ringColor),
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
