import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/digests/sha256.dart';

import 'fitness_recipe.dart';
import 'model_limits.dart' show truncateToChars;

enum RecipeImportStatus { ready, needsText, noRecipe }

/// Untrusted extraction output, validated before it reaches a recipe draft.
class RecipeImportResult {
  const RecipeImportResult({
    required this.status,
    this.candidates = const [],
    this.sourceUrl,
    this.sourceTitle,
    this.sourceAuthor,
    this.sourceUnavailable = false,
    this.warnings = const [],
  });

  final RecipeImportStatus status;
  final List<RecipeImportCandidate> candidates;
  final String? sourceUrl, sourceTitle, sourceAuthor;
  final List<String> warnings;
  final bool sourceUnavailable;

  factory RecipeImportResult.fromJson(Map<String, dynamic> json) {
    final status = switch (json['status']) {
      'ready' => RecipeImportStatus.ready,
      'needs_text' => RecipeImportStatus.needsText,
      'no_recipe' => RecipeImportStatus.noRecipe,
      _ => throw const FormatException('Invalid import status'),
    };
    final raw = json['candidates'];
    if (raw is! List ||
        raw.length > 6 ||
        (status == RecipeImportStatus.ready) != raw.isNotEmpty) {
      throw const FormatException('Invalid import candidates');
    }
    final candidates = raw
        .map((item) {
          if (item is! Map<String, dynamic>) {
            throw const FormatException('Invalid import candidate');
          }
          return RecipeImportCandidate.fromJson(item);
        })
        .toList(growable: false);
    if (candidates.map((c) => c.id).toSet().length != candidates.length) {
      throw const FormatException('Duplicate import candidates');
    }
    final source = json['source'];
    if (source is! Map<String, dynamic>) {
      throw const FormatException('Invalid import source');
    }
    final url = _optionalText(source['url'], 2048);
    if (url != null) {
      final uri = Uri.tryParse(url);
      if (uri == null ||
          uri.scheme != 'https' ||
          uri.userInfo.isNotEmpty ||
          uri.port != 443 ||
          !const {
            'www.tiktok.com',
            'tiktok.com',
            'vm.tiktok.com',
            'vt.tiktok.com',
          }.contains(uri.host.toLowerCase())) {
        throw const FormatException('Invalid import source URL');
      }
    }
    final rawWarnings = json['warnings'] ?? const <dynamic>[];
    if (rawWarnings is! List ||
        rawWarnings.length > 6 ||
        rawWarnings.any(
          (w) => !const {
            'nutrition_missing',
            'source_incomplete',
            'truncated',
          }.contains(w),
        )) {
      throw const FormatException('Invalid import warnings');
    }
    return RecipeImportResult(
      status: status,
      candidates: List.unmodifiable(candidates),
      sourceUrl: url,
      sourceUnavailable: source['unavailable'] == true,
      sourceTitle: _optionalText(source['title'], 500),
      sourceAuthor: _optionalText(source['author'], 160),
      warnings: List<String>.unmodifiable(rawWarnings),
    );
  }
}

class RecipeImportCandidate {
  const RecipeImportCandidate({
    required this.id,
    required this.title,
    required this.ingredients,
    required this.preparation,
    this.description = '',
    this.portion = '',
    this.variantLabel = '',
    this.caloriesKcal,
    this.proteinG,
    this.carbsG,
    this.fatG,
    this.estimatedGrams,
    this.servings,
    this.nutritionEstimated = false,
    this.nutritionBasisUnclear = false,
    this.nutritionConflicts = const [],
    this.ingredientsBasis = RecipeIngredientsBasis.unspecified,
  });

  final String id, title, description, portion, ingredients, preparation;
  final String variantLabel;
  final int? caloriesKcal, proteinG, carbsG, fatG, estimatedGrams;
  final double? servings;
  final bool nutritionEstimated;
  final bool nutritionBasisUnclear;
  final List<String> nutritionConflicts;
  final RecipeIngredientsBasis ingredientsBasis;

  bool get hasNutrition =>
      nutritionConflicts.isEmpty &&
      caloriesKcal != null &&
      proteinG != null &&
      carbsG != null &&
      fatG != null;

  factory RecipeImportCandidate.fromJson(Map<String, dynamic> json) {
    if (!const [
      null,
      'per_serving',
      'unspecified',
    ].contains(json['nutrition_basis'])) {
      throw const FormatException('Invalid import nutrition basis');
    }
    if (!const [null, 'per_recipe', 'per_serving', 'unspecified'].contains(json['ingredients_basis'])) {
      throw const FormatException('Invalid import ingredient basis');
    }
    final conflicts = json['nutrition_conflicts'] ?? const <dynamic>[];
    if (conflicts is! List || conflicts.length > 4 ||
        conflicts.any((field) => !recipeNutritionFields.contains(field) || json[field] != null) ||
        conflicts.toSet().length != conflicts.length) {
      throw const FormatException('Invalid import nutrition conflicts');
    }
    final estimated = json['nutrition_estimated'];
    if (estimated is! bool) {
      throw const FormatException('Invalid import nutrition status');
    }
    return RecipeImportCandidate(
      id: _text(json['id'], 80),
      title: _text(json['title'], 160),
      description: _text(json['description'] ?? '', 2000, empty: true),
      portion: _text(json['portion'] ?? '', 200, empty: true),
      ingredients: _text(json['ingredients'], 8000),
      preparation: _text(json['preparation'], 10000, empty: true),
      variantLabel: _text(json['variant_label'] ?? '', 160, empty: true),
      caloriesKcal: _integer(json['calories_kcal'], 10000),
      proteinG: _integer(json['protein_g'], 1000),
      carbsG: _integer(json['carbs_g'], 1000),
      fatG: _integer(json['fat_g'], 1000),
      estimatedGrams: _integer(json['estimated_g'], 10000),
      servings: _servings(json['servings']),
      nutritionEstimated: estimated,
      nutritionConflicts: List<String>.unmodifiable(conflicts),
      nutritionBasisUnclear: json['nutrition_basis'] == 'unspecified',
      ingredientsBasis: switch (json['ingredients_basis']) {
        'per_recipe' when json['servings'] != null => RecipeIngredientsBasis.perRecipe,
        'per_serving' => RecipeIngredientsBasis.perServing,
        _ => RecipeIngredientsBasis.unspecified,
      },
    );
  }

  RecipeImportCandidate copyWith({
    String? title,
    String? description,
    String? portion,
    String? ingredients,
    String? preparation,
    bool clearNutrition = false,
  }) => RecipeImportCandidate(
    id: id,
    title: title ?? this.title,
    description: description ?? this.description,
    portion: portion ?? this.portion,
    ingredients: ingredients ?? this.ingredients,
    preparation: preparation ?? this.preparation,
    variantLabel: variantLabel,
    caloriesKcal: clearNutrition ? null : caloriesKcal,
    proteinG: clearNutrition ? null : proteinG,
    carbsG: clearNutrition ? null : carbsG,
    fatG: clearNutrition ? null : fatG,
    estimatedGrams: clearNutrition ? null : estimatedGrams,
    servings: servings,
    ingredientsBasis: (ingredients != null && ingredients != this.ingredients) ||
        (portion != null && portion != this.portion)
        ? RecipeIngredientsBasis.unspecified : ingredientsBasis,
    nutritionConflicts: clearNutrition ? const [] : nutritionConflicts,
    nutritionEstimated: !clearNutrition && nutritionEstimated,
    nutritionBasisUnclear: !clearNutrition && nutritionBasisUnclear,
  );

  /// Applies an explicitly reviewed draft without changing its source identity.
  RecipeImportCandidate withReviewedNutrition(FitnessRecipe reviewed) {
    if (reviewed.hasPendingNutrition || reviewed.hasMissingNutrition ||
        reviewed.hasStructuredIngredients) {
      throw const FormatException('Nutrition review is incomplete');
    }
    return RecipeImportCandidate(
      id: id, title: title, description: description, portion: portion,
      ingredients: ingredients, preparation: preparation, variantLabel: variantLabel,
      servings: servings, ingredientsBasis: ingredientsBasis,
      caloriesKcal: _integer(reviewed.caloriesKcal, 10000),
      proteinG: _integer(reviewed.proteinG, 1000),
      carbsG: _integer(reviewed.carbsG, 1000),
      fatG: _integer(reviewed.fatG, 1000),
      estimatedGrams: nutritionBasisUnclear ? null : estimatedGrams,
    );
  }

  /// Content identity makes repeated shares and uncertain save retries idempotent.
  String stableSlug([String? sourceUrl]) {
    String normalize(String value) =>
        value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    final bytes = utf8.encode(
      jsonEncode([
        sourceUrl ?? '',
        normalize(ingredients),
        normalize(preparation),
      ]),
    );
    final digest = SHA256Digest().process(Uint8List.fromList(bytes));
    final hex = digest
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    return 'user_import_$hex';
  }

  FitnessRecipe toRecipe({
    required String slug,
    String? sourceUrl,
    required String sourceLabel,
  }) {
    _text(title, 160);
    _text(ingredients, 8000);
    _text(preparation, 10000, empty: true);
    _text(portion, 200, empty: true);
    final source = sourceUrl == null ? '' : '$sourceLabel: $sourceUrl';
    return FitnessRecipe(
      slug: slug,
      title: title.trim(),
      description: [
        truncateToChars(
          description.trim(),
          (4000 - source.runes.length - 2).clamp(0, 4000),
        ),
        source,
      ].where((s) => s.isNotEmpty).join('\n\n'),
      portion: portion.trim(),
      ingredients: ingredients.trim(),
      preparation: preparation.trim(),
      professionalHint: '',
      imageAsset: '',
      caloriesKcal: caloriesKcal ?? 0,
      proteinG: proteinG ?? 0,
      carbsG: carbsG ?? 0,
      fatG: fatG ?? 0,
      estimatedGrams: estimatedGrams ?? 0,
      categories: [
        'Eigene',
        for (final field in nutritionConflicts) '$recipeNutritionConflictPrefix$field',
        '$recipeIngredientsBasisPrefix${switch (ingredientsBasis) {
          RecipeIngredientsBasis.perRecipe when servings != null => 'per_recipe',
          RecipeIngredientsBasis.perServing => 'per_serving',
          _ => 'unspecified',
        }}',
        if (!hasNutrition || nutritionBasisUnclear) ...[
          if (!hasNutrition) recipeNutritionPendingCategory,
          if (nutritionBasisUnclear) recipeNutritionBasisPendingCategory,
          for (final entry in {
            'calories_kcal': caloriesKcal,
            'protein_g': proteinG,
            'carbs_g': carbsG,
            'fat_g': fatG,
          }.entries)
            if (entry.value != null) '$recipeNutritionKnownPrefix${entry.key}',
        ],
      ],
      userCreated: true,
      batchServings: servings ?? 1,
    );
  }
}

String _text(Object? value, int max, {bool empty = false}) {
  if (value is! String ||
      value.length > max ||
      (!empty && value.trim().isEmpty) ||
      RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]').hasMatch(value)) {
    throw const FormatException('Invalid import text');
  }
  return value.trim();
}

String? _optionalText(Object? value, int max) =>
    value == null ? null : _text(value, max);

int? _integer(Object? value, int max) {
  if (value == null) return null;
  if (value is! num || !value.isFinite || value < 0 || value > max) {
    throw const FormatException('Invalid import nutrition');
  }
  // Saved recipes use whole calories/grams; preserve fractional source values
  // through the app's normal rounding boundary instead of rejecting the recipe.
  return value.round();
}

double? _servings(Object? value) {
  if (value == null) return null;
  if (value is! num || !value.isFinite || value < .1 || value > 100) {
    throw const FormatException('Invalid import servings');
  }
  return value.toDouble();
}
