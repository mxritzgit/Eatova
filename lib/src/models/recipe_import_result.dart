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
    final rawWarnings = json['warnings'] ?? const [];
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
  });

  final String id, title, description, portion, ingredients, preparation;
  final String variantLabel;
  final int? caloriesKcal, proteinG, carbsG, fatG, estimatedGrams;
  final double? servings;
  final bool nutritionEstimated;
  final bool nutritionBasisUnclear;

  bool get hasNutrition =>
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
      nutritionBasisUnclear: json['nutrition_basis'] == 'unspecified',
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
    servings: clearNutrition ? null : servings,
    nutritionEstimated: !clearNutrition && nutritionEstimated,
    nutritionBasisUnclear: !clearNutrition && nutritionBasisUnclear,
  );

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
        if (!hasNutrition || nutritionBasisUnclear) ...[
          recipeNutritionPendingCategory,
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
