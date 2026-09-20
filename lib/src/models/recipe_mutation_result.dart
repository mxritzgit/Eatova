import 'fitness_recipe.dart';

enum RecipeMutationOutcome { applied, conflictSaved, deleteConflict }

/// Current projection, distinct from the immutable mutation's rebase revision.
class RecipeRemoteState {
  const RecipeRemoteState({
    required this.slug,
    required this.revision,
    required this.deleted,
    this.recipe,
  });
  final String slug;
  final int revision;
  final bool deleted;
  final FitnessRecipe? recipe;

  factory RecipeRemoteState.fromJson(Map<String, dynamic> json) {
    final slug = json['slug'];
    final revision = json['revision'];
    final deleted = json['deleted'];
    final raw = json['recipe'];
    if (slug is! String ||
        slug.isEmpty ||
        revision is! int ||
        revision < 0 ||
        deleted is! bool ||
        (deleted ? raw != null : raw is! Map)) {
      throw const FormatException('Invalid current recipe state');
    }
    final recipe = raw == null
        ? null
        : FitnessRecipe.fromRow((raw as Map).cast<String, dynamic>());
    if (recipe != null &&
        (recipe.slug != slug ||
            recipe.serverRevision != revision ||
            revision == 0)) {
      throw const FormatException('Inconsistent current recipe state');
    }
    return RecipeRemoteState(
      slug: slug,
      revision: revision,
      deleted: deleted,
      recipe: recipe,
    );
  }
}

/// A committed server decision. Conflict copies are successes that retain data.
class RecipeMutationResult {
  const RecipeMutationResult({
    required this.outcome,
    required this.currentRevision,
    required this.currentDeleted,
    this.savedRecipe,
    this.currentRecipe,
  });

  final RecipeMutationOutcome outcome;
  final int currentRevision;
  final bool currentDeleted;
  final FitnessRecipe? savedRecipe;
  final FitnessRecipe? currentRecipe;

  factory RecipeMutationResult.fromJson(Map<String, dynamic> json) {
    final revision = json['current_revision'];
    final deleted = json['current_deleted'];
    if (revision is! int || revision < 0 || deleted is! bool) {
      throw const FormatException('Invalid recipe mutation receipt');
    }
    final rawOutcome = json['outcome'];
    final outcomes = RecipeMutationOutcome.values.where(
      (value) => value.name == rawOutcome,
    );
    if (outcomes.isEmpty) {
      throw const FormatException('Invalid recipe mutation outcome');
    }
    final outcome = outcomes.first;
    FitnessRecipe? recipe(String key) {
      final value = json[key];
      if (value == null) return null;
      if (value is! Map) {
        throw const FormatException('Invalid recipe receipt row');
      }
      final result = FitnessRecipe.fromRow(value.cast<String, dynamic>());
      if (result.serverRevision == null || result.serverRevision! <= 0) {
        throw const FormatException('Unversioned recipe receipt');
      }
      return result;
    }

    final saved = recipe('saved_recipe');
    final current = recipe('current_recipe');
    if ((outcome == RecipeMutationOutcome.conflictSaved && saved == null) ||
        (deleted && current != null) ||
        (current != null && current.serverRevision != revision)) {
      throw const FormatException('Inconsistent recipe mutation receipt');
    }
    return RecipeMutationResult(
      outcome: outcome,
      currentRevision: revision,
      currentDeleted: deleted,
      savedRecipe: saved,
      currentRecipe: current,
    );
  }
}
