import 'package:flutter/material.dart';

import '../../theme/app_tokens.dart';

/// Eatova wordmark: "eat" + camera focus ring as the "o" + "va".
///
/// The ring (circle, centre dot, four ticks at 12/3/6/9) is the brand's scan
/// motif, drawn with CustomPaint rather than an image asset so it stays sharp
/// at any size and pixel density.
class EatovaWordmark extends StatelessWidget {
  const EatovaWordmark({
    super.key,
    this.fontSize = 24,
    this.textColor,
    this.ringColor,
  });

  final double fontSize;

  /// Defaults to the brand surface pair from [AppTokens]: `onForest` for the
  /// text, `lime` for the ring — meant for `forest` surfaces in both modes.
  /// The only current site, the auth screen, sits on the mode ground and
  /// passes `ink`/`accent` itself (`onForest` would vanish on the light
  /// ground). The welcome screen paints its own mark with a CustomPainter.
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
    // Slightly larger than the x-height and nudged down so it sits optically
    // on the lowercase midline.
    final ringBox = fontSize * 0.82;
    // One spoken label: without it a screen reader reads "eat va".
    return Semantics(
      label: 'Eatova',
      excludeSemantics: true,
      child: Row(
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
      ),
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
    // Ticks end at the box edge, which fixes the ring radius.
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
