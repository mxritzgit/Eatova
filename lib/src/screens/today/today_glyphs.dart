import 'package:flutter/material.dart';

/// The Today tab's line glyphs, drawn from the dark redesign's 24-unit SVG
/// paths (design/today/template.html, 2026-09-28), converted once to Path
/// calls with absolute coordinates. Decorative: the owning control carries
/// the label.
///
/// Today-only on purpose: the Food task owns the shared slot icons, so these
/// stay private to this tab until the tabs are merged.
enum TodayGlyph {
  flame,
  sunrise,
  bowl,
  moon,
  apple,
  pulse,
  dumbbell,
  plus,
  chevron,
}

class TodayGlyphIcon extends StatelessWidget {
  const TodayGlyphIcon(
    this.glyph, {
    super.key,
    required this.color,
    this.size = 22,
  });

  final TodayGlyph glyph;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: CustomPaint(
      size: Size.square(size),
      painter: _GlyphPainter(glyph, color),
    ),
  );
}

/// Stroke width per glyph as in the design's SVGs; null = filled (the flame).
double? _strokeOf(TodayGlyph glyph) => switch (glyph) {
  TodayGlyph.flame => null,
  TodayGlyph.sunrise ||
  TodayGlyph.bowl ||
  TodayGlyph.moon ||
  TodayGlyph.apple => 1.9,
  TodayGlyph.pulse || TodayGlyph.dumbbell || TodayGlyph.chevron => 2,
  TodayGlyph.plus => 2.4,
};

final Map<TodayGlyph, Path> _paths = {};

Path _pathOf(TodayGlyph glyph) => _paths.putIfAbsent(
  glyph,
  () => switch (glyph) {
    TodayGlyph.flame =>
      Path()
        ..moveTo(12, 21.5)
        ..cubicTo(16, 21.5, 18.8, 18.8, 18.8, 15)
        ..cubicTo(18.8, 11.5, 16.5, 9.2, 15.1, 7.2)
        ..cubicTo(14.6, 8.8, 13.7, 10, 12.6, 10.5)
        ..cubicTo(12.8, 7.6, 11.7, 4.8, 9.2, 2.8)
        ..cubicTo(9, 5.9, 7.5, 7.8, 6.1, 9.7)
        ..cubicTo(4.9, 11.3, 4.2, 12.8, 4.2, 15)
        ..cubicTo(4.2, 18.8, 7, 21.5, 12, 21.5)
        ..close(),
    TodayGlyph.sunrise =>
      Path()
        ..moveTo(3.5, 18)
        ..lineTo(20.5, 18)
        ..moveTo(7, 18)
        ..arcToPoint(const Offset(17, 18), radius: const Radius.circular(5))
        ..moveTo(12, 8.5)
        ..lineTo(12, 5.5)
        ..moveTo(5.6, 11.6)
        ..lineTo(4, 10)
        ..moveTo(18.4, 11.6)
        ..lineTo(20, 10),
    TodayGlyph.bowl =>
      Path()
        ..moveTo(3.5, 11.5)
        ..lineTo(20.5, 11.5)
        ..arcToPoint(
          const Offset(3.5, 11.5),
          radius: const Radius.circular(8.5),
        )
        ..close()
        ..moveTo(8.5, 8)
        ..cubicTo(8.5, 6.7, 9.5, 6.3, 9.5, 4.8)
        ..moveTo(12.5, 8)
        ..cubicTo(12.5, 6.7, 13.5, 6.3, 13.5, 4.8),
    TodayGlyph.moon =>
      Path()
        ..moveTo(19, 14.5)
        ..arcToPoint(const Offset(9.5, 5), radius: const Radius.circular(7.5))
        ..arcToPoint(
          const Offset(19, 14.5),
          radius: const Radius.circular(7.5),
          largeArc: true,
          clockwise: false,
        )
        ..close(),
    TodayGlyph.apple =>
      Path()
        ..moveTo(12, 8)
        ..cubicTo(10.5, 7, 6.5, 6.5, 5.5, 10.5)
        ..cubicTo(4.6, 14.1, 7, 20, 10, 20)
        ..cubicTo(11, 20, 11.3, 19.5, 12, 19.5)
        ..cubicTo(12.7, 19.5, 13, 20, 14, 20)
        ..cubicTo(17, 20, 19.4, 14.1, 18.5, 10.5)
        ..cubicTo(17.5, 6.5, 13.5, 7, 12, 8)
        ..close()
        ..moveTo(12, 8)
        ..cubicTo(12, 6.2, 12.8, 4.8, 14.5, 4),
    TodayGlyph.pulse =>
      Path()
        ..moveTo(3, 12)
        ..lineTo(7, 12)
        ..lineTo(9.5, 6)
        ..lineTo(14.5, 18)
        ..lineTo(17, 12)
        ..lineTo(21, 12),
    TodayGlyph.dumbbell =>
      Path()
        ..moveTo(7, 7)
        ..lineTo(7, 17)
        ..moveTo(17, 7)
        ..lineTo(17, 17)
        ..moveTo(4, 9.5)
        ..lineTo(4, 14.5)
        ..moveTo(20, 9.5)
        ..lineTo(20, 14.5)
        ..moveTo(7, 12)
        ..lineTo(17, 12),
    TodayGlyph.plus =>
      Path()
        ..moveTo(12, 5)
        ..lineTo(12, 19)
        ..moveTo(5, 12)
        ..lineTo(19, 12),
    TodayGlyph.chevron =>
      Path()
        ..moveTo(9, 6)
        ..lineTo(15, 12)
        ..lineTo(9, 18),
  },
);

class _GlyphPainter extends CustomPainter {
  const _GlyphPainter(this.glyph, this.color);

  final TodayGlyph glyph;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = _strokeOf(glyph);
    canvas.save();
    canvas.scale(size.width / 24, size.height / 24);
    final paint = Paint()
      ..color = color
      ..isAntiAlias = true;
    if (stroke != null) {
      paint
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
    }
    canvas.drawPath(_pathOf(glyph), paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_GlyphPainter old) =>
      old.glyph != glyph || old.color != color;
}
