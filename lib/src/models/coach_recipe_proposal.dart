import 'dart:typed_data';

import 'fitness_recipe.dart';

/// Rezept-Vorschlag aus dem Coach (`mode: "recipe"` der coach-chat Function,
/// Spec 2026-08-12). Client-Sicht auf das Server-Wire-Format (snake_case);
/// lebt NUR in der laufenden Chat-Session — persistiert wird erst das
/// [FitnessRecipe], nachdem der Nutzer im Sheet bestaetigt hat.
///
/// Der Server klemmt alle Werte bereits (recipe.ts, RECIPE_LIMITS); hier
/// gibt es nur die billige Defensiv-Klemme gegen aeltere/kaputte
/// Function-Antworten — insbesondere `estimated_g >= 1`, weil
/// [FitnessRecipe.kcalPer100G] sonst durch 0 teilt.
class CoachRecipeProposal {
  const CoachRecipeProposal({
    required this.title,
    required this.description,
    required this.portion,
    required this.ingredients,
    required this.preparation,
    required this.caloriesKcal,
    required this.proteinG,
    required this.carbsG,
    required this.fatG,
    required this.estimatedGrams,
    this.imageBytes,
  });

  final String title;
  final String description;
  final String portion;

  /// "\n- "-Zeilenliste — dasselbe Freitext-Format wie im manuellen
  /// Rezept-Formular (fitness_recipe.dart).
  final String ingredients;

  /// "\n1. "-nummerierte Schritte.
  final String preparation;

  final int caloriesKcal;
  final int proteinG;
  final int carbsG;
  final int fatG;
  final int estimatedGrams;

  /// Das generierte Foto (JPEG). Nur im Speicher — in den Chat-Verlauf
  /// werden nie Bild-Bytes persistiert (Regel wie bei User-Fotos,
  /// chat_message.dart).
  final Uint8List? imageBytes;

  /// null = unbrauchbarer Vorschlag (kein Titel oder keine kcal) — der
  /// Aufrufer behandelt das wie eine leere Antwort.
  static CoachRecipeProposal? fromJson(
    Map<dynamic, dynamic> json, {
    Uint8List? imageBytes,
  }) {
    final title = json['title']?.toString().trim() ?? '';
    final kcal = _toInt(json['calories_kcal']);
    if (title.isEmpty || kcal == null) return null;
    return CoachRecipeProposal(
      title: title,
      description: json['description']?.toString().trim() ?? '',
      portion: json['portion']?.toString().trim() ?? '',
      ingredients: json['ingredients']?.toString().trim() ?? '',
      preparation: json['preparation']?.toString().trim() ?? '',
      caloriesKcal: kcal.clamp(1, 10000),
      proteinG: (_toInt(json['protein_g']) ?? 0).clamp(0, 1000),
      carbsG: (_toInt(json['carbs_g']) ?? 0).clamp(0, 1000),
      fatG: (_toInt(json['fat_g']) ?? 0).clamp(0, 1000),
      estimatedGrams: (_toInt(json['estimated_g']) ?? 300).clamp(1, 10000),
      imageBytes: imageBytes,
    );
  }

  /// Baut das Eigen-Rezept nach denselben Regeln wie das manuelle Formular
  /// (recipe_create_sheet.dart:_save): frischer user_-Slug, Kategorie
  /// "Eigene", kein professionalHint (die Tabelle fuehrt die Spalte nicht).
  /// [imageAsset] ist die RecipeImageStore-Referenz (`local:<name>.jpg`)
  /// oder '' wenn kein Bild gespeichert werden konnte.
  FitnessRecipe toFitnessRecipe({required String imageAsset}) {
    return FitnessRecipe(
      slug: FitnessRecipe.userRecipeSlug(),
      title: title,
      description: description,
      portion: portion,
      ingredients: ingredients,
      preparation: preparation,
      professionalHint: '',
      imageAsset: imageAsset,
      caloriesKcal: caloriesKcal,
      proteinG: proteinG,
      carbsG: carbsG,
      fatG: fatG,
      estimatedGrams: estimatedGrams,
      categories: const <String>['Eigene'],
      userCreated: true,
    );
  }

  static int? _toInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.round();
    if (value is String) return int.tryParse(value.trim());
    return null;
  }
}
