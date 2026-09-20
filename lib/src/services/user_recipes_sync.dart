import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/fitness_recipe.dart';
import 'sync_operation_sync.dart';
import 'user_recipe_reads.dart';
import 'user_rpc.dart';
import 'uuid.dart';

export '../models/recipe_mutation_result.dart';
export 'user_recipe_reads.dart';

/// Versioned account-scoped recipes. Missing RPCs must remain pending locally.
class UserRecipesSync {
  UserRecipesSync(this._client, this._userId);
  final SupabaseClient _client;
  final String _userId;

  /// The full snapshot is bounded by the server's active recipe capacity.
  static const int userRecipesLimit = 5000;

  Future<List<FitnessRecipe>> load() =>
      UserRecipeReads(_client, _userId).load();

  Future<Set<String>> loadPhotoReferences() =>
      UserRecipeReads(_client, _userId).loadPhotoReferences();

  Future<RecipeHistoryPage> loadHistory({String? slug, int? beforeRevision}) =>
      UserRecipeReads(
        _client,
        _userId,
      ).loadHistory(slug: slug, beforeRevision: beforeRevision);

  /// Durable replay uses SyncOperationSync with its persisted operation UUID.
  Future<RecipeMutationResult> upsert(
    FitnessRecipe recipe, {
    String? operationId,
    int? expectedRevision,
  }) => _apply(operationId ?? uuidV4(), 'recipeUpsert', recipe.slug, {
    'recipe': recipe.toRow(),
    'expected_revision': expectedRevision ?? recipe.serverRevision,
  });

  Future<RecipeMutationResult> delete(
    String slug, {
    String? operationId,
    int? expectedRevision,
  }) => _apply(operationId ?? uuidV4(), 'recipeDelete', slug, {
    'expected_revision': expectedRevision,
  });

  Future<RecipeMutationResult> _apply(
    String id,
    String kind,
    String slug,
    Map<String, dynamic> payload,
  ) async {
    if (!isUuidShape(id)) {
      throw const FormatException('Invalid operation identity');
    }
    final dynamic raw;
    try {
      raw = await userRpc(
        _client,
        _userId,
        'apply_sync_operation',
        params: {
          'p_operation_id': id,
          'p_kind': kind,
          'p_entity_id': slug,
          'p_payload': payload,
        },
      );
    } on PostgrestException catch (error) {
      rethrowSyncFailure(error);
    }
    if (raw is! Map) throw const FormatException('Invalid recipe receipt');
    final receipt = SyncOperationReceipt.fromJson(raw.cast<String, dynamic>());
    if (receipt.operationId != id ||
        receipt.kind.name != kind ||
        receipt.entityId != slug ||
        receipt.recipeMutation == null) {
      throw const FormatException('Mismatched recipe receipt');
    }
    return receipt.recipeMutation!;
  }
}
