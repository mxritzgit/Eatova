import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/lifetime_stats.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/macro_progress.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/meal_component.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/services/food_kcal_db.dart';
import 'package:eatova/src/services/kcal_calculator.dart';
import 'package:eatova/src/services/meals_sync.dart';

// Reine Logik-Tests für bislang ungetestete, geld-/datenkritische Funktionen
// (Slot-Heuristik, Streak, Makro-Aggregation, JSON-Roundtrip der Food-History,
// Auto-Split, Makro-Aufteilung). Alle deterministisch, netz-/UI-frei.

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
  group('LoggedMeal.slot Heuristik (Uhrzeit-Fallback)', () {
    LoggedMeal at(int hour) => LoggedMeal(
          id: 'x',
          result: _result(),
          loggedAt: DateTime(2026, 6, 2, hour, 30),
        );

    test('vor 11 Uhr -> Frühstück', () {
      expect(at(0).slot, MealSlot.breakfast);
      expect(at(10).slot, MealSlot.breakfast);
    });
    test('11-15 Uhr -> Mittag', () {
      expect(at(11).slot, MealSlot.lunch);
      expect(at(14).slot, MealSlot.lunch);
    });
    test('15-21 Uhr -> Abend', () {
      expect(at(15).slot, MealSlot.dinner);
      expect(at(20).slot, MealSlot.dinner);
    });
    test('ab 21 Uhr -> Snack', () {
      expect(at(21).slot, MealSlot.snack);
      expect(at(23).slot, MealSlot.snack);
    });
    test('forcedSlot hat Vorrang vor der Uhrzeit', () {
      final m = LoggedMeal(
        id: 'x',
        result: _result(),
        loggedAt: DateTime(2026, 6, 2, 23, 0), // wäre snack
        forcedSlot: MealSlot.breakfast,
      );
      expect(m.slot, MealSlot.breakfast);
    });
  });

  group('LifetimeStats.recordTrackedDay (Logging-Streak)', () {
    final day1 = DateTime(2026, 6, 1);
    final day2 = DateTime(2026, 6, 2);
    final day4 = DateTime(2026, 6, 4);

    test('erster Log-Tag -> Streak 1', () {
      final s = LifetimeStats().recordTrackedDay(day1);
      expect(s.currentStreak, 1);
      expect(s.longestStreak, 1);
    });
    test('gestern -> +1', () {
      final s = LifetimeStats().recordTrackedDay(day1).recordTrackedDay(day2);
      expect(s.currentStreak, 2);
      expect(s.longestStreak, 2);
    });
    test('selber Tag erneut -> idempotent (kein Doppel-Zählen)', () {
      final s = LifetimeStats().recordTrackedDay(day1).recordTrackedDay(day1);
      expect(s.currentStreak, 1);
    });
    test('Lücke ≥ 1 Tag -> Reset auf 1, longestStreak bleibt', () {
      final s = LifetimeStats()
          .recordTrackedDay(day1)
          .recordTrackedDay(day2) // Streak 2
          .recordTrackedDay(day4); // Lücke (day3 fehlt)
      expect(s.currentStreak, 1);
      expect(s.longestStreak, 2);
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
        'workouts_completed': '5', // String statt int
        'meals_logged': null,
      });
      expect(back.workoutsCompleted, 5);
      expect(back.mealsLogged, 0);
      expect(back.currentStreak, 0);
      expect(back.lastTrackedDate, isNull);
    });
  });

  group('MacroProgress add/subtract', () {
    test('add summiert Makros + kcal aus den Ergebnis-Strings', () {
      final p = MacroProgress.empty.add(_result(
        kcal: 500,
        protein: '30 g',
        carbs: '50 g',
        fat: '20 g',
      ));
      expect(p.proteinG, 30);
      expect(p.carbsG, 50);
      expect(p.fatG, 20);
      expect(p.kcal, 500);
    });
    test('add parst Komma-Dezimalzahlen', () {
      final p = MacroProgress.empty.add(_result(protein: '12,5 g'));
      expect(p.proteinG, closeTo(12.5, 0.001));
    });
    test('subtract clampt nicht unter 0', () {
      final p = MacroProgress.empty.subtract(_result(
        kcal: 500,
        protein: '30 g',
      ));
      expect(p.proteinG, 0);
      expect(p.kcal, 0);
    });
    test('add dann subtract gleicht sich aus', () {
      final r = _result(kcal: 400, protein: '25 g', carbs: '40 g', fat: '15 g');
      final p = MacroProgress.empty.add(r).subtract(r);
      expect(p.proteinG, 0);
      expect(p.carbsG, 0);
      expect(p.fatG, 0);
      expect(p.kcal, 0);
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
    test('leeres/teilbefülltes JSON fällt auf sichere Defaults', () {
      final back = mealResultFromJson(<String, dynamic>{});
      expect(back.mealName, 'Mahlzeit');
      expect(back.caloriesKcal, 0);
      expect(back.items, isEmpty);
      expect(back.sourceLabel, 'KI-Schätzung');
    });
  });

  group('food_kcal_db splitMealName / autoSplitItems', () {
    test('splitMealName trennt an mit/und/&/+ und filtert Füllwörter', () {
      expect(splitMealName('Hähnchen mit Reis und Brokkoli'),
          ['Hähnchen', 'Reis', 'Brokkoli']);
      expect(splitMealName('Lachs & Spargel + Kartoffeln auf einem Teller'),
          contains('Lachs'));
      expect(splitMealName('Pizza'), ['Pizza']); // nicht teilbar
    });
    test('autoSplitItems erhält die kcal-Summe der KI', () {
      final items = autoSplitItems(
        mealName: 'Hähnchen mit Reis und Brokkoli',
        totalGrams: 600,
        totalKcal: 700,
      );
      expect(items.length, 3);
      final kcalSum = items.fold<int>(0, (s, c) => s + c.caloriesKcal);
      // Rundung pro Posten -> Summe nahe am Ziel.
      expect(kcalSum, closeTo(700, 3));
      final gramSum = items.fold<int>(0, (s, c) => s + c.grams);
      expect(gramSum, closeTo(600, 3));
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
      expect(fromMacros, closeTo(t.kcal, 60)); // Rundungstoleranz
    });
  });
}
