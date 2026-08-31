import 'dart:developer' as dev;

import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/fitness_recipe.dart';

/// Reads and writes user-created recipes against public.user_recipes.
/// Mirrors MealsSync: one instance per user_id, every method atomic against
/// the table. Conflict key is (user_id, slug) from
/// FitnessRecipe.userRecipeSlug().
class UserRecipesSync {
  UserRecipesSync(this._client, this._userId);

  final SupabaseClient _client;
  final String _userId;

  /// Generous cap for user recipes (newest first). Recipes are created one by
  /// one, so 200 is far above any real count but bounds the boot read.
  ///
  /// "Far above" is a guess, not a guarantee — the table itself allows 5000
  /// (migration 20260829120000). A caller that gets exactly this many rows
  /// holds a WINDOW on the newest recipes, not the collection, and must not
  /// conclude anything from an entry it does not see: `HomeStore` turns a full
  /// page into `userRecipesAuthoritative == false`, which stops the orphan
  /// photo sweep from deleting the older recipes' photos (review 2026-08-31,
  /// A).
  static const int userRecipesLimit = 200;

  Future<List<FitnessRecipe>> load() async {
    try {
      final rows = await _client
          .from('user_recipes')
          .select(
            'slug, title, description, portion, ingredients, preparation, '
            'image_asset, calories_kcal, protein_g, carbs_g, fat_g, '
            'estimated_g, categories',
          )
          .eq('user_id', _userId)
          .order('created_at', ascending: false)
          .limit(userRecipesLimit);
      return rows
          .map<FitnessRecipe>(
            (row) => FitnessRecipe.fromRow((row as Map).cast<String, dynamic>()),
          )
          .toList();
    } catch (e, stack) {
      dev.log('UserRecipesSync.load failed',
          error: e, stackTrace: stack, name: 'user_recipes_sync');
      rethrow;
    }
  }

  Future<void> upsert(FitnessRecipe recipe) async {
    try {
      await _client.from('user_recipes').upsert({
        'user_id': _userId,
        ...recipe.toRow(),
      }, onConflict: 'user_id,slug', ignoreDuplicates: false);
    } catch (e, stack) {
      dev.log('UserRecipesSync.upsert failed',
          error: e, stackTrace: stack, name: 'user_recipes_sync');
      rethrow;
    }
  }

  Future<void> delete(String slug) async {
    try {
      await _client
          .from('user_recipes')
          .delete()
          .eq('slug', slug)
          .eq('user_id', _userId);
    } catch (e, stack) {
      dev.log('UserRecipesSync.delete failed',
          error: e, stackTrace: stack, name: 'user_recipes_sync');
      rethrow;
    }
  }
}
