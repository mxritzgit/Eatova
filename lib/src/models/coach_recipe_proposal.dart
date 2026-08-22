import 'dart:typed_data';

import 'fitness_recipe.dart';

/// Recipe proposal from the coach (`mode: "recipe"` of the coach-chat
/// function). Client view of the snake_case wire format; lives only in the
/// running chat session — only the [FitnessRecipe] is persisted.
///
/// The server already clamps everything (recipe.ts, RECIPE_LIMITS); the
/// clamps here only guard against older/broken responses, notably
/// `estimated_g >= 1` because [FitnessRecipe.kcalPer100G] divides by it.
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

  /// "\n- " line list — same free-text format as the manual recipe form.
  final String ingredients;

  /// "\n1. " numbered steps.
  final String preparation;

  final int caloriesKcal;
  final int proteinG;
  final int carbsG;
  final int fatG;
  final int estimatedGrams;

  /// Generated photo (JPEG). In memory only — image bytes are never
  /// persisted into the chat history (same rule as user photos).
  final Uint8List? imageBytes;

  /// null = unusable proposal (no title or no kcal); callers treat it like
  /// an empty response.
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

  /// Builds the user recipe by the same rules as the manual form; only the
  /// slug comes from the CALLER. For card proposals it is derived
  /// deterministically from the message id (FitnessRecipe.coachProposalSlug),
  /// never random — otherwise the "added" state is lost after a restart.
  FitnessRecipe toFitnessRecipe({
    required String imageAsset,
    required String slug,
  }) {
    return FitnessRecipe(
      slug: slug,
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

  /// Same proposal with image bytes loaded from disk — for the reload card:
  /// JSON from the history (chat_messages.recipe), bytes from
  /// RecipeImageStore.
  CoachRecipeProposal withImageBytes(Uint8List bytes) {
    return CoachRecipeProposal(
      title: title,
      description: description,
      portion: portion,
      ingredients: ingredients,
      preparation: preparation,
      caloriesKcal: caloriesKcal,
      proteinG: proteinG,
      carbsG: carbsG,
      fatG: fatG,
      estimatedGrams: estimatedGrams,
      imageBytes: bytes,
    );
  }

  static int? _toInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.round();
    if (value is String) return int.tryParse(value.trim());
    return null;
  }
}
