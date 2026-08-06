import 'dart:developer' as dev;

import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/fitness_recipe.dart';

/// Liest und schreibt selbst angelegte Rezepte gegen public.user_recipes.
/// Spiegelt MealsSync: eine Instanz gehoert einem user_id, jede Methode ist
/// atomar gegen die Tabelle. Der Konflikt-Schluessel ist (user_id, slug) —
/// derselbe stabile User-Slug, den FitnessRecipe.userRecipeSlug() vergibt.
class UserRecipesSync {
  UserRecipesSync(this._client, this._userId);

  final SupabaseClient _client;
  final String _userId;

  /// Grosszuegiger Deckel fuer selbst angelegte Rezepte (neueste zuerst).
  /// Rezepte entstehen einzeln von Hand — 200 liegt weit ueber jedem
  /// realistischen Bestand, verhindert aber den unbounded Boot-Read.
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
