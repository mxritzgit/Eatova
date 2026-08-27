import 'package:flutter/widgets.dart';

// ---------------------------------------------------------------------------
// TEXT SCALE — width reservation instead of `FittedBox(scaleDown)`.
//
// A FittedBox around a label neutralises the system font size: a 10.5 px
// caption stays 10.5 px at 1.3x. Reserving width that grows with the scaler
// (capped, so the neighbour does not vanish) keeps the text honest and the
// row aligned. Pattern from [MacroBar].
// ---------------------------------------------------------------------------

/// [base] logical px grown with the system font, clamped to `[base, max]`.
/// [max] defaults to 1.5x [base].
double scaledWidth(BuildContext context, double base, {double? max}) {
  final scaler = MediaQuery.textScalerOf(context);
  return scaler.scale(base).clamp(base, max ?? base * 1.5);
}

/// A [SizedBox] whose width is [scaledWidth] of [base].
class ScaledWidth extends StatelessWidget {
  const ScaledWidth({
    super.key,
    required this.base,
    this.max,
    required this.child,
  });

  final double base;
  final double? max;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SizedBox(width: scaledWidth(context, base, max: max), child: child);
  }
}
