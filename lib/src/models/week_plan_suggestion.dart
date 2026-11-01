/// "Woche vorschlagen": a deterministic week plan from the user's own recipes
/// and the catalog, without AI.
///
/// Pure and widget-free. The meal plan's preview sheet
/// (`screens/recipes/meal_plan_suggest_sheet.dart`) binds it to the store;
/// nothing is written before its "Übernehmen".
library;

import '../services/local_day.dart';
import 'day_nutrition.dart' show mainMealSlots;
import 'fitness_recipe.dart';
import 'logged_meal.dart';
import 'planned_meal.dart';
import 'recipe_pick.dart' show recipeSuitsSlot;
import 'user_profile.dart';

/// The servings a suggestion may carry, in half steps. One serving comes
/// first and is kept wherever the day fits; the others only bring a day
/// into [weekPlanKcalBand] of the daily goal.
const List<double> weekPlanServingSteps = <double>[1, 1.5, 2, 0.5];

/// A planned day fits its goal within this share of the daily kcal goal.
const double weekPlanKcalBand = 0.10;

/// The candidates per slot a day's search weighs: the least used ones, in
/// seeded order. Four keep the search at a few thousand day variants.
const int _shortlistSize = 4;

/// The recipe group a slot draws from ([recipeSuitsSlot]): lunch and dinner
/// share the main dishes.
enum WeekPlanPool { breakfast, main, snack }

/// The [WeekPlanPool] of [slot].
WeekPlanPool weekPlanPoolOf(MealSlot slot) => switch (slot) {
  MealSlot.breakfast => WeekPlanPool.breakfast,
  MealSlot.lunch || MealSlot.dinner => WeekPlanPool.main,
  MealSlot.snack => WeekPlanPool.snack,
};

/// A day and slot of the plan; `day` is a local day key (`YYYY-MM-DD`).
typedef WeekPlanSlot = ({String day, MealSlot slot});

/// One proposed meal: a recipe for a day and slot with its servings.
final class SuggestedMeal {
  const SuggestedMeal._({
    required this.day,
    required this.slot,
    required this.recipe,
    required this.servings,
    required this.kcal,
  });

  /// Local day key (`YYYY-MM-DD`).
  final String day;
  final MealSlot slot;
  final FitnessRecipe recipe;

  /// A step of [weekPlanServingSteps].
  final double servings;

  /// kcal of [servings] exactly as the diary would log them.
  final int kcal;

  /// A new meal-plan entry for this suggestion, with a fresh id.
  PlannedMeal toPlannedMeal() => PlannedMeal.create(
    recipe: recipe,
    day: parseLocalDayKey(day)!,
    slot: slot,
    servings: servings,
  );
}

/// A proposed week: [meals] for the open slots, the slots no recipe fits
/// ([unfilled]) and how many recipes each pool had ([poolSizes]).
final class WeekPlanSuggestion {
  const WeekPlanSuggestion._({
    required this.meals,
    required this.unfilled,
    required this.poolSizes,
    required this.dailyKcalGoal,
    required Map<String, int> existingKcal,
    required Map<String, int> existingCount,
    required Map<String, Set<String>> existingIds,
    required Map<WeekPlanPool, List<_Candidate>> pools,
  }) : _existingKcal = existingKcal,
       _existingCount = existingCount,
       _existingIds = existingIds,
       _pools = pools;

  /// By day, then slot.
  final List<SuggestedMeal> meals;

  /// Open slots left empty: no fitting recipe, or the only ones are already
  /// on that day.
  final List<WeekPlanSlot> unfilled;

  /// Fitting recipes per pool (diet, avoided foods, dislikes, loggable).
  final Map<WeekPlanPool, int> poolSizes;
  final int dailyKcalGoal;

  final Map<String, int> _existingKcal;
  final Map<String, int> _existingCount;
  final Map<String, Set<String>> _existingIds;
  final Map<WeekPlanPool, List<_Candidate>> _pools;

  /// The planned kcal of [day]: its existing entries (eaten ones included,
  /// as in the plan's day line) plus the suggested meals.
  int kcalOn(String day) =>
      (_existingKcal[day] ?? 0) +
      meals.where((m) => m.day == day).fold(0, (sum, m) => sum + m.kcal);

  /// Entries [day] already holds; the suggestion leaves them alone.
  int existingOn(String day) => _existingCount[day] ?? 0;

  /// Whether [day] lies within [weekPlanKcalBand] of the daily goal.
  bool fitsGoal(String day) => _miss(kcalOn(day), dailyKcalGoal) == 0;

  /// Pools whose recipes repeat because fewer fit than the week needs.
  List<WeekPlanPool> get thinPools => [
    for (final pool in WeekPlanPool.values)
      if (poolSizes[pool]! > 0 &&
          meals.where((m) => weekPlanPoolOf(m.slot) == pool).length >
              poolSizes[pool]!)
        pool,
  ];

  /// This suggestion without [meal].
  WeekPlanSuggestion without(SuggestedMeal meal) =>
      _copy([for (final m in meals) if (!identical(m, meal)) m]);

  /// [meal] swapped for the next recipe of its pool in seeded order that is
  /// not on that day yet, its servings fitted to the day; null when no
  /// other recipe fits.
  WeekPlanSuggestion? swapped(SuggestedMeal meal) {
    final pool = _pools[weekPlanPoolOf(meal.slot)]!;
    final start = pool.indexWhere((c) => c.recipe.slug == meal.recipe.slug);
    final taken = <String>{
      ...?_existingIds[meal.day],
      for (final m in meals)
        if (m.day == meal.day && !identical(m, meal)) ..._identities(m.recipe),
    };
    final others = kcalOn(meal.day) - meal.kcal;
    for (var step = 1; step <= pool.length; step++) {
      final next = pool[(start + step) % pool.length];
      if (next.recipe.slug == meal.recipe.slug ||
          _identities(next.recipe).any(taken.contains)) {
        continue;
      }
      final fit = _bestServings([next], others, dailyKcalGoal);
      final replacement = next.suggest(meal.day, meal.slot, fit.steps.single);
      return _copy([
        for (final m in meals) identical(m, meal) ? replacement : m,
      ]);
    }
    return null;
  }

  WeekPlanSuggestion _copy(List<SuggestedMeal> meals) => WeekPlanSuggestion._(
    meals: List.unmodifiable(meals),
    unfilled: unfilled,
    poolSizes: poolSizes,
    dailyKcalGoal: dailyKcalGoal,
    existingKcal: _existingKcal,
    existingCount: _existingCount,
    existingIds: _existingIds,
    pools: _pools,
  );
}

/// Proposes recipes for the open [slots] of [days].
///
/// Rules, in order:
///  1. **Only fitting recipes.** A pool holds the [recipes] that match the
///     profile's diet ([FitnessRecipe.matchesDiet]), contain none of its
///     avoided foods ([FitnessRecipe.fitsAvoidances]), name none of its
///     dislikes in title or ingredients, suit the slot ([recipeSuitsSlot])
///     and log with known kcal > 0. Own recipes pass diet, avoidance and
///     dislike checks as everywhere else: the user wrote them.
///  2. **Existing entries stay.** A slot with an entry in [existing] (eaten
///     ones included) or in [skipped] is not filled; existing entries count
///     towards the day's kcal and the week's repeats.
///  3. **Few repeats.** A recipe is never twice on one day, and each day
///     takes the least used recipes of the week first, so a pool repeats only
///     once the week has used all of it. A slot with no fitting recipe left
///     for that day stays empty ([WeekPlanSuggestion.unfilled]).
///  4. **The day's kcal.** Among those, the day that comes closest to
///     [weekPlanKcalBand] around the daily goal wins: one serving where
///     that fits, otherwise the fewest servings off one
///     ([weekPlanServingSteps]).
///  5. **Deterministic.** Ties go by a hash of [seed], the week and the
///     recipe slug: the same input gives the same plan, another [seed]
///     ("Neu mischen") another one.
WeekPlanSuggestion suggestWeekPlan({
  required List<DateTime> days,
  required Set<MealSlot> slots,
  required UserProfile profile,
  required List<FitnessRecipe> recipes,
  List<PlannedMeal> existing = const <PlannedMeal>[],
  Set<WeekPlanSlot> skipped = const <WeekPlanSlot>{},
  int seed = 0,
}) {
  final goal = profile.dailyKcalGoal;
  final dayKeys = {for (final day in days) localDayKey(day)}.toList()..sort();
  final week = dayKeys.isEmpty ? '' : _mondayKey(dayKeys.first);
  final dislikes = _dislikeTerms(profile.foodDislikes);

  final pools = <WeekPlanPool, List<_Candidate>>{};
  for (final pool in WeekPlanPool.values) {
    final probe = switch (pool) {
      WeekPlanPool.breakfast => MealSlot.breakfast,
      WeekPlanPool.main => MealSlot.lunch,
      WeekPlanPool.snack => MealSlot.snack,
    };
    final seen = <String>{};
    final list = <_Candidate>[];
    for (final recipe in recipes) {
      if (!seen.add(recipe.slug) ||
          !recipe.matchesDiet(profile.diet) ||
          !recipe.fitsAvoidances(profile.foodAvoidances) ||
          !recipeSuitsSlot(recipe, probe) ||
          (!recipe.userCreated && _dislikes(recipe, dislikes))) {
        continue;
      }
      final kcal = [
        for (final servings in weekPlanServingSteps)
          _loggedKcal(recipe, servings),
      ];
      if (kcal.first == null || kcal.first! <= 0) continue;
      list.add(_Candidate(recipe, _hash('$seed|$week|${recipe.slug}'), kcal));
    }
    list.sort((a, b) {
      final byRank = a.rank.compareTo(b.rank);
      return byRank != 0 ? byRank : a.recipe.slug.compareTo(b.recipe.slug);
    });
    for (var i = 0; i < list.length; i++) {
      list[i].position = i;
    }
    pools[pool] = List.unmodifiable(list);
  }

  final usage = <String, int>{};
  final occupied = <WeekPlanSlot>{...skipped};
  final existingKcal = <String, int>{};
  final existingCount = <String, int>{};
  final existingIds = <String, Set<String>>{};
  for (final plan in existing) {
    if (plan.removed) continue;
    final recipe = plan.recipe;
    usage.update(recipe.slug, (n) => n + 1, ifAbsent: () => 1);
    occupied.add((day: plan.day, slot: plan.slot));
    existingCount.update(plan.day, (n) => n + 1, ifAbsent: () => 1);
    existingIds.putIfAbsent(plan.day, () => <String>{}).addAll(
      _identities(recipe),
    );
    final kcal = _loggedKcal(recipe, plan.servings);
    if (kcal != null) {
      existingKcal.update(plan.day, (n) => n + kcal, ifAbsent: () => kcal);
    }
  }

  final meals = <SuggestedMeal>[];
  final unfilled = <WeekPlanSlot>[];
  for (final day in dayKeys) {
    final open = [
      for (final slot in MealSlot.values)
        if (slots.contains(slot) && !occupied.contains((day: day, slot: slot)))
          slot,
    ];
    if (open.isEmpty) continue;
    final onDay = existingIds[day] ?? const <String>{};
    final shortlists = [
      for (final slot in open)
        (pools[weekPlanPoolOf(slot)]!
                .where((c) => !_identities(c.recipe).any(onDay.contains))
                .toList()
              ..sort((a, b) {
                final byUse = (usage[a.recipe.slug] ?? 0).compareTo(
                  usage[b.recipe.slug] ?? 0,
                );
                return byUse != 0 ? byUse : a.position.compareTo(b.position);
              }))
            .take(_shortlistSize)
            .toList(),
    ];
    final best = _bestDay(shortlists, usage, existingKcal[day] ?? 0, goal);
    for (var i = 0; i < open.length; i++) {
      final choice = best.chosen[i];
      if (choice == null) {
        unfilled.add((day: day, slot: open[i]));
        continue;
      }
      meals.add(choice.candidate.suggest(day, open[i], choice.step));
      usage.update(choice.candidate.recipe.slug, (n) => n + 1, ifAbsent: () => 1);
    }
  }

  return WeekPlanSuggestion._(
    meals: List.unmodifiable(meals),
    unfilled: List.unmodifiable(unfilled),
    poolSizes: {for (final e in pools.entries) e.key: e.value.length},
    dailyKcalGoal: goal,
    existingKcal: existingKcal,
    existingCount: existingCount,
    existingIds: existingIds,
    pools: pools,
  );
}

/// The slots of [now]'s day a suggestion leaves alone: main meals whose time
/// is over ([mealSlotForHour], as the next-meal pick reads it) and every
/// slot that already has a diary entry. [todaysMeals] are the meals of
/// [now]'s local day.
Set<WeekPlanSlot> weekPlanSkipsForToday({
  required DateTime now,
  required Iterable<LoggedMeal> todaysMeals,
}) {
  final local = now.toLocal();
  final day = localDayKey(local);
  final current = mealSlotForHour(local.hour);
  final passed = current == MealSlot.snack
      ? mainMealSlots
      : mainMealSlots.take(mainMealSlots.indexOf(current));
  return {
    for (final slot in passed) (day: day, slot: slot),
    for (final meal in todaysMeals) (day: day, slot: meal.slot),
  };
}

final class _Candidate {
  _Candidate(this.recipe, this.rank, this.kcal);

  final FitnessRecipe recipe;
  final int rank;

  /// Index in the pool's seeded order.
  int position = 0;

  /// kcal per entry of [weekPlanServingSteps]; null where it cannot log.
  final List<int?> kcal;

  SuggestedMeal suggest(String day, MealSlot slot, int step) =>
      SuggestedMeal._(
        day: day,
        slot: slot,
        recipe: recipe,
        servings: weekPlanServingSteps[step],
        kcal: kcal[step]!,
      );
}

typedef _Choice = ({_Candidate candidate, int step});

/// The best variant of one day: per open slot one candidate of its
/// shortlist or none, never one recipe twice, scored lexicographically by
/// empty slots, repeats in the week, distance from the kcal band, servings
/// off one, then distance from the goal and seeded order.
({List<_Choice?> chosen}) _bestDay(
  List<List<_Candidate>> shortlists,
  Map<String, int> usage,
  int existingKcal,
  int goal,
) {
  List<_Choice?> best = List.filled(shortlists.length, null);
  List<int>? bestScore;
  final picked = <_Candidate?>[];

  void visit(int i) {
    if (i == shortlists.length) {
      final chosen = [for (final c in picked) ?c];
      final head = [
        picked.length - chosen.length,
        chosen.fold(0, (sum, c) => sum + (usage[c.recipe.slug] ?? 0)),
      ];
      // Worse on empty slots or repeats: the servings cannot make up for it.
      if (bestScore != null && _compare(head, bestScore!.sublist(0, 2)) > 0) {
        return;
      }
      final fit = _bestServings(chosen, existingKcal, goal);
      final score = [
        ...head,
        ...fit.score,
        chosen.fold(0, (sum, c) => sum + c.position),
      ];
      if (bestScore == null || _compare(score, bestScore!) < 0) {
        bestScore = score;
        var next = 0;
        best = [
          for (final c in picked)
            c == null ? null : (candidate: c, step: fit.steps[next++]),
        ];
      }
      return;
    }
    for (final candidate in shortlists[i]) {
      final ids = _identities(candidate.recipe);
      if (picked.any((p) => p != null && _identities(p.recipe).any(ids.contains))) {
        continue;
      }
      picked.add(candidate);
      visit(i + 1);
      picked.removeLast();
    }
    picked.add(null);
    visit(i + 1);
    picked.removeLast();
  }

  visit(0);
  return (chosen: best);
}

/// The servings steps for [chosen] that bring [base] plus their kcal
/// closest to the band around [goal]: band distance, steps off one, their
/// distance from one, then distance from [goal].
({List<int> steps, List<int> score}) _bestServings(
  List<_Candidate> chosen,
  int base,
  int goal,
) {
  var bestSteps = List.filled(chosen.length, 0);
  // One serving each, inside the band: nothing scores better.
  final plain = chosen.fold(base, (sum, c) => sum + c.kcal.first!);
  if (_miss(plain, goal) == 0) {
    return (steps: bestSteps, score: [0, 0, 0, (plain - goal).abs()]);
  }
  List<int>? bestScore;
  final steps = List.filled(chosen.length, 0);

  void visit(int i, int total) {
    if (i == chosen.length) {
      var off = 0, deviation = 0;
      for (final step in steps) {
        if (step != 0) off++;
        deviation += ((weekPlanServingSteps[step] - 1).abs() * 2).round();
      }
      final score = [_miss(total, goal), off, deviation, (total - goal).abs()];
      if (bestScore == null || _compare(score, bestScore!) < 0) {
        bestScore = score;
        bestSteps = List.of(steps);
      }
      return;
    }
    for (var step = 0; step < weekPlanServingSteps.length; step++) {
      final kcal = chosen[i].kcal[step];
      if (kcal == null) continue;
      steps[i] = step;
      visit(i + 1, total + kcal);
    }
  }

  visit(0, base);
  return (steps: bestSteps, score: bestScore!);
}

/// kcal outside the band around [goal]; 0 inside it.
int _miss(int total, int goal) {
  final low = (goal * (1 - weekPlanKcalBand)).ceil();
  final high = (goal * (1 + weekPlanKcalBand)).floor();
  if (total < low) return low - total;
  if (total > high) return total - high;
  return 0;
}

int _compare(List<int> a, List<int> b) {
  for (var i = 0; i < a.length && i < b.length; i++) {
    if (a[i] != b[i]) return a[i].compareTo(b[i]);
  }
  return a.length.compareTo(b.length);
}

/// What logging [servings] of [recipe] would record in kcal, or null.
int? _loggedKcal(FitnessRecipe recipe, double servings) {
  try {
    return recipe.toMealResultForServings(servings).caloriesKcal;
  } on FormatException {
    return null;
  }
}

/// A recipe's identities for "never twice a day": its slug and its name, so
/// an own copy of a catalog dish counts as the same meal.
Set<String> _identities(FitnessRecipe recipe) => {
  's:${recipe.slug}',
  'n:${recipe.title.trim().toLowerCase()}',
};

/// The dislikes text ("Koriander, Pilze") as folded search terms of at least
/// three letters; shorter ones would match inside unrelated words.
List<String> _dislikeTerms(String dislikes) => [
  for (final part in dislikes.split(
    RegExp(r'[,;/\n]|\s+(?:und|and|oder|or)\s+', caseSensitive: false),
  ))
    if (foldRecipeSearchText(part.trim()) case final term
        when term.length >= 3)
      term,
];

/// Whether [recipe]'s title or ingredients name one of [terms]. A
/// recommendation aid like the avoided foods, not a guarantee.
bool _dislikes(FitnessRecipe recipe, List<String> terms) {
  if (terms.isEmpty) return false;
  final text = foldRecipeSearchText('${recipe.title}\n${recipe.ingredients}');
  return terms.any(text.contains);
}

String _mondayKey(String day) {
  final date = parseLocalDayKey(day)!;
  return localDayKey(DateTime(date.year, date.month, date.day - date.weekday + 1));
}

/// FNV-1a over [text]: a stable order that does not depend on the platform's
/// random generator.
int _hash(String text) {
  var hash = 0x811c9dc5;
  for (final unit in text.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash;
}
