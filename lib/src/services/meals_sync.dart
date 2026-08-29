import 'dart:async';
import 'dart:developer' as dev;

import 'package:clock/clock.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/favorite_meal.dart';
import '../models/logged_meal.dart';
import '../models/meal_analysis_result.dart';
import '../models/meal_component.dart';
import 'crash_reporter.dart';

/// Reads and writes LoggedMeal + FavoriteMeal against public.logged_meals and
/// public.favorite_meals. MealAnalysisResult travels as a JSONB payload plus a
/// few denormalised filter columns. One instance belongs to one user_id.
class MealsSync {
  MealsSync(this._client, this._userId);

  final SupabaseClient _client;
  final String _userId;

  /// Boot window for the diary (days back from now). The UI shows at most 31
  /// days of history and streak/lifetime numbers come from the server, so 35
  /// is generous. Without a window every cold start loaded ALL meals ever
  /// logged, JSONB payload included.
  static const int loggedMealsWindowDays = 35;

  /// Defensive row cap on top (~28 logs/day in the window): PostgREST truncates
  /// SILENTLY at db-max-rows, while an explicit limit is deterministic and,
  /// thanks to order desc, only ever drops the OLDEST rows of the window.
  static const int loggedMealsMaxRows = 1000;

  /// Row cap for the on-demand day query ([loadLoggedMealsForDay]): ~50 logs on
  /// ONE day is far beyond realistic use, and an explicit limit beats depending
  /// on the silent db-max-rows.
  static const int loggedMealsDayMaxRows = 50;

  /// Favourites cap: the client only keeps 5 auto-recents plus pinned
  /// favourites, so 200 is far above any realistic pin count.
  static const int favoritesLimit = 200;

  // ---------- logged_meals ----------

  Future<List<LoggedMeal>> loadLoggedMeals() async {
    try {
      // Window on logged_at (indexed user_id+logged_at desc), not local_day:
      // older rows may carry local_day=null and would silently be missing.
      //
      // P1-06: `clock.now()`, not `DateTime.now()`. The store's window
      // predicate (`_isOutsideBootWindow`) reads the injectable clock, so the
      // two measured against different clocks under `withClock` and the
      // invariant "a day the store treats as inside the window really was
      // loaded" was not provable for any test. In production both are the
      // same wall clock.
      final cutoffIso = clock.now()
          .toUtc()
          .subtract(const Duration(days: loggedMealsWindowDays))
          .toIso8601String();
      final rows = await _client
          .from('logged_meals')
          .select('id, logged_at, forced_slot, local_day, payload')
          .eq('user_id', _userId)
          .gte('logged_at', cutoffIso)
          .order('logged_at', ascending: false)
          .limit(loggedMealsMaxRows);
      return _mealsFromRows(rows);
    } catch (e, stack) {
      dev.log('MealsSync.loadLoggedMeals failed',
          error: e, stackTrace: stack, name: 'meals_sync');
      rethrow;
    }
  }

  /// Loads specific rows by id — WITHOUT the date window.
  ///
  /// Only caller is the re-display after a permanently dropped delete
  /// (`_restoreDroppedDeletes`): that row can be arbitrarily old, so the
  /// windowed [loadLoggedMeals] would miss it and the "it's back" hint would
  /// lie. The id set is small, so the window limit suffices.
  Future<List<LoggedMeal>> loadLoggedMealsByIds(Set<String> ids) async {
    if (ids.isEmpty) return const <LoggedMeal>[];
    try {
      final rows = await _client
          .from('logged_meals')
          .select('id, logged_at, forced_slot, local_day, payload')
          .eq('user_id', _userId)
          .inFilter('id', ids.toList())
          .order('logged_at', ascending: false)
          .limit(loggedMealsMaxRows);
      return _mealsFromRows(rows);
    } catch (e, stack) {
      dev.log('MealsSync.loadLoggedMealsByIds failed',
          error: e, stackTrace: stack, name: 'meals_sync');
      rethrow;
    }
  }

  /// Loads the meals of ONE local calendar day — the on-demand path for days
  /// outside the [loggedMealsWindowDays] boot window. Half-open local wall
  /// clock window [day 00:00, next day 00:00) translated to UTC on logged_at,
  /// because old rows may carry local_day=null.
  Future<List<LoggedMeal>> loadLoggedMealsForDay(DateTime day) async {
    try {
      final start = DateTime(day.year, day.month, day.day);
      // day+1 instead of +Duration(days: 1): the constructor normalises to the
      // next local midnight, DST edges included.
      final end = DateTime(day.year, day.month, day.day + 1);
      final rows = await _client
          .from('logged_meals')
          .select('id, logged_at, forced_slot, local_day, payload')
          .eq('user_id', _userId)
          .gte('logged_at', start.toUtc().toIso8601String())
          .lt('logged_at', end.toUtc().toIso8601String())
          .order('logged_at', ascending: false)
          .limit(loggedMealsDayMaxRows)
          // No postgrest auto-retry (default 3 attempts, 1s/2s/4s backoff):
          // this query runs interactively behind a spinner, where the silent
          // retry cascade would delay the error by ~7s. Tapping the day again
          // reloads.
          .retry(enabled: false);
      return _mealsFromRows(rows);
    } catch (e, stack) {
      dev.log('MealsSync.loadLoggedMealsForDay failed',
          error: e, stackTrace: stack, name: 'meals_sync');
      rethrow;
    }
  }

  /// Maps server rows and SKIPS broken ones individually (S1): since
  /// `mealResultFromJson` throws on a corrupt payload, one bad row would
  /// otherwise tear down the whole load and freeze the diary on the cache
  /// state. Skipped rows go to dev.log + CrashReporter; the data stays on the
  /// server untouched.
  static List<LoggedMeal> _mealsFromRows(List<dynamic> rows) {
    final meals = <LoggedMeal>[];
    for (final row in rows) {
      try {
        meals.add(_mealFromRow(row));
      } catch (e, stack) {
        dev.log('MealsSync: korrupte Zeile uebersprungen (${row['id']})',
            error: e, stackTrace: stack, name: 'meals_sync');
        unawaited(CrashReporter.capture(e, stack, context: 'meals.row-corrupt'));
      }
    }
    return meals;
  }

  /// Shared row mapping for [loadLoggedMeals] and [loadLoggedMealsForDay]
  /// (identical select in both queries).
  static LoggedMeal _mealFromRow(dynamic row) {
    return LoggedMeal(
      id: row['id'] as String,
      loggedAt: DateTime.parse(row['logged_at'] as String).toLocal(),
      forcedSlot: _parseSlot(row['forced_slot']?.toString()),
      // DATA-6: carry the canonical local day key when the row has one. Older
      // rows without it fall back to isSameDay(.toLocal()) (see meal_totals).
      localDay: row['local_day']?.toString(),
      result: mealResultFromJson(
        (row['payload'] as Map).cast<String, dynamic>(),
      ),
    );
  }

  Future<void> insertLoggedMeal(LoggedMeal meal) async {
    try {
      // Upsert on the client UUID instead of insert: a retry after an unclear
      // network timeout (response lost, row written) stays idempotent.
      await _client.from('logged_meals').upsert({
        'id': meal.id,
        'user_id': _userId,
        'logged_at': meal.loggedAt.toUtc().toIso8601String(),
        // DATA-6: canonical local day key from the entry's LOCAL wall clock,
        // derived from loggedAt when not set, so entries share the same day
        // without UTC drift across DST/zones.
        'local_day': meal.effectiveLocalDay,
        'forced_slot': meal.forcedSlot?.name,
        'meal_name': meal.result.mealName,
        'calories_kcal': meal.result.caloriesKcal,
        'estimated_g': meal.result.estimatedGrams,
        'protein_g': _macroToNumeric(meal.result.protein),
        'carbs_g': _macroToNumeric(meal.result.carbs),
        'fat_g': _macroToNumeric(meal.result.fat),
        'barcode': meal.result.barcode,
        'brand': meal.result.brand,
        'source_label': meal.result.sourceLabel,
        'payload': mealResultToJson(meal.result),
      }, onConflict: 'id', ignoreDuplicates: false);
    } catch (e, stack) {
      dev.log('MealsSync.insertLoggedMeal failed',
          error: e, stackTrace: stack, name: 'meals_sync');
      rethrow;
    }
  }

  Future<void> updateLoggedMeal(LoggedMeal meal) async {
    try {
      await _client
          .from('logged_meals')
          .update({
            // An update can also move day/slot of an existing row, so
            // logged_at + local_day always ride along; portion-only updates
            // rewrite the same value.
            'logged_at': meal.loggedAt.toUtc().toIso8601String(),
            'local_day': meal.effectiveLocalDay,
            'forced_slot': meal.forcedSlot?.name,
            'meal_name': meal.result.mealName,
            'calories_kcal': meal.result.caloriesKcal,
            'estimated_g': meal.result.estimatedGrams,
            'protein_g': _macroToNumeric(meal.result.protein),
            'carbs_g': _macroToNumeric(meal.result.carbs),
            'fat_g': _macroToNumeric(meal.result.fat),
            'barcode': meal.result.barcode,
            'brand': meal.result.brand,
            'source_label': meal.result.sourceLabel,
            'payload': mealResultToJson(meal.result),
          })
          .eq('id', meal.id)
          .eq('user_id', _userId);
    } catch (e, stack) {
      dev.log('MealsSync.updateLoggedMeal failed',
          error: e, stackTrace: stack, name: 'meals_sync');
      rethrow;
    }
  }

  Future<void> deleteLoggedMeal(String id) async {
    try {
      await _client
          .from('logged_meals')
          .delete()
          .eq('id', id)
          .eq('user_id', _userId);
    } catch (e, stack) {
      dev.log('MealsSync.deleteLoggedMeal failed',
          error: e, stackTrace: stack, name: 'meals_sync');
      rethrow;
    }
  }

  // ---------- favorite_meals ----------

  Future<List<FavoriteMeal>> loadFavorites() async {
    try {
      final rows = await _client
          .from('favorite_meals')
          .select('favorite_key, added_at, payload, pinned')
          .eq('user_id', _userId)
          .order('added_at', ascending: false)
          .limit(favoritesLimit);
      return rows.map<FavoriteMeal>((row) {
        return FavoriteMeal(
          id: row['favorite_key'] as String,
          addedAt: DateTime.parse(row['added_at'] as String).toLocal(),
          // Older rows without the column / null -> false (auto-recent).
          pinned: (row['pinned'] as bool?) ?? false,
          result: mealResultFromJson(
            (row['payload'] as Map).cast<String, dynamic>(),
          ),
        );
      }).toList();
    } catch (e, stack) {
      dev.log('MealsSync.loadFavorites failed',
          error: e, stackTrace: stack, name: 'meals_sync');
      rethrow;
    }
  }

  Future<void> upsertFavorite(FavoriteMeal fav) async {
    try {
      await _client.from('favorite_meals').upsert({
        'user_id': _userId,
        'favorite_key': fav.id,
        'meal_name': fav.result.mealName,
        'calories_kcal': fav.result.caloriesKcal,
        'estimated_g': fav.result.estimatedGrams,
        'barcode': fav.result.barcode,
        'brand': fav.result.brand,
        'source_label': fav.result.sourceLabel,
        'payload': mealResultToJson(fav.result),
        'added_at': fav.addedAt.toUtc().toIso8601String(),
        'pinned': fav.pinned,
      }, onConflict: 'user_id,favorite_key');
    } catch (e, stack) {
      dev.log('MealsSync.upsertFavorite failed',
          error: e, stackTrace: stack, name: 'meals_sync');
      rethrow;
    }
  }

  Future<void> deleteFavorite(String favoriteKey) async {
    try {
      await _client
          .from('favorite_meals')
          .delete()
          .eq('favorite_key', favoriteKey)
          .eq('user_id', _userId);
    } catch (e, stack) {
      dev.log('MealsSync.deleteFavorite failed',
          error: e, stackTrace: stack, name: 'meals_sync');
      rethrow;
    }
  }

  // ---------- helpers ----------

  static MealSlot? _parseSlot(String? raw) {
    if (raw == null) return null;
    for (final v in MealSlot.values) {
      if (v.name == raw) return v;
    }
    return null;
  }

  static num? _macroToNumeric(String macroText) {
    final match = RegExp(r'(\d+(?:[.,]\d+)?)').firstMatch(macroText);
    if (match == null) return null;
    return num.tryParse(match.group(1)!.replaceAll(',', '.'));
  }
}

/// Serialises MealAnalysisResult for JSONB columns and reads it back
/// roundtrip-safe. Kept here, not in the model, so persistence does not leak
/// into the domain model.
Map<String, dynamic> mealResultToJson(MealAnalysisResult r) {
  return {
    'mealName': r.mealName,
    'caloriesKcal': r.caloriesKcal,
    'estimatedGrams': r.estimatedGrams,
    'kcalPer100G': r.kcalPer100G,
    'protein': r.protein,
    'carbs': r.carbs,
    'fat': r.fat,
    'confidence': r.confidence,
    'portionNotes': r.portionNotes,
    'items': r.items
        .map((c) => {
              'name': c.name,
              'grams': c.grams,
              'caloriesKcal': c.caloriesKcal,
              if (c.kcalPer100G != null) 'kcalPer100G': c.kcalPer100G,
              // B8: per-item macros. `!= null`, not `> 0` — 0 g is a statement
              // (olive oil has 0 g protein), `null` means unknown. Only if ALL
              // items carry macros does adjustedToItems sum exactly instead of
              // scaling by mass.
              if (c.proteinG != null) 'proteinG': c.proteinG,
              if (c.carbsG != null) 'carbsG': c.carbsG,
              if (c.fatG != null) 'fatG': c.fatG,
            })
        .toList(),
    'isAdjusted': r.isAdjusted,
    'sourceLabel': r.sourceLabel,
    if (r.barcode != null) 'barcode': r.barcode,
    if (r.brand != null) 'brand': r.brand,
    // B7: a measured 0 kcal (water, zero drinks) must survive the roundtrip,
    // otherwise the last-resort guard blocks the auto-recent favourite of the
    // same product. Only written when true, so old rows stay byte-identical.
    if (r.explicitZeroKcal) 'explicitZeroKcal': true,
  };
}

MealAnalysisResult mealResultFromJson(Map<String, dynamic> j) {
  final itemsRaw = j['items'];
  final items = itemsRaw is List
      ? itemsRaw
          .whereType<Map>()
          .map((m) {
            final item = m.cast<String, dynamic>();
            return MealComponent(
              name: item['name']?.toString() ?? '',
              grams: (item['grams'] as num?)?.toInt() ?? 0,
              caloriesKcal: (item['caloriesKcal'] as num?)?.toInt() ?? 0,
              kcalPer100G: (item['kcalPer100G'] as num?)?.toDouble(),
              // A missing key stays `null` = unknown, so older rows load
              // unchanged.
              proteinG: (item['proteinG'] as num?)?.toDouble(),
              carbsG: (item['carbsG'] as num?)?.toDouble(),
              fatG: (item['fatG'] as num?)?.toDouble(),
            );
          })
          .toList()
      : const <MealComponent>[];
  // S1: `caloriesKcal` is required — mealResultToJson always writes it, so a
  // payload without the key is corrupt. The old `?? 0` fill produced exactly
  // the kind of 0 that B7 separates from a measured 0, and outbox replay wrote
  // it to the server permanently. The throw lands in honest handlers:
  // SyncOp.meal -> null -> corrupt-payload drop (A8); LocalCache catches it
  // per slot; [_mealsFromRows] skips and reports the row. Grams/density keep 0
  // as their documented unknown form.
  final caloriesRoh = j['caloriesKcal'];
  if (caloriesRoh is! num) {
    throw FormatException(
        'meal payload ohne lesbares caloriesKcal (${caloriesRoh.runtimeType})');
  }
  return MealAnalysisResult(
    mealName: j['mealName']?.toString() ?? 'Mahlzeit',
    caloriesKcal: caloriesRoh.toInt(),
    estimatedGrams: (j['estimatedGrams'] as num?)?.toInt() ?? 0,
    kcalPer100G: (j['kcalPer100G'] as num?)?.toDouble() ?? 0.0,
    protein: j['protein']?.toString() ?? '-',
    carbs: j['carbs']?.toString() ?? '-',
    fat: j['fat']?.toString() ?? '-',
    confidence: j['confidence']?.toString() ?? MealResultConfidence.medium.code,
    portionNotes: j['portionNotes']?.toString() ?? '',
    items: items,
    isAdjusted: (j['isAdjusted'] as bool?) ?? false,
    sourceLabel: j['sourceLabel']?.toString() ?? MealResultSource.aiEstimate.code,
    barcode: j['barcode']?.toString(),
    brand: j['brand']?.toString(),
    // Missing key -> false: the 0 of an old row stays a sentinel.
    explicitZeroKcal: (j['explicitZeroKcal'] as bool?) ?? false,
  );
}
