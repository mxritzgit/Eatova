import 'package:flutter/material.dart';

/// Two staggered shoe prints, shared by step counts and step goals.
/// Decorative: the adjacent metric label supplies the accessible name.
class StepsIcon extends StatelessWidget {
  const StepsIcon({super.key, this.size, this.color});

  final double? size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = IconTheme.of(context);
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: size ?? theme.size ?? 24,
        child: CustomPaint(
          painter: _StepsPainter(
            color ?? theme.color ?? Theme.of(context).colorScheme.onSurface,
          ),
        ),
      ),
    );
  }
}

class _StepsPainter extends CustomPainter {
  const _StepsPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 24, size.height / 24);
    final paint = Paint()..color = color;
    final sole = Path()
      ..moveTo(4, 14)
      ..cubicTo(2.8, 11.5, 3.1, 7, 5.4, 6.5)
      ..cubicTo(8, 6, 10, 10, 9.3, 12.7)
      ..lineTo(8.7, 15.4)
      ..close();
    final heel = Path()
      ..moveTo(4.8, 16.5)
      ..lineTo(8.7, 17.6)
      ..lineTo(8.1, 19.7)
      ..cubicTo(7.5, 22, 3.5, 20.8, 4.1, 18.6)
      ..close();
    canvas.drawPath(sole, paint);
    canvas.drawPath(heel, paint);
    canvas.save();
    canvas.translate(24, -4);
    canvas.scale(-1, 1);
    canvas.drawPath(sole, paint);
    canvas.drawPath(heel, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_StepsPainter oldDelegate) => color != oldDelegate.color;
}
