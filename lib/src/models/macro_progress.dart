import 'meal_analysis_result.dart';

class MacroProgress {
  const MacroProgress({
    required this.proteinG,
    required this.carbsG,
    required this.fatG,
    required this.kcal,
    this.proteinMissing = 0,
    this.carbsMissing = 0,
    this.fatMissing = 0,
    this.entriesMissingMacros = 0,
  });

  final double proteinG;
  final double carbsG;
  final double fatG;
  final int kcal;

  /// Entries whose protein, carbs or fat is unknown ("-"). They add 0 g, so
  /// a sum with any of them is a lower bound, not the amount eaten.
  final int proteinMissing;
  final int carbsMissing;
  final int fatMissing;

  /// Entries with at least one unknown macro, for "2 entries without full
  /// macros".
  final int entriesMissingMacros;

  MacroProgress add(MealAnalysisResult result) {
    final protein = _parseMacroG(result.protein);
    final carbs = _parseMacroG(result.carbs);
    final fat = _parseMacroG(result.fat);
    // Macros carry energy: an entry without any holds none of them, so an
    // unknown macro there is 0 g, not a gap.
    final counts = result.caloriesKcal > 0;
    final proteinUnknown = counts && protein == null;
    final carbsUnknown = counts && carbs == null;
    final fatUnknown = counts && fat == null;
    return MacroProgress(
      proteinG: proteinG + (protein ?? 0),
      carbsG: carbsG + (carbs ?? 0),
      fatG: fatG + (fat ?? 0),
      kcal: kcal + result.caloriesKcal,
      proteinMissing: proteinMissing + (proteinUnknown ? 1 : 0),
      carbsMissing: carbsMissing + (carbsUnknown ? 1 : 0),
      fatMissing: fatMissing + (fatUnknown ? 1 : 0),
      entriesMissingMacros:
          entriesMissingMacros +
          (proteinUnknown || carbsUnknown || fatUnknown ? 1 : 0),
    );
  }

  static const empty = MacroProgress(proteinG: 0, carbsG: 0, fatG: 0, kcal: 0);

  /// Grams in a stored macro text ("12,5 g"); null when it states none ("-").
  static double? _parseMacroG(String value) {
    final match = RegExp(r'(\d+(?:[.,]\d+)?)').firstMatch(value);
    if (match == null) {
      return null;
    }
    return double.tryParse(match.group(1)!.replaceAll(',', '.'));
  }
}
