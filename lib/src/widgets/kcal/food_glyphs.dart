import 'package:flutter/material.dart';

/// The Food tab's control glyphs, drawn from the dark redesign's 24-unit
/// SVGs (stroke widths as in the design).
enum FoodGlyph {
  calendar,
  chevronLeft,
  chevronRight,
  plus,
  search,
  barcode,
  camera,
}

/// A decorative [FoodGlyph]; color and size default to the [IconTheme], so
/// it inherits a button's ink.
class FoodGlyphIcon extends StatelessWidget {
  const FoodGlyphIcon(this.glyph, {super.key, this.size, this.color});

  final FoodGlyph glyph;
  final double? size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = IconTheme.of(context);
    final ink = color ?? theme.color ?? Theme.of(context).colorScheme.onSurface;
    final dimension = size ?? theme.size ?? 24;
    return ExcludeSemantics(
      child: CustomPaint(
        size: Size.square(dimension),
        painter: _FoodGlyphPainter(
          glyph,
          ink.withValues(alpha: ink.a * (theme.opacity ?? 1)),
        ),
      ),
    );
  }
}

class _FoodGlyphPainter extends CustomPainter {
  const _FoodGlyphPainter(this.glyph, this.ink);

  final FoodGlyph glyph;
  final Color ink;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 24, size.height / 24);
    Paint pen(double width) => Paint()
      ..color = ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    switch (glyph) {
      case FoodGlyph.calendar:
        final p = pen(1.9);
        canvas.drawRRect(
          RRect.fromLTRBR(4, 5.5, 20, 20, const Radius.circular(3)),
          p,
        );
        canvas.drawPath(
          Path()
            ..moveTo(4, 10)
            ..lineTo(20, 10)
            ..moveTo(8.5, 3.5)
            ..lineTo(8.5, 7.5)
            ..moveTo(15.5, 3.5)
            ..lineTo(15.5, 7.5),
          p,
        );
      case FoodGlyph.chevronLeft:
        canvas.drawPath(
          Path()
            ..moveTo(15, 6)
            ..lineTo(9, 12)
            ..lineTo(15, 18),
          pen(2),
        );
      case FoodGlyph.chevronRight:
        canvas.drawPath(
          Path()
            ..moveTo(9, 6)
            ..lineTo(15, 12)
            ..lineTo(9, 18),
          pen(2),
        );
      case FoodGlyph.plus:
        canvas.drawPath(
          Path()
            ..moveTo(12, 5)
            ..lineTo(12, 19)
            ..moveTo(5, 12)
            ..lineTo(19, 12),
          pen(2.6),
        );
      case FoodGlyph.search:
        final p = pen(2);
        canvas.drawCircle(const Offset(11, 11), 6.5, p);
        canvas.drawLine(const Offset(20, 20), const Offset(15.8, 15.8), p);
      case FoodGlyph.barcode:
        const r = Radius.circular(1.5);
        canvas.drawPath(
          Path()
            ..moveTo(4, 7.5)
            ..lineTo(4, 5.5)
            ..arcToPoint(const Offset(5.5, 4), radius: r)
            ..lineTo(7.5, 4)
            ..moveTo(16.5, 4)
            ..lineTo(18.5, 4)
            ..arcToPoint(const Offset(20, 5.5), radius: r)
            ..lineTo(20, 7.5)
            ..moveTo(20, 16.5)
            ..lineTo(20, 18.5)
            ..arcToPoint(const Offset(18.5, 20), radius: r)
            ..lineTo(16.5, 20)
            ..moveTo(7.5, 20)
            ..lineTo(5.5, 20)
            ..arcToPoint(const Offset(4, 18.5), radius: r)
            ..lineTo(4, 16.5)
            ..moveTo(8, 8.5)
            ..lineTo(8, 15.5)
            ..moveTo(11, 8.5)
            ..lineTo(11, 15.5)
            ..moveTo(13.5, 8.5)
            ..lineTo(13.5, 15.5)
            ..moveTo(16, 8.5)
            ..lineTo(16, 15.5),
          pen(1.9),
        );
      case FoodGlyph.camera:
        final p = pen(2);
        const r = Radius.circular(2.5);
        canvas.drawPath(
          Path()
            ..moveTo(4, 8.5)
            ..arcToPoint(const Offset(6.5, 6), radius: r)
            ..lineTo(8.1, 6)
            ..lineTo(9.5, 4)
            ..lineTo(14.5, 4)
            ..lineTo(15.9, 6)
            ..lineTo(17.5, 6)
            ..arcToPoint(const Offset(20, 8.5), radius: r)
            ..lineTo(20, 16.5)
            ..arcToPoint(const Offset(17.5, 19), radius: r)
            ..lineTo(6.5, 19)
            ..arcToPoint(const Offset(4, 16.5), radius: r)
            ..close(),
          p,
        );
        canvas.drawCircle(const Offset(12, 12.5), 3.5, p);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_FoodGlyphPainter oldDelegate) =>
      glyph != oldDelegate.glyph || ink != oldDelegate.ink;
}
