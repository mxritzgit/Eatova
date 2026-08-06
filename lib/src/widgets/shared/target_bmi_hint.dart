import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';

// ---------------------------------------------------------------------------
// Sanfter BMI-Hinweis zum Zielgewicht.
//
// Zeigt beim Setzen des Wunschgewichts (Onboarding-Zielschritt und
// Settings-Sheet) einen dezenten, NICHT blockierenden Hinweis, wenn das Ziel
// rechnerisch deutlich außerhalb des als gesund geltenden BMI-Bereichs läge
// (unter 18,5 bzw. über 35). Bewusst zurückhaltend formuliert und gestaltet:
// kein Rot, kein Blocken, keine Wertung — der User behält die volle Kontrolle.
// ---------------------------------------------------------------------------

/// Unterhalb dieses BMI gilt ein Zielgewicht als untergewichtig (WHO: 18,5).
const double kBmiUnderweightThreshold = 18.5;

/// Oberhalb dieses BMI weisen wir mild nach oben hin (Adipositas Grad II+).
const double kBmiUpperHintThreshold = 35.0;

/// BMI (kg/m²) für ein Zielgewicht — pure Funktion, damit testbar.
/// Liefert null bei unplausibler Größe (<= 0), statt zu dividieren/crashen.
double? targetBmi({required int heightCm, required int targetWeightKg}) {
  if (heightCm <= 0 || targetWeightKg <= 0) return null;
  final meters = heightCm / 100.0;
  return targetWeightKg / (meters * meters);
}

/// Hinweistext zum Ziel-BMI oder null, wenn kein Hinweis angebracht ist.
///
/// Grenzfälle: exakt 18,5 und exakt 35,0 lösen KEINEN Hinweis aus — nur
/// Werte strikt darunter bzw. strikt darüber.
String? targetBmiHintText({required int heightCm, required int targetWeightKg}) {
  final bmi = targetBmi(heightCm: heightCm, targetWeightKg: targetWeightKg);
  if (bmi == null) return null;
  final formatted = bmi.toStringAsFixed(1).replaceAll('.', ',');
  if (bmi < kBmiUnderweightThreshold) {
    return 'Dieses Zielgewicht entspräche einem BMI von $formatted — das '
        'liegt unterhalb des als gesund geltenden Bereichs.';
  }
  if (bmi > kBmiUpperHintThreshold) {
    return 'Dieses Zielgewicht entspräche einem BMI von $formatted — das '
        'liegt oberhalb des als gesund geltenden Bereichs.';
  }
  return null;
}

/// Dezente Soft-Kapsel mit dem BMI-Hinweis. Rendert nichts (und belegt keinen
/// Platz), solange das Zielgewicht im unauffälligen Bereich liegt.
class TargetBmiHint extends StatelessWidget {
  const TargetBmiHint({
    super.key,
    required this.heightCm,
    required this.targetWeightKg,
    this.margin = EdgeInsets.zero,
  });

  final int heightCm;
  final int targetWeightKg;

  /// Außenabstand, der nur anfällt, wenn der Hinweis sichtbar ist — so
  /// entsteht im versteckten Zustand keine doppelte Lücke im Layout.
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) {
    final text = targetBmiHintText(
      heightCm: heightCm,
      targetWeightKg: targetWeightKg,
    );
    if (text == null) return const SizedBox.shrink();

    return Container(
      key: const ValueKey('target-bmi-hint'),
      width: double.infinity,
      margin: margin,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: surfaceSoft,
        borderRadius: BorderRadius.circular(rControl),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline_rounded, size: 15, color: textMuted),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                color: textMuted,
                fontSize: 12,
                height: 1.4,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
