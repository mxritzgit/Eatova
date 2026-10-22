import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/planned_meal.dart';
import 'package:eatova/src/models/recipe_pick.dart';
import 'package:eatova/src/models/recipe_shelf.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/widgets/common/app_snack.dart';

// Review 2026-10-19 (P1): whoever avoids fish must not get salmon as
// tonight's pick. Today's pick, the Food row and the Recipes hero share
// `pickRecipeForSlot`; the lean shelf has its own filter. Both must drop every
// catalog recipe that contains an avoided food, for every code.

final _day = DateTime(2026, 10, 19);

/// Breakfast, lunch and dinner time of [_day].
final _slotTimes = <MealSlot, DateTime>{
  MealSlot.breakfast: DateTime(2026, 10, 19, 7),
  MealSlot.lunch: DateTime(2026, 10, 19, 12),
  MealSlot.dinner: DateTime(2026, 10, 19, 18, 30),
};

void _noopSnack(
  String message, {
  IconData icon = Icons.info_outline,
  SnackTone tone = SnackTone.positive,
  Duration? duration,
  SnackBarAction? action,
}) {}

void main() {
  group('pickRecipeForSlot', () {
    test('kein Vorschlag enthält, was gemieden wird — jeder Code, jede '
        'Mahlzeit, beide Kataloge', () {
      // Proves the cases bite: without the filter the pick contains the code.
      final bitten = <FoodAvoidance>{};
      for (final catalog in [recipeCatalogDe, recipeCatalogEn]) {
        for (final code in FoodAvoidance.values) {
          for (final MapEntry(key: slot, value: time) in _slotTimes.entries) {
            for (final kcal in [450, 500, 650, 900, 2100]) {
              final pick = pickRecipeForSlot(
                slot: slot,
                day: time,
                remainingKcal: kcal,
                recipes: catalog,
                avoidances: {code},
              );
              expect(
                pick == null || pick.recipe.fitsAvoidances({code}),
                isTrue,
                reason:
                    '${code.name}, ${slot.name}, $kcal kcal: '
                    '${pick?.recipe.slug} enthält es',
              );
              final unfiltered = pickRecipeForSlot(
                slot: slot,
                day: time,
                remainingKcal: kcal,
                recipes: catalog,
              );
              if (unfiltered != null &&
                  !unfiltered.recipe.fitsAvoidances({code})) {
                bitten.add(code);
              }
            }
          }
        }
      }
      expect(
        bitten,
        containsAll([
          FoodAvoidance.lactose,
          FoodAvoidance.gluten,
          FoodAvoidance.nuts,
          FoodAvoidance.fish,
        ]),
        reason: 'ohne Filter hätten diese Codes einen Treffer geliefert',
      );
    });

    test('mehrere Codes zusammen und mit Ernährungsform', () {
      const avoided = {
        FoodAvoidance.gluten,
        FoodAvoidance.soy,
        FoodAvoidance.sesame,
      };
      final pick = pickRecipeForSlot(
        slot: MealSlot.dinner,
        day: _slotTimes[MealSlot.dinner]!,
        remainingKcal: 900,
        recipes: recipeCatalogDe,
        diet: DietPreference.vegan,
        avoidances: avoided,
      )!;
      expect(pick.recipe.matchesDiet(DietPreference.vegan), isTrue);
      expect(pick.recipe.fitsAvoidances(avoided), isTrue);
      // Tofu (35 g) and tempeh (34 g) would win without the filter.
      expect(pick.recipe.slug, 'linsen_dal_mit_reis');
    });

    test('wer Nüsse meidet, bekommt morgens nie die Skyr-Bowl', () {
      const skyrBowl = 'skyr_bowl_mit_beeren_and_granola';
      String pick(DateTime day, Set<FoodAvoidance> avoided) =>
          pickRecipeForNextMeal(
            now: day,
            todaysMeals: const [],
            remainingKcal: 2100,
            recipes: recipeCatalogDe,
            avoidances: avoided,
          )!.recipe.slug;
      // The breakfast pick rotates by day; over a week it is the skyr bowl
      // at least once, never for someone who avoids nuts.
      final week = [
        for (var i = 0; i < 7; i++)
          _slotTimes[MealSlot.breakfast]!.add(Duration(days: i)),
      ];
      expect(week.map((day) => pick(day, const {})), contains(skyrBowl));
      for (final day in week) {
        expect(pick(day, const {FoodAvoidance.nuts}), isNot(skyrBowl));
      }
    });

    test('jede Ernährungsform und jedes gemiedene Lebensmittel lässt ein '
        'Frühstück übrig, beide Kataloge', () {
      for (final catalog in [recipeCatalogDe, recipeCatalogEn]) {
        for (final diet in DietPreference.values) {
          for (final avoided in [
            for (final code in FoodAvoidance.values) {code},
            FoodAvoidance.values.toSet(),
          ]) {
            final pick = pickRecipeForSlot(
              slot: MealSlot.breakfast,
              day: _slotTimes[MealSlot.breakfast]!,
              remainingKcal: 2100,
              recipes: catalog,
              diet: diet,
              avoidances: avoided,
            );
            expect(pick, isNotNull, reason: '${diet.name}, $avoided');
          }
        }
      }
    });

    test('ein geplantes Gericht bleibt die Wahl des Nutzers, auch mit '
        'gemiedenem Inhalt', () {
      final lachs = recipeCatalogDe.firstWhere(
        (r) => r.slug == 'lachs_mit_sukartoffel_and_spargel',
      );
      final plan = PlannedMeal.create(
        recipe: lachs,
        day: _day,
        slot: MealSlot.dinner,
      );
      final pick = pickRecipeForSlot(
        slot: MealSlot.dinner,
        day: _slotTimes[MealSlot.dinner]!,
        remainingKcal: 900,
        recipes: recipeCatalogDe,
        avoidances: const {FoodAvoidance.fish},
        plannedMeals: [plan],
      )!;
      expect(pick.source, RecipePickSource.planned);
      expect(pick.recipe.slug, lachs.slug);
    });

    test('eigene Rezepte bleiben im Pool, auch wenn ihr Text Fisch nennt', () {
      const own = FitnessRecipe(
        slug: 'user_lachs',
        title: 'Mein Lachs',
        description: '',
        portion: '',
        ingredients: '200 g Lachs',
        preparation: '',
        professionalHint: '',
        imageAsset: '',
        caloriesKcal: 600,
        proteinG: 90,
        carbsG: 10,
        fatG: 20,
        estimatedGrams: 300,
        categories: ['Eigene'],
        userCreated: true,
      );
      final pick = pickRecipeForSlot(
        slot: MealSlot.dinner,
        day: _slotTimes[MealSlot.dinner]!,
        remainingKcal: 900,
        recipes: [own, ...recipeCatalogDe],
        avoidances: const {FoodAvoidance.fish},
      )!;
      expect(pick.recipe.slug, own.slug);
    });
  });

  group('Regal „Viel Protein, unter 500 kcal"', () {
    test('lässt jedes Rezept mit gemiedenem Inhalt weg', () {
      for (final code in FoodAvoidance.values) {
        final shelf = leanHighProteinShelf(
          recipeCatalogDe,
          now: _day,
          avoidances: {code},
          count: 30,
        );
        for (final recipe in shelf) {
          expect(
            recipe.fitsAvoidances({code}),
            isTrue,
            reason: '${code.name}: ${recipe.slug}',
          );
        }
      }
      final all = leanHighProteinRecipes(recipeCatalogDe);
      expect(
        all.map((r) => r.slug),
        contains('skyr_bowl_mit_beeren_and_granola'),
        reason: 'Vorbedingung: ohne Filter steht die Skyr-Bowl im Regal',
      );
      expect(
        leanHighProteinRecipes(
          recipeCatalogDe,
          avoidances: const {FoodAvoidance.lactose},
        ).map((r) => r.slug),
        isNot(contains('skyr_bowl_mit_beeren_and_granola')),
      );
    });
  });

  test('HomeStore.nextMealPick liest die gemiedenen Lebensmittel aus dem '
      'Profil', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    withClock(Clock.fixed(_slotTimes[MealSlot.breakfast]!), () {
      final store = HomeStore(
        sync: null,
        health: const NoopHealthService(),
        notificationService: const NoopNotificationService(),
        initialUserName: 'Moritz',
        emitSnack: _noopSnack,
      );
      addTearDown(store.dispose);
      // Until 2026-10-22 every catalog breakfast had dairy, and avoiding
      // lactose left no pick at all; now a dairy-free one is offered.
      for (final avoided in const <Set<FoodAvoidance>>[
        {},
        {FoodAvoidance.nuts, FoodAvoidance.egg},
        {FoodAvoidance.lactose},
      ]) {
        store.profile = UserProfile(
          dailyKcalGoal: 2100,
          foodAvoidances: avoided,
        );
        final pick = store.nextMealPick(localeName: 'de');
        expect(pick, isNotNull, reason: '$avoided');
        expect(pick!.slot, MealSlot.breakfast);
        expect(pick.recipe.fitsAvoidances(avoided), isTrue, reason: '$avoided');
      }
    });
  });
}
