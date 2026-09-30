part of 'recipes_screen.dart';

// ---------------------------------------------------------------------------
// Open-stroke glyphs of the Recipes tab redesign (2026-09-28), drawn from the
// design's 24-unit SVG paths so line weight and caps match the template.
// Decorative: the controls around them carry the semantics.
// ---------------------------------------------------------------------------

enum _RecipeGlyph {
  calendar,
  plus,
  search,
  sliders,
  bookmark,
  check,
  download,
  pencil,
  bowl,
  fish,
  leaf,
}

class _GlyphIcon extends StatelessWidget {
  const _GlyphIcon(
    this.glyph, {
    this.size = 20,
    this.strokeWidth = 2,
    this.color,
    this.filled = false,
  });

  final _RecipeGlyph glyph;
  final double size;

  /// Stroke width in the 24-unit design space (the SVG `stroke-width`).
  final double strokeWidth;

  /// Defaults to the ambient [IconTheme] color.
  final Color? color;

  /// Fills closed outlines (the saved bookmark).
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final ink = color ?? IconTheme.of(context).color ?? context.t.ink;
    return ExcludeSemantics(
      child: CustomPaint(
        size: Size.square(size),
        painter: _GlyphPainter(glyph, ink, strokeWidth, filled),
      ),
    );
  }
}

class _GlyphPainter extends CustomPainter {
  const _GlyphPainter(this.glyph, this.ink, this.strokeWidth, this.filled);

  final _RecipeGlyph glyph;
  final Color ink;
  final double strokeWidth;
  final bool filled;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.shortestSide / 24;
    canvas
      ..save()
      ..scale(scale);
    final stroke = Paint()
      ..color = ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    void line(double x1, double y1, double x2, double y2) =>
        canvas.drawLine(Offset(x1, y1), Offset(x2, y2), stroke);
    switch (glyph) {
      case _RecipeGlyph.calendar:
        canvas.drawRRect(
          RRect.fromLTRBR(4, 5.5, 20, 20, const Radius.circular(3)),
          stroke,
        );
        line(4, 10, 20, 10);
        line(8.5, 3.5, 8.5, 7.5);
        line(15.5, 3.5, 15.5, 7.5);
        line(8, 14, 10, 14);
        line(14, 14, 16, 14);
        line(8, 17, 10, 17);
      case _RecipeGlyph.plus:
        line(12, 5, 12, 19);
        line(5, 12, 19, 12);
      case _RecipeGlyph.search:
        canvas.drawCircle(const Offset(11, 11), 6.5, stroke);
        line(20, 20, 15.8, 15.8);
      case _RecipeGlyph.sliders:
        line(4, 7, 13, 7);
        line(17, 7, 20, 7);
        line(4, 17, 7, 17);
        line(11, 17, 20, 17);
        canvas
          ..drawCircle(const Offset(15, 7), 2, stroke)
          ..drawCircle(const Offset(9, 17), 2, stroke);
      case _RecipeGlyph.bookmark:
        final path = Path()
          ..moveTo(7, 4.5)
          ..lineTo(17, 4.5)
          ..lineTo(17, 19.5)
          ..lineTo(12, 16)
          ..lineTo(7, 19.5)
          ..close();
        if (filled) canvas.drawPath(path, Paint()..color = ink);
        canvas.drawPath(path, stroke);
      case _RecipeGlyph.check:
        canvas.drawPath(
          Path()
            ..moveTo(5.5, 12.5)
            ..lineTo(9.5, 16.5)
            ..lineTo(18.5, 7.5),
          stroke,
        );
      case _RecipeGlyph.download:
        line(12, 4, 12, 15);
        canvas.drawPath(
          Path()
            ..moveTo(7.5, 10.5)
            ..lineTo(12, 15)
            ..lineTo(16.5, 10.5),
          stroke,
        );
        line(5, 19.5, 19, 19.5);
      case _RecipeGlyph.pencil:
        canvas.drawPath(
          Path()
            ..moveTo(4, 20)
            ..lineTo(5, 16)
            ..lineTo(16.5, 4.5)
            ..arcToPoint(
              const Offset(19.5, 7.5),
              radius: const Radius.circular(2.1),
            )
            ..lineTo(8, 19)
            ..close(),
          stroke,
        );
      case _RecipeGlyph.bowl:
        canvas
          ..drawPath(
            Path()
              ..moveTo(3.5, 11.5)
              ..lineTo(20.5, 11.5)
              ..arcToPoint(
                const Offset(3.5, 11.5),
                radius: const Radius.circular(8.5),
              )
              ..close(),
            stroke,
          )
          ..drawPath(
            Path()
              ..moveTo(8.5, 8)
              ..cubicTo(8.5, 6.7, 9.5, 6.3, 9.5, 4.8)
              ..moveTo(12.5, 8)
              ..cubicTo(12.5, 6.7, 13.5, 6.3, 13.5, 4.8),
            stroke,
          );
      case _RecipeGlyph.fish:
        canvas
          ..drawPath(
            Path()
              ..moveTo(20.5, 12)
              ..cubicTo(18.5, 15, 15.7, 16.5, 12.5, 16.5)
              ..cubicTo(9.3, 16.5, 6.8, 15, 5, 12)
              ..cubicTo(6.8, 9, 9.3, 7.5, 12.5, 7.5)
              ..cubicTo(15.7, 7.5, 18.5, 9, 20.5, 12)
              ..close(),
            stroke,
          )
          ..drawPath(
            Path()
              ..moveTo(5, 12)
              ..lineTo(2.5, 9)
              ..lineTo(2.5, 15)
              ..close(),
            stroke,
          )
          ..drawCircle(const Offset(16, 11.2), 0.6, stroke);
      case _RecipeGlyph.leaf:
        canvas.drawPath(
          Path()
            ..moveTo(5, 19)
            ..cubicTo(5, 11, 10, 6, 19, 5)
            ..cubicTo(19, 14, 14, 19, 6, 19)
            ..moveTo(5, 19)
            ..lineTo(12, 12),
          stroke,
        );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_GlyphPainter oldDelegate) =>
      glyph != oldDelegate.glyph ||
      ink != oldDelegate.ink ||
      strokeWidth != oldDelegate.strokeWidth ||
      filled != oldDelegate.filled;
}
