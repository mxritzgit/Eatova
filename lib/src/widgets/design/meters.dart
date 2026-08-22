import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../theme/app_tokens.dart';
import '../common/motion.dart';

// ---------------------------------------------------------------------------
// METERS — tick gauge, macro bar, meal avatar, sparkline, dot grid.
//
// All of them take values from the network or from user input, so handling 0,
// negatives, over-target, NaN and empty series without throwing is the job,
// not a convenience.
// ---------------------------------------------------------------------------

/// The calorie gauge: a row of ticks filling with lime.
class TickGauge extends StatelessWidget {
  const TickGauge({
    super.key,
    required this.progress,
    this.height = 28,
    this.fillColor,
    this.trackColor,
  });

  /// 0..1; out-of-range values and non-numbers are clamped.
  final double progress;

  final double height;

  /// Defaults to [AppTokens.lime] on a dimmed [AppTokens.onForest] track — the
  /// gauge sits on the forest hero card.
  final Color? fillColor;
  final Color? trackColor;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final safe = progress.isFinite ? progress.clamp(0.0, 1.0) : 0.0;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: safe),
      // DESIGN_REFACTOR §5: reduced motion snaps the bar to its value instead
      // of ramping it up over half a second.
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

/// One macro row: name, bar, "value / goal unit".
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

    // Both side columns grow with the system font, capped so the bar between
    // them does not vanish. Base 84 because the longest German macro name
    // needs ~80 px at AppType.ui(12) and wrapped to two lines even at scale
    // 1.0, leaving the three bars visibly misaligned.
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

/// The letter avatar in front of a meal.
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
      // FittedBox: the tile has a fixed edge length but the letter grows with
      // the system font and would escape the tile at 2.0.
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          letter,
          style: AppType.display(
            size * 0.38,
            weight: FontWeight.w700,
            // Not the full slot color: on its own 16 % tint it only reaches
            // 2.15:1 in light mode (carb amber).
            color: t.readableOnTint(color),
          ),
        ),
      ),
    );
  }
}

/// Axis-free polyline for trends (weight, kcal per week).
class Sparkline extends StatelessWidget {
  const Sparkline({
    super.key,
    required this.values,
    this.stroke,
    this.dotFill,
    this.height = 74,
  });

  /// Fewer than two points make no line — the area stays empty instead of
  /// throwing.
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

  // The store hands over a freshly built list, so an identity check would
  // repaint on every rebuild; compare elements instead.
  @override
  bool shouldRepaint(_SparklinePainter old) =>
      old.stroke != stroke ||
      old.dotFill != dotFill ||
      !listEquals(old.values, values);
}

/// The dot grid behind branded surfaces (hero cards, banners). Built for
/// `Positioned.fill`: it always takes the full area.
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
