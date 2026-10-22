import '../models/logged_meal.dart';
import '../models/model_limits.dart' show truncateToChars;
import '../models/planned_meal.dart';
import 'day_math.dart';
import 'energy_check.dart';
import 'local_day.dart';

/// Planned meals per day the Coach context names at most.
const int _maxPlannedPerDay = 4;

/// Longest planned title in the context, like the food names of the day.
const int _maxTitleChars = 40;

/// The meal-plan line of the Coach context (2026-10-22), German like the
/// rest of the context. Pure; the store binds its state.
///
/// Names the titles of today's and tomorrow's planned meals that are not
/// eaten yet, by slot, and nothing else: no servings, ingredients or
/// nutrition. An eaten plan is already in the food list. Null when neither
/// day holds an open plan, so the line is absent instead of empty.
String? coachMealPlanLine({
  required DateTime today,
  required List<PlannedMeal> plans,
}) {
  final start = startOfDay(today);
  String? day(DateTime date, String label) {
    final key = localDayKey(date);
    final open = <PlannedMeal>[
      for (final slot in MealSlot.values)
        for (final plan in plans)
          if (plan.day == key &&
              plan.slot == slot &&
              !plan.removed &&
              !plan.isEaten)
            plan,
    ];
    if (open.isEmpty) return null;
    final shown = open
        .take(_maxPlannedPerDay)
        .map((plan) {
          final title = plan.recipe.title.trim();
          final clipped = truncateToChars(title, _maxTitleChars);
          final name = title.isEmpty
              ? 'Gericht'
              : clipped == title
              ? title
              : '${truncateToChars(title, _maxTitleChars - 1)}…';
          return '${plan.slot.germanLabel}: $name';
        })
        .join(', ');
    final more = open.length > _maxPlannedPerDay ? ' …' : '';
    return '$label $shown$more';
  }

  final days = <String>[
    ?day(start, 'heute'),
    ?day(addDays(start, 1), 'morgen'),
  ];
  if (days.isEmpty) return null;
  return 'Speiseplan (geplant, noch nicht gegessen) — ${days.join('; ')}.';
}

/// The weekly-check line of the Coach context (2026-10-22): the check's
/// state only, never its figures (no expenditure, rate, goal or step).
///
/// [manualGoal]: the user set the daily goal by hand, so the check is off.
/// Otherwise [progress] and [estimate] are the store's values on complete
/// sources; null [progress] means the check does not apply or its sources
/// are not ready, and the line is absent.
String? coachEnergyCheckLine({
  bool manualGoal = false,
  EnergyCheckProgress? progress,
  EnergyCheckEstimate? estimate,
}) {
  if (manualGoal) {
    return 'Wochen-Check: aus, das Tagesziel ist manuell festgelegt.';
  }
  if (estimate != null) {
    final proposal = estimate.proposal;
    if (proposal != null) {
      final direction = proposal.stepKcal < 0 ? 'senken' : 'erhöhen';
      return 'Wochen-Check: schlägt heute vor, das Tagesziel zu $direction; '
          'der Nutzer entscheidet darüber in der App.';
    }
    return estimate.withinNoise
        ? 'Wochen-Check: das Tagesziel passt zum Gewichtstrend.'
        : 'Wochen-Check: Aufnahme und Gewichtstrend weichen ab, das '
              'Tagesziel steht aber schon an einer Grenze der Anpassung.';
  }
  if (progress == null) return null;
  if (progress.pausedUntil != null) {
    return 'Wochen-Check: vor Kurzem beantwortet, der nächste folgt eine '
        'Woche danach.';
  }
  final missing = <String>[
    if (progress.missingLoggedDays > 0) 'vollständig erfasste Tage',
    if (progress.missingWeighInDays > 0 || !progress.spanReached)
      'Wiegungen über mindestens zwei Wochen',
  ];
  return missing.isEmpty
      ? 'Wochen-Check: sammelt noch Daten.'
      : 'Wochen-Check: sammelt noch Daten, es fehlen noch '
            '${missing.join(' und ')}.';
}
