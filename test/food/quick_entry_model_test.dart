// E4: a quick entry stores totals without a weight (0 g, no density). Every
// gram path must keep its calories: re-portioning a 0 g meal used to drop
// them to the 0 sentinel (fixed for items in #151; must not come back here).

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/export_document.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/meal_component.dart';
import 'package:eatova/src/models/persisted_labels.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/meals_sync.dart'
    show mealResultFromJson, mealResultToJson;
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/widgets/common/app_snack.dart';
import 'package:eatova/src/widgets/kcal/diary_meal_card.dart'
    show diaryAmountLabel;
import 'package:eatova/src/widgets/kcal/meal_analysis_sheet.dart'
    show mealPortionAdjustment;
import 'package:eatova/src/widgets/shared/export_sections.dart';

MealAnalysisResult _pizza({String name = 'Pizza Diavola'}) =>
    MealAnalysisResult.quickEntry(
      name: name,
      caloriesKcal: 1150,
      proteinG: 45,
      carbsG: 120.5,
      fatG: null,
    );

void _noopSnack(
  String message, {
  IconData icon = Icons.info_outline,
  SnackTone tone = SnackTone.positive,
  Duration? duration,
  SnackBarAction? action,
}) {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Werte', () {
    test('speichert Gesamtwerte ohne Gramm und ohne Dichte', () {
      final r = _pizza();
      expect(r.mealName, 'Pizza Diavola');
      expect(r.caloriesKcal, 1150);
      expect(r.estimatedGrams, 0);
      expect(r.kcalPer100G, 0);
      expect(r.protein, '45 g');
      expect(r.carbs, '120,5 g');
      expect(r.fat, '-', reason: 'leer heisst unbekannt, nicht 0');
      expect(r.sourceLabel, MealResultSource.manual.code);
      expect(r.portionNotes, MealResultPortionNote.quick.code);
      expect(r.isQuickEntry, isTrue);
      expect(r.hasNoPortionWeight, isTrue);
      expect(r.isOwnProduct, isFalse);
      expect(r.explicitZeroKcal, isFalse);
    });

    test('ohne Namen traegt er den Standard, je Sprache aufgeloest', () {
      final r = _pizza(name: '   ');
      expect(r.mealName, PersistedLabels.quickEntryName);
      expect(r.resolvedMealName(deL10n), 'Schnell-Eintrag');
      expect(r.resolvedMealName(enL10n), 'Quick entry');
      // A typed name passes through untouched.
      expect(_pizza().resolvedMealName(enL10n), 'Pizza Diavola');
    });

    test('0 kcal ist eine Angabe, kein unbekannter Wert', () {
      final r = MealAnalysisResult.quickEntry(name: 'Kaffee', caloriesKcal: 0);
      expect(r.explicitZeroKcal, isTrue);
    });

    test('die Per-100-g-Eingabe ist nie ein Schnell-Eintrag', () {
      final r = MealAnalysisResult.manualEntry(
        name: 'Quark',
        kcalPer100G: 67,
        grams: 250,
      );
      expect(r.isQuickEntry, isFalse);
      expect(r.hasNoPortionWeight, isFalse);
    });
  });

  group('Umportionieren', () {
    test('Gramm aendern behaelt die Kalorien (kein 0-Sentinel)', () {
      final r = _pizza();
      for (final grams in [1, 100, 350, 10000]) {
        final adjusted = r.adjustedToGrams(grams);
        expect(adjusted.caloriesKcal, 1150, reason: '$grams g');
        expect(adjusted.protein, '45 g');
      }
    });

    test('das Bestandteile-Blatt wendet auf ihn nichts an', () {
      final r = _pizza();
      final adjustment = mealPortionAdjustment(r, [
        const MealComponent(
          name: 'Pizza Diavola',
          grams: 200,
          caloriesKcal: 10,
          kcalPer100G: 5,
        ),
      ]);
      expect(adjustment, isNull);
    });

    test('Speicher-Rundreise bleibt ein Schnell-Eintrag', () {
      final back = mealResultFromJson(mealResultToJson(_pizza()));
      expect(back.isQuickEntry, isTrue);
      expect(back.caloriesKcal, 1150);
      expect(back.adjustedToGrams(400).caloriesKcal, 1150);
    });

    test('Portionen rechnen Gesamtwerte um und reisen im Payload mit', () {
      final half = _pizza().withServings(1.5);
      expect(half.caloriesKcal, 1725);
      expect(half.protein, '67,5 g');
      expect(half.fat, '-', reason: 'unbekannt bleibt unbekannt');
      expect(half.isQuickEntry, isTrue);

      final back = mealResultFromJson(mealResultToJson(half));
      expect(back.servings, 1.5);
      expect(back.withServings(1).caloriesKcal, 1150);
      // Rows without the field read as one serving.
      expect(mealResultFromJson(mealResultToJson(_pizza())).servings, isNull);
    });
  });

  group('Darstellung', () {
    test('das Tagebuch zeigt die Portionen statt 0 g', () {
      // A recipe logged before the field existed: its note names the count.
      final legacyRecipe = MealAnalysisResult(
        mealName: 'Bowl',
        caloriesKcal: 700,
        estimatedGrams: 0,
        kcalPer100G: 0,
        protein: '-',
        carbs: '-',
        fat: '-',
        confidence: 'recipe',
        portionNotes: '2 Portionen · Eine Bowl.',
        sourceLabel: MealResultSource.recipe.code,
      );
      for (final (result, de, en) in [
        (_pizza(), '1 Portion', '1 portion'),
        (_pizza().withServings(1.5), '1,5 Portionen', '1.5 portions'),
        (legacyRecipe, '2 Portionen', '2 portions'),
      ]) {
        expect(diaryAmountLabel(result, deL10n), de);
        expect(diaryAmountLabel(result, enL10n), en);
      }
    });

    test('der Export loest Name, Notiz, Herkunft und Makros auf', () {
      final row = <String, dynamic>{
        'id': 'm1',
        'meal_name': PersistedLabels.quickEntryName,
        'payload': mealResultToJson(_pizza(name: '')),
      };
      final fields = exportFields(row);
      String readable(String path) =>
          exportReadableValue(fields, path, fields[path], enL10n);

      expect(readable('/payload/mealName'), 'Quick entry');
      expect(readable('/meal_name'), 'Quick entry');
      expect(readable('/payload/portionNotes'), enL10n.foodQuickEntryNote);
      expect(readable('/payload/sourceLabel'), 'Manual');
      expect(readable('/payload/carbs'), '120.5 g');
      expect(fields['/payload/estimatedGrams'], 0);
      expect(fields['/payload/caloriesKcal'], 1150);
    });
  });

  test('Store: Eintragen, Umportionieren und Tagessumme', () async {
    await withClock(Clock.fixed(DateTime(2026, 10, 18, 19)), () async {
      final store = HomeStore(
        sync: null,
        health: const NoopHealthService(),
        notificationService: const NoopNotificationService(),
        initialUserName: 'Test',
        emitSnack: _noopSnack,
      );
      addTearDown(store.dispose);

      final id = await store.addResultToDailyTotal(_pizza());
      expect(store.dailyConsumedKcal, 1150);

      // What the analysis/edit paths hand back after a gram change.
      final logged = store.loggedMeals.single;
      await store.updateLoggedMealResult(
        id,
        logged.result.adjustedToGrams(300),
      );
      expect(store.loggedMeals.single.result.caloriesKcal, 1150);
      expect(store.dailyConsumedKcal, 1150);
      expect(store.macroProgress.proteinG, 45);
    });
  });
}
