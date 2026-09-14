import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/app_symbol.dart';

export '../../theme/app_symbol.dart';

/// Original 24-unit pictograms with rounded ink strokes and quiet inset fills.
/// Inherits IconTheme, including disabled opacity. Decorative by default.
class AppIcon extends StatelessWidget {
  const AppIcon(
    this.symbol, {
    super.key,
    this.size,
    this.color,
    this.selected = false,
    this.semanticLabel,
  });

  final AppSymbol symbol;
  final double? size;
  final Color? color;
  final bool selected;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final theme = IconTheme.of(context);
    final ink = color ?? theme.color ?? Theme.of(context).colorScheme.onSurface;
    final dimension = size ?? theme.size ?? 24;
    final glyph = ExcludeSemantics(
      child: SizedBox.square(
        dimension: dimension,
        child: Center(
          child: CustomPaint(
            size: Size.square(dimension),
            painter: _AppIconPainter(
              symbol,
              ink.withValues(alpha: ink.a * (theme.opacity ?? 1)),
              selected,
            ),
          ),
        ),
      ),
    );
    return semanticLabel == null
        ? glyph
        : Semantics(label: semanticLabel, image: true, child: glyph);
  }
}

class _AppIconPainter extends CustomPainter {
  const _AppIconPainter(this.symbol, this.ink, this.selected);
  final AppSymbol symbol;
  final Color ink;
  final bool selected;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = math.min(size.width, size.height) / 24;
    canvas.save();
    canvas.translate(
      (size.width - scale * 24) / 2,
      (size.height - scale * 24) / 2,
    );
    canvas.scale(scale);
    final drawing = _SymbolDrawing(canvas, ink, selected);
    switch (symbol) {
      case AppSymbol.today:
        drawing.today();
      case AppSymbol.food:
        drawing.food();
      case AppSymbol.recipes:
        drawing.recipes();
      case AppSymbol.training:
        drawing.training();
      case AppSymbol.coach:
        drawing.coach();
      case AppSymbol.breakfast:
        drawing.breakfast();
      case AppSymbol.lunch:
        drawing.lunch();
      case AppSymbol.dinner:
        drawing.dinner();
      case AppSymbol.snack:
        drawing.snack();
      case AppSymbol.protein:
        drawing.protein();
      case AppSymbol.carbs:
        drawing.carbs();
      case AppSymbol.fat:
        drawing.fat();
      case AppSymbol.energy:
        drawing.energy();
      case AppSymbol.steps:
        drawing.steps();
      case AppSymbol.settings:
        drawing.settings();
      case AppSymbol.addMeal:
        drawing.addMeal();
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_AppIconPainter oldDelegate) =>
      symbol != oldDelegate.symbol ||
      ink != oldDelegate.ink ||
      selected != oldDelegate.selected;
}

/// All contours live here, so optical weight is shared at 18-28 px.
class _SymbolDrawing {
  _SymbolDrawing(this.canvas, Color ink, this.selected)
    : stroke = (Paint()
        ..color = ink
        ..style = PaintingStyle.stroke
        ..strokeWidth = selected ? 1.95 : 1.7
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round),
      fill = (Paint()..color = ink),
      tint = (Paint()
        ..color = ink.withValues(alpha: ink.a * (selected ? .22 : .08)));

  final Canvas canvas;
  final bool selected;
  final Paint stroke, fill, tint;

  void line(double x1, double y1, double x2, double y2) =>
      canvas.drawLine(Offset(x1, y1), Offset(x2, y2), stroke);
  void path(Path p) => canvas.drawPath(p, stroke);
  void shape(Path p, {bool solid = false}) {
    canvas.drawPath(p, solid ? fill : tint);
    if (!solid) path(p);
  }

  Path oval(double left, double top, double right, double bottom) =>
      Path()..addOval(Rect.fromLTRB(left, top, right, bottom));

  void today() {
    canvas.drawCircle(const Offset(11.5, 12.5), 5.5, tint);
    path(Path()..addArc(const Rect.fromLTWH(3, 4, 17, 17), -.55, 5.4));
    path(
      Path()
        ..moveTo(11.5, 7.5)
        ..lineTo(11.5, 12.5)
        ..lineTo(15.5, 14.5),
    );
    canvas.drawCircle(const Offset(19.5, 4.5), selected ? 2 : 1.5, fill);
  }

  void food() {
    shape(oval(7, 4.5, 22, 20));
    path(Path()..addArc(const Rect.fromLTWH(10.2, 7.7, 8.6, 9.1), -.9, 4.5));
    path(
      Path()
        ..moveTo(2, 3.5)
        ..lineTo(2, 8)
        ..quadraticBezierTo(2, 10, 4, 10)
        ..quadraticBezierTo(6, 10, 6, 8)
        ..lineTo(6, 3.5),
    );
    line(4, 3.5, 4, 20.5);
    if (selected) shape(oval(12.2, 9.8, 17.2, 14.8), solid: true);
  }

  void recipes() {
    shape(
      Path()
        ..moveTo(3, 5)
        ..quadraticBezierTo(7.5, 3.1, 12, 6)
        ..quadraticBezierTo(16.5, 3.1, 21, 5)
        ..lineTo(21, 19)
        ..quadraticBezierTo(16.5, 17.1, 12, 20)
        ..quadraticBezierTo(7.5, 17.1, 3, 19)
        ..close(),
    );
    line(12, 6, 12, 20);
    path(
      Path()
        ..moveTo(6, 8.7)
        ..quadraticBezierTo(7.6, 8.5, 9, 9.4),
    );
    path(
      Path()
        ..moveTo(6, 12)
        ..quadraticBezierTo(7.6, 11.8, 9, 12.7),
    );
    final tab = Path()
      ..moveTo(15.5, 4.6)
      ..lineTo(15.5, 12)
      ..lineTo(17.2, 10.7)
      ..lineTo(19, 12)
      ..lineTo(19, 4.5)
      ..close();
    shape(tab, solid: selected);
  }

  void training() {
    path(
      Path()
        ..moveTo(8, 8)
        ..lineTo(8, 5.5)
        ..quadraticBezierTo(8, 3, 10.5, 3)
        ..lineTo(13.5, 3)
        ..quadraticBezierTo(16, 3, 16, 5.5)
        ..lineTo(16, 8),
    );
    shape(
      Path()
        ..moveTo(8, 8)
        ..lineTo(16, 8)
        ..cubicTo(18, 10, 20.3, 13.5, 20, 16.5)
        ..quadraticBezierTo(19.7, 21, 16, 21)
        ..lineTo(8, 21)
        ..quadraticBezierTo(4.3, 21, 4, 16.5)
        ..cubicTo(3.7, 13.5, 6, 10, 8, 8)
        ..close(),
    );
    path(
      Path()
        ..moveTo(8.5, 12)
        ..quadraticBezierTo(6.8, 14, 7.2, 16),
    );
    if (selected) line(10, 17.5, 15.5, 17.5);
  }

  void coach() {
    path(
      Path()
        ..moveTo(9, 5.5)
        ..quadraticBezierTo(9.5, 3, 12, 3)
        ..lineTo(18, 3)
        ..quadraticBezierTo(21, 3, 21, 6)
        ..lineTo(21, 11)
        ..quadraticBezierTo(21, 13, 19.5, 13.5),
    );
    shape(
      Path()
        ..moveTo(6, 7)
        ..lineTo(14.5, 7)
        ..quadraticBezierTo(17.5, 7, 17.5, 10)
        ..lineTo(17.5, 16)
        ..quadraticBezierTo(17.5, 19, 14.5, 19)
        ..lineTo(9, 19)
        ..lineTo(5, 21)
        ..lineTo(5, 18.8)
        ..quadraticBezierTo(2.5, 18.3, 2.5, 16)
        ..lineTo(2.5, 10)
        ..quadraticBezierTo(2.5, 7, 6, 7)
        ..close(),
    );
    line(6.5, 11.4, 13.5, 11.4);
    line(6.5, 14.8, selected ? 12 : 10.5, 14.8);
  }

  void breakfast() {
    shape(
      Path()
        ..moveTo(3.5, 16.5)
        ..cubicTo(2.6, 13, 3.7, 8.5, 7.4, 7)
        ..cubicTo(8.4, 4.8, 15.6, 4.8, 16.6, 7)
        ..cubicTo(20.3, 8.5, 21.4, 13, 20.5, 16.5)
        ..lineTo(17.2, 18.5)
        ..cubicTo(16.8, 13.5, 15.2, 11.5, 12, 11.5)
        ..cubicTo(8.8, 11.5, 7.2, 13.5, 6.8, 18.5)
        ..close(),
    );
    path(
      Path()
        ..moveTo(8.2, 6.2)
        ..quadraticBezierTo(8, 9.3, 9, 12.2),
    );
    path(
      Path()
        ..moveTo(15.8, 6.2)
        ..quadraticBezierTo(16, 9.3, 15, 12.2),
    );
    line(4.1, 10.5, 7.3, 13.5);
    line(19.9, 10.5, 16.7, 13.5);
  }

  void bowl() {
    shape(
      Path()
        ..moveTo(3.2, 11)
        ..lineTo(20.8, 11)
        ..quadraticBezierTo(19.8, 19, 12, 20)
        ..quadraticBezierTo(4.2, 19, 3.2, 11)
        ..close(),
    );
    line(8.5, 21, 15.5, 21);
  }

  void lunch() {
    line(12, 2.5, 8, 8.5);
    line(16.5, 3.5, 12, 9);
    path(
      Path()
        ..moveTo(6, 11)
        ..quadraticBezierTo(6.8, 7, 9.5, 8.3)
        ..quadraticBezierTo(13, 5.5, 15, 8.3)
        ..quadraticBezierTo(17.2, 7.6, 18.2, 11),
    );
    bowl();
  }

  void dinner() {
    shape(
      Path()
        ..moveTo(3, 15)
        ..quadraticBezierTo(12, 11.6, 21, 15)
        ..quadraticBezierTo(18.5, 20, 12, 20)
        ..quadraticBezierTo(5.5, 20, 3, 15)
        ..close(),
    );
    path(
      Path()
        ..moveTo(3, 15)
        ..quadraticBezierTo(12, 17.3, 21, 15),
    );
    shape(
      Path()
        ..moveTo(17, 2.8)
        ..cubicTo(12, 2.5, 11, 8.4, 15, 10)
        ..quadraticBezierTo(18.8, 11.5, 20.7, 7.3)
        ..cubicTo(16.2, 9.1, 14.4, 5.6, 17, 2.8)
        ..close(),
    );
    path(
      Path()
        ..moveTo(3.5, 4)
        ..lineTo(3.5, 7)
        ..quadraticBezierTo(3.5, 9, 5.5, 9)
        ..quadraticBezierTo(7.5, 9, 7.5, 7)
        ..lineTo(7.5, 4),
    );
    line(5.5, 4, 5.5, 11);
  }

  void snack() {
    shape(
      Path()
        ..moveTo(9, 3)
        ..cubicTo(3.8, 6, 2.8, 12.4, 5, 17)
        ..cubicTo(10.9, 17.7, 14, 9.4, 9, 3)
        ..close(),
    );
    path(
      Path()
        ..moveTo(6.1, 13.5)
        ..quadraticBezierTo(6.7, 9.5, 8.5, 6.7),
    );
    shape(
      Path()
        ..moveTo(16, 9)
        ..cubicTo(12.6, 10.7, 11.6, 15.6, 13.5, 20.5)
        ..cubicTo(19.7, 21.5, 23, 16.1, 16, 9)
        ..close(),
    );
    path(
      Path()
        ..moveTo(16, 12.5)
        ..quadraticBezierTo(18, 15.5, 16.8, 18),
    );
  }

  void protein() {
    shape(
      Path()
        ..moveTo(12, 3)
        ..cubicTo(8.3, 3, 4.5, 9.5, 4.5, 14)
        ..cubicTo(4.5, 23.1, 19.5, 23.1, 19.5, 14)
        ..cubicTo(19.5, 9.5, 15.7, 3, 12, 3)
        ..close(),
    );
    shape(oval(8.1, 11, 15.9, 18.6));
    path(
      Path()
        ..moveTo(8, 8.6)
        ..quadraticBezierTo(8.7, 6.9, 10, 6.1),
    );
  }

  void carbs() {
    line(6, 21, 17, 3);
    for (final (x, y) in [(8.6, 16.5), (11.4, 12.0), (14.2, 7.5)]) {
      shape(
        Path()
          ..moveTo(x, y)
          ..quadraticBezierTo(x - 5.2, y + .1, x - 4.1, y - 4.4)
          ..quadraticBezierTo(x - .2, y - 4.1, x, y)
          ..close(),
      );
      shape(
        Path()
          ..moveTo(x, y)
          ..quadraticBezierTo(x + .2, y + 4.3, x + 4.4, y + 3.5)
          ..quadraticBezierTo(x + 4.1, y - .2, x, y)
          ..close(),
      );
    }
  }

  void fat() {
    shape(
      Path()
        ..moveTo(11.5, 7)
        ..quadraticBezierTo(13.8, 1.9, 21, 3)
        ..quadraticBezierTo(19.8, 9.3, 11.5, 7)
        ..close(),
    );
    line(9, 11, 16.5, 5.2);
    shape(oval(3.5, 10, 12.5, 21));
    path(
      Path()
        ..moveTo(6.5, 14)
        ..quadraticBezierTo(5.5, 16, 6.4, 17.5),
    );
    shape(oval(14, 10, 21, 18.5));
    line(17.2, 10, 15, 7.5);
  }

  void energy() {
    shape(
      Path()
        ..moveTo(12, 2.5)
        ..quadraticBezierTo(15.1, 7, 14, 10)
        ..quadraticBezierTo(17, 9, 17.3, 6.7)
        ..cubicTo(23, 13, 20.6, 21, 12, 21)
        ..cubicTo(3.1, 21, 2.8, 14, 6, 9.4)
        ..lineTo(7.5, 12)
        ..quadraticBezierTo(11.5, 8.3, 12, 2.5)
        ..close(),
    );
    path(
      Path()
        ..moveTo(10, 17.4)
        ..quadraticBezierTo(9.3, 14.6, 12, 12.8)
        ..quadraticBezierTo(12, 16, 14, 17.4),
    );
  }

  void steps() {
    void shoe() {
      shape(
        Path()
          ..moveTo(4.2, 13.6)
          ..cubicTo(2.9, 10.7, 3.4, 6.2, 5.6, 6)
          ..cubicTo(8.1, 5.7, 9.9, 9.6, 9, 12.5)
          ..lineTo(8.4, 14.8)
          ..close(),
      );
      shape(
        Path()
          ..moveTo(4.7, 17)
          ..lineTo(8, 18)
          ..lineTo(7.5, 20)
          ..quadraticBezierTo(7, 21.6, 5.4, 21)
          ..quadraticBezierTo(3.8, 20.5, 4.2, 19)
          ..close(),
      );
      line(5.6, 9.5, 6.5, 11.2);
    }

    shoe();
    canvas.save();
    canvas.translate(24, -3.5);
    canvas.scale(-1, 1);
    shoe();
    canvas.restore();
  }

  void settings() {
    line(3, 7, 6, 7);
    line(12, 7, 21, 7);
    line(3, 17, 12, 17);
    line(18, 17, 21, 17);
    shape(oval(6, 4, 12, 10));
    shape(oval(12, 14, 18, 20));
  }

  void addMeal() {
    bowl();
    path(
      Path()
        ..moveTo(5, 8)
        ..quadraticBezierTo(6.5, 4.7, 10, 5.5),
    );
    line(18, 2.5, 18, 8.5);
    line(15, 5.5, 21, 5.5);
  }
}
