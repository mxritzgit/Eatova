import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/fitness_recipe.dart';
import 'user_recipe_reads.dart';

export '../models/recipe_mutation_result.dart';
export 'user_recipe_reads.dart';

/// Versioned account-scoped recipes. Writes are durable sync operations
/// (`SyncOperationSync`); missing RPCs must remain pending locally.
class UserRecipesSync {
  UserRecipesSync(this._client, this._userId);
  final SupabaseClient _client;
  final String _userId;

  Future<List<FitnessRecipe>> load() =>
      UserRecipeReads(_client, _userId).load();

  Future<Set<String>> loadPhotoReferences() =>
      UserRecipeReads(_client, _userId).loadPhotoReferences();
}
