import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/fitness_recipe.dart';
import 'user_rpc.dart';

/// A journal event, including the last content before a deletion.
class RecipeVersion {
  const RecipeVersion({
    required this.recipe,
    required this.revision,
    required this.deleted,
    required this.recordedAt,
    this.hasRecipeContent = true,
    Map<String, dynamic>? record,
  }) : _record = record;

  final FitnessRecipe recipe;
  final int revision;
  final bool deleted;
  final DateTime recordedAt;

  /// False for a deletion recorded before any server recipe content existed.
  final bool hasRecipeContent;
  final Map<String, dynamic>? _record;

  Map<String, dynamic> toJson() => Map.of(
    _record ??
        {
          'revision': revision,
          'deleted': deleted,
          'recorded_at': recordedAt.toIso8601String(),
          'recipe': recipe.toRow(),
        },
  );
}

class RecipeHistoryPage {
  const RecipeHistoryPage({
    required this.versions,
    required this.currentRevision,
    required this.currentDeleted,
    required this.nextBefore,
  });

  final List<RecipeVersion> versions;
  // Null for the account-wide timeline; restore first reads the slug's head.
  final int? currentRevision;
  final bool? currentDeleted;
  final int? nextBefore;
}

/// Reads complete owner snapshots, never publishing an intermediate page.
/// The journal watermark freezes both contents and membership across requests.
class UserRecipeReads {
  UserRecipeReads(this._client, this._userId);

  final SupabaseClient _client;
  final String _userId;
  static const pageSize = 200;
  static const historyPageSize = 30;
  static const maxSnapshotRecipes = 5000;

  Future<List<FitnessRecipe>> load() async =>
      List.unmodifiable((await loadRows()).map(FitnessRecipe.fromRow));

  /// Preserve complete server rows for the user-data export.
  Future<List<Map<String, dynamic>>> loadRows() async {
    final recipes = <Map<String, dynamic>>[];
    final seen = <String>{};
    int? watermark;
    String? after;
    while (true) {
      final page = _object(
        await userRpc(
          _client,
          _userId,
          'load_recipe_page',
          params: {
            'p_watermark': watermark,
            'p_after_slug': after,
            'p_limit': pageSize,
          },
        ),
      );
      final stamp = _revision(page['watermark'], allowZero: true);
      if (watermark != null && watermark != stamp) {
        throw const FormatException('Recipe snapshot changed');
      }
      watermark = stamp;
      final rows = _list(page['rows']);
      final complete = page['complete'];
      final next = page['next_after'];
      if (rows.length > pageSize ||
          complete is! bool ||
          (complete ? next != null : next is! String || next.isEmpty)) {
        throw const FormatException('Invalid recipe page');
      }
      for (final value in rows) {
        final row = _object(value);
        final revision = _revision(row['server_revision']);
        final recipe = FitnessRecipe.fromRow(row);
        if (revision > stamp || !seen.add(recipe.slug)) {
          throw const FormatException('Invalid recipe snapshot row');
        }
        recipes.add(Map.unmodifiable(row));
      }
      if (recipes.length > maxSnapshotRecipes) {
        throw const FormatException('Recipe snapshot exceeds account limit');
      }
      if (complete) return List.unmodifiable(recipes);
      if (rows.isEmpty || next == after || next != recipes.last['slug']) {
        throw const FormatException('Recipe cursor made no progress');
      }
      after = next as String;
    }
  }

  /// Image bytes remain device-local, including versions retained in history.
  /// Callers may collect orphans only after this entire reference set arrives.
  Future<Set<String>> loadPhotoReferences() async {
    final references = <String>{};
    int? watermark;
    String? after;
    while (true) {
      final page = _object(
        await userRpc(
          _client,
          _userId,
          'load_recipe_photo_refs',
          params: {
            'p_watermark': watermark,
            'p_after_ref': after,
            'p_limit': pageSize,
          },
        ),
      );
      final stamp = _revision(page['watermark'], allowZero: true);
      final rows = _list(page['refs']);
      final complete = page['complete'];
      final next = page['next_after'];
      if (watermark != null && watermark != stamp ||
          rows.length > pageSize ||
          complete is! bool ||
          (complete ? next != null : next is! String || next.isEmpty)) {
        throw const FormatException('Invalid recipe photo reference page');
      }
      watermark = stamp;
      for (final value in rows) {
        if (value is! String ||
            !value.startsWith('local:') ||
            !references.add(value)) {
          throw const FormatException('Invalid recipe photo reference');
        }
      }
      if (complete) return Set.unmodifiable(references);
      if (rows.isEmpty || next == after || next != rows.last) {
        throw const FormatException('Recipe photo cursor made no progress');
      }
      after = next as String;
    }
  }

  Future<RecipeHistoryPage> loadHistory({
    String? slug,
    int? beforeRevision,
  }) async {
    if (slug != null && slug.isEmpty ||
        beforeRevision != null && beforeRevision <= 0) {
      throw ArgumentError('Invalid recipe history cursor');
    }
    final page = _object(
      await userRpc(
        _client,
        _userId,
        'load_recipe_history',
        params: {
          'p_slug': slug,
          'p_before_revision': beforeRevision,
          'p_limit': historyPageSize,
        },
      ),
    );
    final rows = _list(page['versions']);
    if (rows.length > historyPageSize) {
      throw const FormatException('Recipe history page exceeds limit');
    }
    final versions = <RecipeVersion>[];
    var previous = beforeRevision;
    for (final value in rows) {
      final row = _object(value);
      final revision = _revision(row['revision']);
      final deleted = row['deleted'];
      final rawAt = row['recorded_at'];
      final at = rawAt is String ? DateTime.tryParse(rawAt) : null;
      final recipeRow = _object(row['recipe']);
      final hasRecipeContent = recipeRow['title'] is String;
      if (!hasRecipeContent &&
          (deleted != true ||
              recipeRow.keys.any(
                (key) => key != 'slug' && key != 'server_revision',
              ))) {
        throw const FormatException('Invalid recipe history content');
      }
      final recipe = FitnessRecipe.fromRow(recipeRow);
      if (deleted is! bool ||
          at == null ||
          (previous != null && revision >= previous) ||
          (slug != null && slug != recipe.slug)) {
        throw const FormatException('Invalid recipe history event');
      }
      versions.add(
        RecipeVersion(
          recipe: recipe,
          revision: revision,
          deleted: deleted,
          recordedAt: at.toUtc(),
          hasRecipeContent: hasRecipeContent,
          record: Map.unmodifiable(row),
        ),
      );
      previous = revision;
    }
    final next = page['next_before'];
    if (next != null &&
        (next is! int || versions.isEmpty || next != previous)) {
      throw const FormatException('Invalid recipe history cursor');
    }
    final current = page['current_revision'];
    final deleted = page['current_deleted'];
    if (slug != null) {
      _revision(current, allowZero: true);
      if (deleted is! bool ||
          versions.any((v) => v.revision > (current as int))) {
        throw const FormatException('Invalid recipe history head');
      }
    } else if (current != null || deleted != null) {
      throw const FormatException('Invalid account recipe history head');
    }
    return RecipeHistoryPage(
      versions: List.unmodifiable(versions),
      currentRevision: current as int?,
      currentDeleted: deleted as bool?,
      nextBefore: next as int?,
    );
  }

  static Map<String, dynamic> _object(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw const FormatException('Invalid recipe response');
    }
    return value;
  }

  static List<dynamic> _list(Object? value) {
    if (value is! List) throw const FormatException('Invalid recipe rows');
    return value;
  }

  static int _revision(Object? value, {bool allowZero = false}) {
    if (value is! int || value < (allowZero ? 0 : 1)) {
      throw const FormatException('Invalid recipe revision');
    }
    return value;
  }
}
