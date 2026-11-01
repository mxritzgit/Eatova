import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/planned_meal.dart';
import 'package:eatova/src/models/recipe_pick.dart' show recipeSuitsSlot;
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/models/week_plan_suggestion.dart';
import 'package:eatova/src/services/local_day.dart';

// "Woche vorschlagen" (2026-11-01): a deterministic week plan without AI.
// Fitting recipes only, existing entries untouched, no dish twice a day,
// repeats only where the pool is too small, empty slots instead of forced
// ones, the same plan for the same input.

/// Monday, 2 November 2026, to Sunday.
final _week = [for (var i = 0; i < 7; i++) DateTime(2026, 11, 2 + i)];
const _threeMeals = {MealSlot.breakfast, MealSlot.lunch, MealSlot.dinner};

WeekPlanSuggestion _suggest({
  DietPreference diet = DietPreference.none,
  Set<FoodAvoidance> avoid = const {},
  String dislikes = '',
  int goal = 2100,
  Set<MealSlot> slots = _threeMeals,
  List<FitnessRecipe>? recipes,
  List<PlannedMeal> existing = const [],
  Set<WeekPlanSlot> skipped = const {},
  int seed = 0,
}) => suggestWeekPlan(
  days: _week,
  slots: slots,
  profile: UserProfile(
    diet: diet,
    foodAvoidances: avoid,
    foodDislikes: dislikes,
    dailyKcalGoal: goal,
  ),
  recipes: recipes ?? recipeCatalogDe,
  existing: existing,
  skipped: skipped,
  seed: seed,
);

List<String> _signature(WeekPlanSuggestion plan) => [
  for (final m in plan.meals) '${m.day} ${m.slot.name} ${m.recipe.slug} ${m.servings}',
];

FitnessRecipe _catalog(String slug) =>
    recipeCatalogDe.firstWhere((r) => r.slug == slug);

FitnessRecipe _own(String slug) => FitnessRecipe(
  slug: slug,
  title: 'Eigene $slug',
  description: '',
  portion: '1 Teller',
  ingredients: 'Reis',
  preparation: '',
  professionalHint: '',
  imageAsset: '',
  caloriesKcal: 600,
  proteinG: 40,
  carbsG: 60,
  fatG: 15,
  estimatedGrams: 400,
  categories: const ['Eigene'],
  userCreated: true,
);

void main() {
  test('Gemiedenes, Ernährungsform und Abneigungen kommen nie in den Plan; '
      'kein Gericht zweimal am Tag, Wiederholungen nur wo nötig, jeder volle '
      'Tag im Zielband', () {
    final avoidSets = <Set<FoodAvoidance>>[
      {},
      for (final food in FoodAvoidance.values) {food},
      {FoodAvoidance.lactose, FoodAvoidance.gluten},
      {FoodAvoidance.gluten, FoodAvoidance.soy},
    ];
    for (final diet in DietPreference.values) {
      for (final avoid in avoidSets) {
        for (final (goal, slots) in [
          (1400, _threeMeals),
          (3000, MealSlot.values.toSet()),
        ]) {
          final row = '${diet.name} ohne ${avoid.map((a) => a.name)} $goal kcal '
              '${slots.length} Slots';
          final plan = _suggest(
            diet: diet,
            avoid: avoid,
            dislikes: 'Lachs, Quinoa',
            goal: goal,
            slots: slots,
          );
          expect(plan.meals, isNotEmpty, reason: row);
          final perPool = <WeekPlanPool, Map<String, int>>{};
          for (final m in plan.meals) {
            final text = foldRecipeSearchText(
              '${m.recipe.title} ${m.recipe.ingredients}',
            );
            expect(m.recipe.matchesDiet(diet), isTrue, reason: row);
            expect(m.recipe.fitsAvoidances(avoid), isTrue, reason: row);
            expect(text.contains('lachs') || text.contains('quinoa'), isFalse,
                reason: '$row: ${m.recipe.slug}');
            expect(recipeSuitsSlot(m.recipe, m.slot), isTrue, reason: row);
            expect(weekPlanServingSteps, contains(m.servings), reason: row);
            perPool
                .putIfAbsent(weekPlanPoolOf(m.slot), () => {})
                .update(m.recipe.slug, (n) => n + 1, ifAbsent: () => 1);
          }
          for (final day in _week.map(localDayKey)) {
            final slugs = [
              for (final m in plan.meals)
                if (m.day == day) m.recipe.slug,
            ];
            expect(slugs.toSet(), hasLength(slugs.length), reason: '$row $day');
            if (plan.unfilled.isEmpty) {
              expect(plan.fitsGoal(day), isTrue, reason: '$row $day');
            }
          }
          for (final MapEntry(key: pool, value: uses) in perPool.entries) {
            final meals = uses.values.fold(0, (a, b) => a + b);
            final fair = (meals / plan.poolSizes[pool]!).ceil();
            expect(uses.values.every((n) => n <= fair), isTrue,
                reason: '$row ${pool.name}: $uses');
          }
        }
      }
    }
  });

  test('bestehende Einträge bleiben stehen und zählen zur Tagessumme und zu '
      'den Wiederholungen', () {
    final chili = _catalog('rinderhack_chili_mit_bohnen');
    final tuesdayLunch = PlannedMeal.create(
      recipe: chili,
      day: DateTime(2026, 11, 3),
      slot: MealSlot.lunch,
      servings: 2,
    );
    final eatenBreakfast = PlannedMeal.create(
      recipe: _catalog('protein_pancakes_mit_beeren'),
      day: DateTime(2026, 11, 4),
      slot: MealSlot.breakfast,
    ).copyWith(eatenAt: DateTime(2026, 11, 4, 8));
    final removedDinner = PlannedMeal.create(
      recipe: chili,
      day: DateTime(2026, 11, 5),
      slot: MealSlot.dinner,
    ).copyWith(removed: true);
    final plan = _suggest(
      existing: [tuesdayLunch, eatenBreakfast, removedDinner],
      skipped: {(day: '2026-11-02', slot: MealSlot.breakfast)},
    );
    bool has(String day, MealSlot slot) =>
        plan.meals.any((m) => m.day == day && m.slot == slot);

    expect(has('2026-11-03', MealSlot.lunch), isFalse);
    expect(has('2026-11-04', MealSlot.breakfast), isFalse,
        reason: 'an eaten entry holds its slot');
    expect(has('2026-11-02', MealSlot.breakfast), isFalse, reason: 'skipped');
    expect(has('2026-11-05', MealSlot.dinner), isTrue,
        reason: 'a removed entry frees its slot');
    expect(
      plan.meals.where((m) => m.day == '2026-11-03').map((m) => m.recipe.slug),
      isNot(contains(chili.slug)),
    );
    final tuesday = plan.meals.where((m) => m.day == '2026-11-03');
    expect(
      plan.kcalOn('2026-11-03'),
      chili.caloriesKcal * 2 + tuesday.fold(0, (sum, m) => sum + m.kcal),
    );
    expect(plan.existingOn('2026-11-03'), 1);
    expect(plan.meals, hasLength(21 - 3));
  });

  test('gleicher Input, gleicher Plan; ein anderer Seed mischt neu', () {
    final first = _signature(_suggest());
    expect(_signature(_suggest()), first);
    expect(
      _signature(_suggest(recipes: recipeCatalogDe.reversed.toList())),
      first,
      reason: 'the catalog order does not shuffle the plan',
    );
    expect(_signature(_suggest(seed: 1)), isNot(first));
  });

  test('ein Slot ohne passendes Rezept bleibt leer, statt etwas Unpassendes '
      'oder ein Gericht zweimal am Tag zu erzwingen', () {
    for (final (row, plan, emptySlots) in [
      (
        'vegetarisch ohne alle 13: kein Hauptgericht',
        _suggest(
          diet: DietPreference.vegetarian,
          avoid: FoodAvoidance.values.toSet(),
        ),
        {MealSlot.lunch, MealSlot.dinner},
      ),
      (
        'ein einziges eigenes Hauptgericht',
        _suggest(recipes: [_own('user_bowl')]),
        {MealSlot.breakfast, MealSlot.dinner},
      ),
    ]) {
      expect(plan.unfilled, hasLength(7 * emptySlots.length), reason: row);
      expect(plan.unfilled.map((s) => s.slot).toSet(), emptySlots, reason: row);
      expect(
        plan.meals.map((m) => m.slot).toSet().intersection(emptySlots),
        isEmpty,
        reason: row,
      );
    }
  });

  test('ein zu kleiner Katalog sagt es; Tauschen nimmt ein anderes Gericht, '
      'nie eines, das an dem Tag schon steht', () {
    final vegan = _suggest(diet: DietPreference.vegan);
    expect(vegan.poolSizes[WeekPlanPool.main], 5);
    expect(vegan.thinPools, contains(WeekPlanPool.main));
    expect(_suggest().thinPools, isEmpty);

    final meal = vegan.meals.firstWhere((m) => m.slot == MealSlot.lunch);
    final swapped = vegan.swapped(meal)!;
    final replacement = swapped.meals.firstWhere(
      (m) => m.day == meal.day && m.slot == MealSlot.lunch,
    );
    final sameDay = [
      for (final m in swapped.meals)
        if (m.day == meal.day) m.recipe.slug,
    ];
    expect(replacement.recipe.slug, isNot(meal.recipe.slug));
    expect(replacement.recipe.matchesDiet(DietPreference.vegan), isTrue);
    expect(sameDay.toSet(), hasLength(sameDay.length));
    expect(swapped.meals, hasLength(vegan.meals.length));

    final own = _suggest(recipes: [_own('user_bowl')]);
    expect(own.swapped(own.meals.first), isNull, reason: 'nothing else fits');
    expect(own.without(own.meals.first).meals, hasLength(6));
  });
}
