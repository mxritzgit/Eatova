import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../l10n/l10n.dart';
import '../design/design.dart';

// ---------------------------------------------------------------------------
// Soft BMI hint for the target weight: a non-blocking note when the target
// lands well outside the healthy range. No red, no blocking, no judgement.
// ---------------------------------------------------------------------------

/// Below this BMI a target weight counts as underweight (WHO: 18.5).
const double kBmiUnderweightThreshold = 18.5;

/// Above this BMI the upward hint fires (obesity class II+).
const double kBmiUpperHintThreshold = 35.0;

/// BMI (kg/m²) for a target weight; null for implausible input (<= 0).
double? targetBmi({required int heightCm, required int targetWeightKg}) {
  if (heightCm <= 0 || targetWeightKg <= 0) return null;
  final meters = heightCm / 100.0;
  return targetWeightKg / (meters * meters);
}

/// Hint text for the target BMI, or null when none is warranted. Exactly
/// 18.5 and 35.0 trigger nothing; only strictly below/above. [l10n] is
/// optional so tests can call this context-free.
String? targetBmiHintText({
  required int heightCm,
  required int targetWeightKg,
  AppLocalizations? l10n,
}) {
  final bmi = targetBmi(heightCm: heightCm, targetWeightKg: targetWeightKg);
  if (bmi == null) return null;
  final t = l10n ?? deL10n;
  // Locale-aware via NumberFormat: comma under `de`, dot under `en`.
  final formatted = NumberFormat('0.0', t.localeName).format(bmi);
  if (bmi < kBmiUnderweightThreshold) {
    return t.targetBmiHintUnderweight(formatted);
  }
  if (bmi > kBmiUpperHintThreshold) {
    return t.targetBmiHintOverweight(formatted);
  }
  return null;
}

/// Soft capsule holding the BMI hint; renders nothing and takes no space
/// while the target weight is unremarkable.
class TargetBmiHint extends StatelessWidget {
  const TargetBmiHint({
    super.key,
    required this.heightCm,
    required this.targetWeightKg,
    this.margin = EdgeInsets.zero,
  });

  final int heightCm;
  final int targetWeightKg;

  /// Applies only while the hint is visible, so the hidden state leaves no
  /// double gap.
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) {
    final text = targetBmiHintText(
      heightCm: heightCm,
      targetWeightKg: targetWeightKg,
      l10n: context.l10n,
    );
    if (text == null) return const SizedBox.shrink();

    // The app's quiet boxed note: a hint, not a warning.
    return Padding(
      key: const ValueKey('target-bmi-hint'),
      padding: margin,
      child: SignalNote(text, boxed: true),
    );
  }
}
