import '../models/favorite_meal.dart';
import '../models/logged_meal.dart';
import '../models/macro_progress.dart';
import '../models/meal_analysis_result.dart';
import 'favorites_view.dart' show foodUseWindowStart;
import 'food_history_search.dart';
import 'local_day.dart';

// The add sheet's suggestions from the user's own foods (2026-11-01): what
// they often eat in a meal slot, their usual combination there, and which
// own foods still fit today's budget. Pure and synchronous: no I/O, no
// network, no AI; works offline. Foods are grouped like the search's
// "From you" ([FoodHistoryIndex]), and the window is the favorites sheet's
// 35 days ([foodUseWindowStart]).

/// Days a food needs in one slot within the window to count as "often".
const int frequentFoodMinDays = 3;

/// Rows of the "Often at breakfast" section.
const int frequentFoodsMax = 5;

/// Own foods with a stated protein value before "Still fits" shows at all.
const int fittingFoodsMinKnown = 10;

/// Rows of the "Still fits" section.
const int fittingFoodsMax = 3;

/// What the add sheet offers above its recents for one slot and day.
class OwnFoodSuggestions {
  const OwnFoodSuggestions({
    this.usual,
    this.frequent = const <FoodHistoryHit>[],
    this.fitting = const <FoodHistoryHit>[],
  });

  /// The slot's usual combination, offered while the slot is still empty.
  final UsualSlotMeal? usual;

  /// Foods of the slot on at least [frequentFoodMinDays] days, most days
  /// first, each with its newest portion in that slot.
  final List<FoodHistoryHit> frequent;

  /// Own foods whose usual portion fits the day's remaining kcal, most
  /// protein first.
  final List<FoodHistoryHit> fitting;
}

/// The same set of at least two foods in one slot on [days] days.
class UsualSlotMeal {
  const UsualSlotMeal({required this.meals, required this.days});

  /// The newest such day's entries, oldest first: what a copy takes over.
  final List<LoggedMeal> meals;
  final int days;

  int get kcal => meals.fold(0, (sum, meal) => sum + meal.result.caloriesKcal);
}

/// Everything the add sheet shows for [slot] on [day] from [diary] (the
/// rows the store holds) and [favorites] (pinned, recents, own products).
///
/// [dayMeals] are the entries already on [day]. [day] itself never counts
/// as history, so what the sheet adds there leaves the frequent rows where
/// they are. The usual meal is offered only while [slot] is empty there.
/// "Still fits" needs [day] to be [now]'s day with at least one entry, and
/// [remainingKcal] above 0; it leaves out the foods already in the frequent
/// list.
OwnFoodSuggestions ownFoodSuggestions({
  required Iterable<LoggedMeal> diary,
  required Iterable<FavoriteMeal> favorites,
  required MealSlot slot,
  required DateTime day,
  required Iterable<LoggedMeal> dayMeals,
  required DateTime now,
  int? remainingKcal,
}) {
  final dayKey = localDayKey(day);
  final frequent = frequentFoodsInSlot(
    diary,
    slot: slot,
    now: now,
    skipDay: dayKey,
  );
  final remaining = remainingKcal;
  final today = dayKey == localDayKey(now);
  return OwnFoodSuggestions(
    // Every part of a usual meal is a frequent food, so no frequent food
    // means no usual meal either.
    usual: frequent.isEmpty || dayMeals.any((meal) => meal.slot == slot)
        ? null
        : usualMealInSlot(diary, slot: slot, now: now, skipDay: dayKey),
    frequent: frequent,
    fitting: remaining == null || !today || dayMeals.isEmpty
        ? const <FoodHistoryHit>[]
        : foodsThatFit(
            favorites: favorites,
            diary: diary,
            remainingKcal: remaining,
            exclude: {for (final hit in frequent) hit.key},
          ),
  );
}

/// The foods logged in [slot] on at least [minDays] distinct days of the
/// window (the local day key [skipDay] left out), most days first, then the
/// most recently logged. Each hit carries its newest entry in [slot]; three
/// cups on one morning count one day.
List<FoodHistoryHit> frequentFoodsInSlot(
  Iterable<LoggedMeal> diary, {
  required MealSlot slot,
  required DateTime now,
  String? skipDay,
  int minDays = frequentFoodMinDays,
  int limit = frequentFoodsMax,
}) {
  final meals = _inSlotWindow(diary, slot, now, skipDay);
  final index = FoodHistoryIndex(diary: meals);
  final days = <String, Set<String>>{};
  for (final meal in meals) {
    final key = index.keyOf(meal.result);
    if (key != null) (days[key] ??= <String>{}).add(meal.effectiveLocalDay);
  }
  int daysOf(FoodHistoryHit hit) => days[hit.key]?.length ?? 0;
  final hits = [
    for (final hit in index.foods)
      if (daysOf(hit) >= minDays) hit,
  ];
  hits.sort((a, b) {
    final byDays = daysOf(b).compareTo(daysOf(a));
    if (byDays != 0) return byDays;
    // Diary rows only, so every hit has a time.
    final byTime = b.lastUsed!.compareTo(a.lastUsed!);
    return byTime != 0 ? byTime : a.key.compareTo(b.key);
  });
  return hits.take(limit).toList(growable: false);
}

/// The slot's usual combination: the set of foods (two or more) that made
/// up [slot] exactly on the most days of the window ([skipDay] left out),
/// at least [minDays]; on a tie the more recent one. Null when no set
/// repeats that often.
UsualSlotMeal? usualMealInSlot(
  Iterable<LoggedMeal> diary, {
  required MealSlot slot,
  required DateTime now,
  String? skipDay,
  int minDays = frequentFoodMinDays,
}) {
  final keys = FoodHistoryIndex();
  final byDay = <String, List<LoggedMeal>>{};
  for (final meal in _inSlotWindow(diary, slot, now, skipDay)) {
    if (keys.keyOf(meal.result) == null) continue;
    (byDay[meal.effectiveLocalDay] ??= <LoggedMeal>[]).add(meal);
  }
  final dayCount = <String, int>{};
  final newestDay = <String, String>{};
  for (final MapEntry(key: day, value: meals) in byDay.entries) {
    final foods = {for (final meal in meals) keys.keyOf(meal.result)!};
    if (foods.length < 2) continue;
    final set = (foods.toList()..sort()).join('\n');
    dayCount[set] = (dayCount[set] ?? 0) + 1;
    final known = newestDay[set];
    // Day keys are YYYY-MM-DD, so string order is calendar order.
    if (known == null || day.compareTo(known) > 0) newestDay[set] = day;
  }
  String? best;
  for (final MapEntry(key: set, value: count) in dayCount.entries) {
    if (count < minDays) continue;
    final leader = best;
    if (leader == null ||
        count > dayCount[leader]! ||
        (count == dayCount[leader]! &&
            newestDay[set]!.compareTo(newestDay[leader]!) > 0)) {
      best = set;
    }
  }
  if (best == null) return null;
  final meals = [...byDay[newestDay[best]]!]
    ..sort((a, b) => a.loggedAt.compareTo(b.loggedAt));
  return UsualSlotMeal(meals: meals, days: dayCount[best]!);
}

/// "Still fits": own foods (favorites, recents, own products and the diary
/// rows the store holds; no recipes) whose usual portion is within
/// [remainingKcal], most protein first, then fewer kcal.
///
/// The usual portion is the newest one ([FoodHistoryIndex]): a pinned
/// favorite's saved portion, a recent's last one. Foods without energy or
/// with unknown protein never count. Empty while nothing is left, or while
/// fewer than [minKnown] own foods state their protein: the list would say
/// more about the gaps than about the day.
List<FoodHistoryHit> foodsThatFit({
  required Iterable<FavoriteMeal> favorites,
  required Iterable<LoggedMeal> diary,
  required int remainingKcal,
  Set<String> exclude = const <String>{},
  int minKnown = fittingFoodsMinKnown,
  int limit = fittingFoodsMax,
}) {
  if (remainingKcal <= 0) return const <FoodHistoryHit>[];
  final known = <(FoodHistoryHit, double)>[
    for (final hit in FoodHistoryIndex(
      favorites: favorites,
      diary: diary,
    ).foods)
      if (_statedProteinG(hit.result) case final protein?) (hit, protein),
  ];
  if (known.length < minKnown) return const <FoodHistoryHit>[];
  final fits = [
    for (final candidate in known)
      if (candidate.$1.result.caloriesKcal <= remainingKcal &&
          !exclude.contains(candidate.$1.key))
        candidate,
  ];
  fits.sort((a, b) {
    final byProtein = b.$2.compareTo(a.$2);
    if (byProtein != 0) return byProtein;
    final byKcal = a.$1.result.caloriesKcal.compareTo(b.$1.result.caloriesKcal);
    return byKcal != 0 ? byKcal : a.$1.key.compareTo(b.$1.key);
  });
  return [for (final (hit, _) in fits.take(limit)) hit];
}

/// Diary rows of [slot] logged within the window ending at [now], except
/// those of the local day [skipDay].
List<LoggedMeal> _inSlotWindow(
  Iterable<LoggedMeal> diary,
  MealSlot slot,
  DateTime now,
  String? skipDay,
) {
  final since = foodUseWindowStart(now);
  return [
    for (final meal in diary)
      if (meal.slot == slot &&
          !meal.loggedAt.isBefore(since) &&
          meal.effectiveLocalDay != skipDay)
        meal,
  ];
}

/// Grams of protein as the diary counts them ([MacroProgress.add]), or null
/// for a food without energy or with unknown protein.
double? _statedProteinG(MealAnalysisResult result) {
  if (result.caloriesKcal <= 0) return null;
  final sum = MacroProgress.empty.add(result);
  return sum.proteinMissing > 0 ? null : sum.proteinG;
}
