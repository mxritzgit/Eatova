import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../l10n/l10n.dart';
import '../../theme/app_tokens.dart';

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
///
/// [l10n] ist optional (Default Deutsch, [deL10n]): `test/target_bmi_hint_test.dart`
/// ruft diese Funktion als Test-API weiterhin kontextfrei und pumpt feste
/// deutsche Erwartungstexte (DESIGN_REFACTOR §6) — der [TargetBmiHint]-Widget
/// reicht sein `context.l10n` durch.
String? targetBmiHintText({
  required int heightCm,
  required int targetWeightKg,
  AppLocalizations? l10n,
}) {
  final bmi = targetBmi(heightCm: heightCm, targetWeightKg: targetWeightKg);
  if (bmi == null) return null;
  final t = l10n ?? deL10n;
  // Seit Paket 7 (2026-08-11) locale-bewusst ueber NumberFormat — dasselbe
  // Muster wie `formatBmiDe` in `profile/profile_format.dart`: unter `de`
  // byte-gleich zum vorherigen `toStringAsFixed(1).replaceAll('.', ',')`
  // (CLDR liefert fuer `de` ebenfalls das Komma), unter `en` jetzt der Punkt.
  final formatted = NumberFormat('0.0', t.localeName).format(bmi);
  if (bmi < kBmiUnderweightThreshold) {
    return t.targetBmiHintUnderweight(formatted);
  }
  if (bmi > kBmiUpperHintThreshold) {
    return t.targetBmiHintOverweight(formatted);
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
      l10n: context.l10n,
    );
    if (text == null) return const SizedBox.shrink();

    final t = context.t;
    return Container(
      key: const ValueKey('target-bmi-hint'),
      width: double.infinity,
      margin: margin,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: t.surf2,
        borderRadius: BorderRadius.circular(rControl),
        border: Border.all(color: t.line),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline_rounded, size: 15, color: t.ink2),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              text,
              style: AppType.ui(
                12,
                weight: FontWeight.w500,
                color: t.ink2,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
