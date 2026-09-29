import 'package:flutter/material.dart';

import '../../models/logged_meal.dart';
import '../../theme/app_tokens.dart';
import '../../theme/meal_slot_style.dart';

/// The dark redesign's meal-slot mark: a rounded tile in the slot's tint with
/// its glyph (sunrise, bowl, moon, apple) in the slot's ink.
///
/// Shared by the Food diary and the Today meal rows. Decorative: the slot
/// name always stands next to it, so the tile adds no semantics.
class SlotIconTile extends StatelessWidget {
  const SlotIconTile({super.key, required this.slot, this.size = 44});

  final MealSlot slot;

  /// Edge length; the design's tile is 44 with a 22 px glyph.
  final double size;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: slot.tileTint(t),
          borderRadius: BorderRadius.circular(rControl * size / 44),
        ),
        child: CustomPaint(
          size: Size.square(size / 2),
          painter: _SlotGlyphPainter(slot, slot.tileInk(t)),
        ),
      ),
    );
  }
}

/// The design's 24-unit slot SVGs, stroke 1.9 with round caps and joins.
class _SlotGlyphPainter extends CustomPainter {
  const _SlotGlyphPainter(this.slot, this.ink);

  final MealSlot slot;
  final Color ink;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 24, size.height / 24);
    final pen = Paint()
      ..color = ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.9
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(switch (slot) {
      MealSlot.breakfast => _sunrise(),
      MealSlot.lunch => _bowl(),
      MealSlot.dinner => _moon(),
      MealSlot.snack => _apple(),
    }, pen);
    canvas.restore();
  }

  static Path _sunrise() => Path()
    ..moveTo(3.5, 18)
    ..lineTo(20.5, 18)
    ..moveTo(7, 18)
    ..arcToPoint(const Offset(17, 18), radius: const Radius.circular(5))
    ..moveTo(12, 8.5)
    ..lineTo(12, 5.5)
    ..moveTo(5.6, 11.6)
    ..lineTo(4, 10)
    ..moveTo(18.4, 11.6)
    ..lineTo(20, 10);

  static Path _bowl() => Path()
    ..moveTo(3.5, 11.5)
    ..lineTo(20.5, 11.5)
    ..arcToPoint(const Offset(3.5, 11.5), radius: const Radius.circular(8.5))
    ..close()
    ..moveTo(8.5, 8)
    ..cubicTo(8.5, 6.7, 9.5, 6.3, 9.5, 4.8)
    ..moveTo(12.5, 8)
    ..cubicTo(12.5, 6.7, 13.5, 6.3, 13.5, 4.8);

  static Path _moon() => Path()
    ..moveTo(19, 14.5)
    ..arcToPoint(const Offset(9.5, 5), radius: const Radius.circular(7.5))
    ..arcToPoint(
      const Offset(19, 14.5),
      radius: const Radius.circular(7.5),
      largeArc: true,
      clockwise: false,
    )
    ..close();

  static Path _apple() => Path()
    ..moveTo(12, 8)
    ..cubicTo(10.5, 7, 6.5, 6.5, 5.5, 10.5)
    ..cubicTo(4.6, 14.1, 7, 20, 10, 20)
    ..cubicTo(11, 20, 11.3, 19.5, 12, 19.5)
    ..cubicTo(12.7, 19.5, 13, 20, 14, 20)
    ..cubicTo(17, 20, 19.4, 14.1, 18.5, 10.5)
    ..cubicTo(17.5, 6.5, 13.5, 7, 12, 8)
    ..close()
    ..moveTo(12, 8)
    ..cubicTo(12, 6.2, 12.8, 4.8, 14.5, 4);

  @override
  bool shouldRepaint(_SlotGlyphPainter oldDelegate) =>
      slot != oldDelegate.slot || ink != oldDelegate.ink;
}
