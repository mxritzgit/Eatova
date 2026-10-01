import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/lifetime_stats.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/meal_component.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/services/food_kcal_db.dart';
import 'package:eatova/src/services/kcal_calculator.dart';
import 'package:eatova/src/services/meals_sync.dart';

// Pure logic tests for money- and data-critical functions (first streak day,
// stats rows, food-history JSON roundtrip, auto split, macro split).
// Deterministic, no network or UI. The slot heuristic, the running streak and
// the macro aggregation live in test/models/logged_meal_slot_test.dart,
// lifetime_stats_test.dart and macro_progress_test.dart.

MealAnalysisResult _result({
  String name = 'Testmahlzeit',
  int kcal = 500,
  int grams = 300,
  String protein = '30 g',
  String carbs = '50 g',
  String fat = '20 g',
  List<MealComponent> items = const <MealComponent>[],
  String? barcode,
  String? brand,
}) {
  return MealAnalysisResult(
    mealName: name,
    caloriesKcal: kcal,
    estimatedGrams: grams,
    kcalPer100G: grams > 0 ? kcal * 100 / grams : 0,
    protein: protein,
    carbs: carbs,
    fat: fat,
    confidence: 'Hoch',
    portionNotes: 'Notiz',
    items: items,
    barcode: barcode,
    brand: brand,
  );
}

void main() {
  group('LifetimeStats.recordTrackedDay (Logging-Streak)', () {
    final day1 = DateTime(2026, 6, 1);
    final day2 = DateTime(2026, 6, 2);

    test('erster Log-Tag -> Streak 1', () {
      final s = LifetimeStats().recordTrackedDay(day1);
      expect(s.currentStreak, 1);
      expect(s.longestStreak, 1);
    });
    test('toRow/fromRow Roundtrip erhält Zähler + Streak', () {
      final s = LifetimeStats(
        workoutsCompleted: 7,
        mealsLogged: 42,
        waterTotalMl: 12000,
        currentStreak: 3,
        longestStreak: 9,
        lastTrackedDate: day2,
      );
      final back = LifetimeStats.fromRow(s.toRow());
      expect(back.workoutsCompleted, 7);
      expect(back.mealsLogged, 42);
      expect(back.waterTotalMl, 12000);
      expect(back.currentStreak, 3);
      expect(back.longestStreak, 9);
      expect(back.lastTrackedDate, day2);
    });
    test('fromRow ist defensiv bei fehlenden/falschen Spalten', () {
      final back = LifetimeStats.fromRow(<String, dynamic>{
        'workouts_completed': '5', // string instead of int
        'meals_logged': null,
      });
      expect(back.workoutsCompleted, 5);
      expect(back.mealsLogged, 0);
      expect(back.currentStreak, 0);
      expect(back.lastTrackedDate, isNull);
    });
  });

  group('mealResultToJson/fromJson Roundtrip (Food-History-Persistenz)', () {
    test('vollständiges Ergebnis inkl. items/barcode/brand übersteht den Trip', () {
      final r = _result(
        name: 'Pizza Salami',
        kcal: 820,
        grams: 350,
        protein: '32 g',
        carbs: '90 g',
        fat: '34 g',
        barcode: '4001234567890',
        brand: 'Dr. Oetker',
        items: const [
          MealComponent(
              name: 'Teig', grams: 200, caloriesKcal: 500, kcalPer100G: 250),
          MealComponent(
              name: 'Salami', grams: 150, caloriesKcal: 320, kcalPer100G: 213),
        ],
      );
      final back = mealResultFromJson(mealResultToJson(r));
      expect(back.mealName, 'Pizza Salami');
      expect(back.caloriesKcal, 820);
      expect(back.estimatedGrams, 350);
      expect(back.protein, '32 g');
      expect(back.barcode, '4001234567890');
      expect(back.brand, 'Dr. Oetker');
      expect(back.items.length, 2);
      expect(back.items.first.name, 'Teig');
      expect(back.items.first.grams, 200);
      expect(back.items[1].caloriesKcal, 320);
    });
    test('leeres JSON ist KORRUPT und wirft (Sentinel-Rest S1)', () {
      // "Safe defaults" would not be safe: an invented 0 kcal meal without
      // explicitZeroKcal enters the daily total and reaches the server as
      // calories_kcal: 0. mealResultToJson always writes caloriesKcal, so a
      // payload without the key is broken.
      expect(() => mealResultFromJson(<String, dynamic>{}),
          throwsFormatException);
    });

    test('teilbefuelltes JSON (caloriesKcal vorhanden) behaelt Label-Defaults',
        () {
      final back = mealResultFromJson(<String, dynamic>{'caloriesKcal': 300});
      expect(back.mealName, 'Mahlzeit');
      expect(back.caloriesKcal, 300);
      expect(back.items, isEmpty);
      // The fallback for a missing sourceLabel is the language-neutral code,
      // not a German display string (see MealResultSource docs).
      expect(back.sourceLabel, 'aiEstimate');
      expect(back.resolvedSourceLabel(deL10n), 'KI-Schätzung');
      expect(back.resolvedSourceLabel(enL10n), 'AI estimate');
    });
  });

  group('food_kcal_db splitMealName / autoSplitItems', () {
    test('splitMealName trennt an mit/und/&/+ und filtert Füllwörter', () {
      expect(splitMealName('Hähnchen mit Reis und Brokkoli'),
          ['Hähnchen', 'Reis', 'Brokkoli']);
      expect(splitMealName('Lachs & Spargel + Kartoffeln auf einem Teller'),
          contains('Lachs'));
      expect(splitMealName('Pizza'), ['Pizza']); // not splittable
    });
    test('autoSplitItems erhält die kcal-Summe der KI', () {
      final items = autoSplitItems(
        mealName: 'Hähnchen mit Reis und Brokkoli',
        totalGrams: 600,
        totalKcal: 700,
      );
      expect(items.length, 3);
      final kcalSum = items.fold<int>(0, (s, c) => s + c.caloriesKcal);
      // EXACT, not close: autoSplitItems spreads the rounding remainder over
      // the items (_spreadRemainder), so both totals land on the anchor. A
      // tolerance here would wave that drift straight back through.
      expect(kcalSum, 700);
      final gramSum = items.fold<int>(0, (s, c) => s + c.grams);
      expect(gramSum, 600);
    });
    test('autoSplitItems gibt [] zurück wenn nicht teilbar', () {
      expect(
        autoSplitItems(mealName: 'Apfel', totalGrams: 120, totalKcal: 62),
        isEmpty,
      );
    });
  });

  group('KcalCalculator Makro-Aufteilung', () {
    const calc = KcalCalculator();

    test('Protein = 1.6 g/kg Körpergewicht', () {
      const base = UserProfile(); // 78 kg
      final t = calc.calculate(base);
      expect(t.proteinG, (78 * 1.6).round()); // 125
    });
    test('Makros sind positiv und gehen ungefähr im kcal-Ziel auf', () {
      const base = UserProfile();
      final t = calc.calculate(base);
      expect(t.proteinG, greaterThan(0));
      expect(t.carbsG, greaterThan(0));
      expect(t.fatG, greaterThan(0));
      final fromMacros = t.proteinG * 4 + t.carbsG * 4 + t.fatG * 9;
      expect(fromMacros, closeTo(t.kcal, 60)); // rounding tolerance
    });
  });
}
