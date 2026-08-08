import 'model_limits.dart';

class MealComponent {
  const MealComponent({
    required this.name,
    required this.grams,
    required this.caloriesKcal,
    this.kcalPer100G,
    this.proteinG,
    this.carbsG,
    this.fatG,
  });

  final String name;
  final int grams;
  final int caloriesKcal;
  final double? kcalPer100G;

  /// Makros dieses Bestandteils in Gramm — optional, weil weder das
  /// Scan-Modell noch der Bestandteil-Dialog sie heute liefern.
  /// `null` heisst ausdruecklich "unbekannt", nicht "0 g".
  final double? proteinG;
  final double? carbsG;
  final double? fatG;

  /// `true`, wenn dieser Posten eine vollstaendige Makro-Angabe traegt.
  /// Nur dann darf `MealAnalysisResult.adjustedToItems` die Makros der
  /// Mahlzeit aus den Posten aufsummieren.
  bool get hasMacros => proteinG != null && carbsG != null && fatG != null;

  String get gramsLabel => '$grams g';
  String get caloriesLabel => '$caloriesKcal kcal';

  /// kcal/100 g, sofern der Wert ueberhaupt brauchbar ist — sonst `null`.
  ///
  /// Drei Faelle gelten alle als "fehlt" (docs/REVIEW-2026-08-08.md, B1):
  ///
  /// * `null` — der Schluessel fehlt oder ist explizit `null`.
  /// * `<= 0` — der Server klemmte nicht parsebare Modellwerte auf die
  ///   Untergrenze `0`, und `-1` klemmt er weiterhin auf `0`. Ein `??` haette
  ///   hier nie gefeuert, weil `0.0` nicht `null` ist. Genau daran hingen die
  ///   0-kcal-Eintraege.
  /// * `> 900` — physikalisch unmoeglich (reines Fett), praktisch immer die
  ///   kJ-Zahl im kcal-Feld.
  double? get effectiveKcalPer100G {
    final wert = kcalPer100G;
    if (wert == null || !wert.isFinite || wert <= 0) {
      return null;
    }
    return isPlausibleKcalPer100G(wert) ? wert : null;
  }

  /// Rechnet diesen Posten auf [adjustedGrams] um.
  ///
  /// `caloriesKcal` ist autoritativ: es ist die Zahl, die der Nutzer auf der
  /// Karte gesehen und mit "Anpassen" bestaetigt hat. Die Dichte ist im
  /// Modellergebnis ein unabhaengig geklemmtes Nebenfeld und wird nur dann
  /// zur Bezugsgroesse, wenn sich aus Kalorien und Gramm nichts herleiten
  /// laesst. Dadurch gilt die Invariante: `adjustedToGrams(grams)` aendert
  /// die Kalorien nicht.
  MealComponent adjustedToGrams(int adjustedGrams) {
    final zielGramm = clampPortionGrams(adjustedGrams);
    final dichte = effectiveKcalPer100G;
    final int neueKcal;
    if (grams > 0 && caloriesKcal > 0) {
      neueKcal = clampMealCaloriesKcal(caloriesKcal * zielGramm / grams);
    } else if (dichte != null) {
      neueKcal = clampMealCaloriesKcal(dichte * zielGramm / 100);
    } else {
      neueKcal = 0;
    }
    final neueDichte = neueKcal > 0 ? neueKcal * 100 / zielGramm : dichte;
    final faktor = grams > 0 ? zielGramm / grams : 1.0;

    return MealComponent(
      name: name,
      grams: zielGramm,
      caloriesKcal: neueKcal,
      kcalPer100G: neueDichte == null ? null : clampKcalPer100G(neueDichte),
      proteinG: _skaliert(proteinG, faktor),
      carbsG: _skaliert(carbsG, faktor),
      fatG: _skaliert(fatG, faktor),
    );
  }

  factory MealComponent.fromJson(Map<String, dynamic> json) {
    final name =
        _firstNonEmptyString(json, const ['name', 'item', 'food', 'label']) ??
        'Zutat';
    final grams =
        _readInt(json, const [
          'grams',
          'estimatedGrams',
          'weightG',
          'quantityG',
          'portionGrams',
        ]) ??
        _extractFirstInt(json['grams']?.toString()) ??
        0;
    // Die Dichte wird geklemmt gelesen: 0 und die kJ-Zahl im kcal-Feld sind
    // beides "unbekannt", nicht "0 kcal/100 g".
    final rohDichte = _readDouble(json, const [
      'kcalPer100G',
      'caloriesPer100G',
      'caloriesPer100g',
      'kcalPer100g',
    ]);
    final kcalPer100 =
        rohDichte == null || !rohDichte.isFinite || rohDichte <= 0 || !isPlausibleKcalPer100G(rohDichte)
        ? null
        : rohDichte;
    final geklemmteGramm = clampMealEstimatedG(grams);
    final calories =
        _readInt(json, const ['caloriesKcal', 'kcal', 'calories']) ??
        (kcalPer100 != null && geklemmteGramm > 0
            ? (kcalPer100 * geklemmteGramm / 100).round()
            : 0);

    return MealComponent(
      name: name,
      grams: geklemmteGramm,
      caloriesKcal: clampMealCaloriesKcal(calories),
      kcalPer100G: kcalPer100,
      proteinG: _readMacroG(json, const ['proteinG', 'protein_g', 'protein']),
      carbsG: _readMacroG(json, const ['carbsG', 'carbs_g', 'carbs']),
      fatG: _readMacroG(json, const ['fatG', 'fat_g', 'fat']),
    );
  }

  static double? _skaliert(double? wert, double faktor) =>
      wert == null ? null : clampMealMacroG(wert * faktor);

  static double? _readMacroG(Map<String, dynamic> json, List<String> keys) {
    final wert = _readDouble(json, keys);
    if (wert == null || !wert.isFinite) {
      return null;
    }
    return clampMealMacroG(wert);
  }

  static int? _readInt(Map<String, dynamic> json, List<String> keys) {
    for (final key in keys) {
      final value = json[key];
      if (value is int) {
        return value;
      }
      if (value is double) {
        return value.round();
      }
      if (value is String) {
        final parsed = _extractFirstInt(value);
        if (parsed != null) {
          return parsed;
        }
      }
    }
    return null;
  }

  static double? _readDouble(Map<String, dynamic> json, List<String> keys) {
    for (final key in keys) {
      final value = json[key];
      if (value is num) {
        return value.toDouble();
      }
      if (value is String) {
        final normalized = value.replaceAll(',', '.');
        final match = RegExp(r'\d+(?:\.\d+)?').firstMatch(normalized);
        if (match != null) {
          return double.tryParse(match.group(0)!);
        }
      }
    }
    return null;
  }

  static String? _firstNonEmptyString(
    Map<String, dynamic> json,
    List<String> keys,
  ) {
    for (final key in keys) {
      final value = json[key]?.toString().trim();
      if (value != null && value.isNotEmpty) {
        return value;
      }
    }
    return null;
  }

  static int? _extractFirstInt(String? value) {
    if (value == null) {
      return null;
    }
    final match = RegExp(r'\d+').firstMatch(value);
    return match == null ? null : int.tryParse(match.group(0)!);
  }
}
