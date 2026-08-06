import 'dart:developer' as dev;

import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/favorite_meal.dart';
import '../models/logged_meal.dart';
import '../models/meal_analysis_result.dart';
import '../models/meal_component.dart';

/// Liest und schreibt LoggedMeal + FavoriteMeal gegen public.logged_meals
/// und public.favorite_meals. MealAnalysisResult wandert als JSONB-
/// Payload, plus ein paar denormalisierte Spalten fuer schnelle Filter
/// (calories_kcal, barcode, brand). Eine Instanz gehoert einem user_id.
class MealsSync {
  MealsSync(this._client, this._userId);

  final SupabaseClient _client;
  final String _userId;

  /// Boot-Fenster fuer das Tagebuch (Tage zurueck ab jetzt). Die UI zeigt
  /// maximal ~5 Tage Historie (Datums-Chips, visiblePastDays in
  /// meal_analysis_screen.dart); Streak-/Lifetime-Zahlen kommen serverseitig
  /// aus lifetime_stats bzw. record_tracking_day — NICHT aus dieser Liste.
  /// 35 Tage liegen also grosszuegig ueber dem UI-Bedarf. Ohne Fenster lud
  /// jeder Kaltstart ALLE jemals geloggten Mahlzeiten inkl. JSONB-Payload.
  static const int loggedMealsWindowDays = 35;

  /// Defensiver Zeilen-Deckel obendrauf (~28 Logs/Tag im Fenster): PostgREST
  /// kappt bei gesetztem db-max-rows STILL — mit explizitem Limit ist die
  /// Obergrenze stattdessen deterministisch und dank order desc verschwinden
  /// hoechstens die AELTESTEN Eintraege des Fensters, nie aktuelle.
  static const int loggedMealsMaxRows = 1000;

  /// Favoriten-Deckel: client-seitig existieren ohnehin nur 5 Auto-Recents
  /// plus angeheftete Favoriten (home_store._cappedFavorites) — 200 liegt
  /// weit ueber jedem realistischen Pin-Bestand.
  static const int favoritesLimit = 200;

  // ---------- logged_meals ----------

  Future<List<LoggedMeal>> loadLoggedMeals() async {
    try {
      // Fenster auf logged_at (timestamptz, Index user_id+logged_at desc) statt
      // local_day: aeltere Zeilen koennen local_day=null tragen und wuerden bei
      // einem local_day-Filter kommentarlos fehlen.
      final cutoffIso = DateTime.now()
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
      return rows.map<LoggedMeal>((row) {
        return LoggedMeal(
          id: row['id'] as String,
          loggedAt: DateTime.parse(row['logged_at'] as String).toLocal(),
          forcedSlot: _parseSlot(row['forced_slot']?.toString()),
          // DATA-6: kanonischen lokalen Tages-Schluessel mitfuehren wenn die
          // Zeile ihn hat. Aeltere Zeilen ohne Spalte/null -> Bucketing faellt
          // auf isSameDay(.toLocal()) zurueck (siehe meal_totals).
          localDay: row['local_day']?.toString(),
          result: mealResultFromJson(
            (row['payload'] as Map).cast<String, dynamic>(),
          ),
        );
      }).toList();
    } catch (e, stack) {
      dev.log('MealsSync.loadLoggedMeals failed',
          error: e, stackTrace: stack, name: 'meals_sync');
      rethrow;
    }
  }

  Future<void> insertLoggedMeal(LoggedMeal meal) async {
    try {
      // Upsert auf der Client-UUID statt insert: ein Retry nach einem
      // unklaren Netzwerk-Timeout (Antwort verloren, Zeile aber geschrieben)
      // erzeugt so keinen Duplikat-Fehler, sondern bleibt idempotent.
      await _client.from('logged_meals').upsert({
        'id': meal.id,
        'user_id': _userId,
        'logged_at': meal.loggedAt.toUtc().toIso8601String(),
        // DATA-6: kanonischer lokaler Tages-Schluessel aus der LOKALEN Wanduhr
        // des Eintrags. Additiv — wird aus loggedAt berechnet wenn die
        // home_page-Konstruktion ihn (noch) nicht setzt, sodass Koffein und
        // Mahlzeiten denselben Tag teilen (kein UTC-Drift ueber DST/Zone).
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
          // Aeltere Zeilen ohne Spalte / null -> false (Auto-Recent).
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

/// Serialisiert MealAnalysisResult fuer JSONB-Spalten und liest sie
/// roundtrip-sicher zurueck. Bewusst hier statt im Model, damit der
/// Persistence-Aspekt nicht ins Domain-Modell leakt.
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
            })
        .toList(),
    'isAdjusted': r.isAdjusted,
    'sourceLabel': r.sourceLabel,
    if (r.barcode != null) 'barcode': r.barcode,
    if (r.brand != null) 'brand': r.brand,
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
            );
          })
          .toList()
      : const <MealComponent>[];
  return MealAnalysisResult(
    mealName: j['mealName']?.toString() ?? 'Mahlzeit',
    caloriesKcal: (j['caloriesKcal'] as num?)?.toInt() ?? 0,
    estimatedGrams: (j['estimatedGrams'] as num?)?.toInt() ?? 0,
    kcalPer100G: (j['kcalPer100G'] as num?)?.toDouble() ?? 0.0,
    protein: j['protein']?.toString() ?? '-',
    carbs: j['carbs']?.toString() ?? '-',
    fat: j['fat']?.toString() ?? '-',
    confidence: j['confidence']?.toString() ?? 'Mittel',
    portionNotes: j['portionNotes']?.toString() ?? '',
    items: items,
    isAdjusted: (j['isAdjusted'] as bool?) ?? false,
    sourceLabel: j['sourceLabel']?.toString() ?? 'KI-Schätzung',
    barcode: j['barcode']?.toString(),
    brand: j['brand']?.toString(),
  );
}
