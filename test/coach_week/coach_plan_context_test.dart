// The Coach context's meal-plan and weekly-check lines (2026-10-22), pure.
//
// The owner's decision was titles and the check's state only: no servings,
// recipe data or check figures reach the model. Whether the store puts the
// lines in the right place sits in home_store_coach_context_slots_test.dart.

import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/planned_meal.dart';
import 'package:eatova/src/services/coach_plan_context.dart';
import 'package:eatova/src/services/energy_check.dart';

/// Thursday 22 October 2026, morning.
final DateTime _today = DateTime(2026, 10, 22, 9);

PlannedMeal _plan(
  String title,
  int inDays,
  MealSlot slot, {
  bool eaten = false,
}) {
  final plan = PlannedMeal.create(
    recipe: FitnessRecipe(
      slug: 'user_${title.hashCode}',
      title: title,
      description: '',
      portion: '',
      ingredients: '200 g Zutat',
      preparation: '',
      professionalHint: '',
      imageAsset: '',
      caloriesKcal: 640,
      proteinG: 42,
      carbsG: 60,
      fatG: 20,
      estimatedGrams: 450,
      categories: const <String>['Eigene'],
      userCreated: true,
    ),
    day: DateTime(_today.year, _today.month, _today.day + inDays),
    slot: slot,
    servings: 2,
  );
  return eaten ? plan.copyWith(eatenAt: _today) : plan;
}

EnergyCheckProgress _progress({
  int logged = 14,
  int weighIns = 4,
  int span = 14,
  DateTime? pausedUntil,
}) => EnergyCheckProgress(
  today: _today,
  loggedDays: logged,
  weighInDays: weighIns,
  weighInSpanDays: span,
  pausedUntil: pausedUntil,
  earliestDay: _today,
  loggedDaysToGo: 0,
  weighInsToGo: 0,
);

EnergyCheckEstimate _estimate({int? step, bool withinNoise = false}) =>
    EnergyCheckEstimate(
      observedKcal: 2480,
      modelledKcal: 2350,
      weeklyRateKg: -0.21,
      planWeeklyRateKg: -0.5,
      currentGoalKcal: 1850,
      loggedDays: 16,
      weighInDays: 6,
      withinNoise: withinNoise,
      proposal: step == null
          ? null
          : EnergyCheckProposal(
              stepKcal: step,
              newAdjustmentKcal: step,
              currentGoalKcal: 1850,
              newGoalKcal: 1850 + step,
              observedKcal: 2480,
              modelledKcal: 2350,
              weeklyRateKg: -0.21,
              loggedDays: 16,
              weighInDays: 6,
            ),
    );

void main() {
  test('the plan line: open titles of today and tomorrow by slot, nothing '
      'else', () {
    expect(coachMealPlanLine(today: _today, plans: const []), isNull);
    expect(
      coachMealPlanLine(
        today: _today,
        plans: [
          _plan('Gestern-Bowl', -1, MealSlot.dinner),
          _plan('Schon gegessen', 0, MealSlot.breakfast, eaten: true),
          _plan('Übermorgen-Suppe', 2, MealSlot.lunch),
        ],
      ),
      isNull,
      reason: 'other days and eaten plans are no line',
    );

    final line = coachMealPlanLine(
      today: _today,
      plans: [
        _plan('Chili sin Carne', 0, MealSlot.dinner),
        _plan('Overnight Oats', 1, MealSlot.breakfast),
        _plan('Lachs-Bowl', 0, MealSlot.lunch),
        _plan(
          'Ein Gericht mit einem sehr langen Namen, der weit über vierzig '
          'Zeichen hinausgeht',
          1,
          MealSlot.dinner,
        ),
      ],
    )!;
    expect(
      line,
      matches(
        RegExp(
          r'heute Mittagessen: Lachs-Bowl, Abendessen: Chili sin Carne; '
          r'morgen Frühstück: Overnight Oats, Abendessen: Ein Gericht[^;]*…\.$',
        ),
      ),
      reason:
          'slot order within the day, today before tomorrow, long '
          'titles clipped',
    );
    expect(line, isNot(contains('640')), reason: 'no recipe numbers');
    expect(line, isNot(contains('200 g')), reason: 'no ingredients');
  });

  test('the weekly-check line names the state and never a figure', () {
    final rows = <(String, String?, Pattern?)>[
      ('manual goal', coachEnergyCheckLine(manualGoal: true), 'aus'),
      ('not applicable', coachEnergyCheckLine(), null),
      (
        'proposes lower',
        coachEnergyCheckLine(
          progress: _progress(),
          estimate: _estimate(step: -100),
        ),
        'senken',
      ),
      (
        'proposes higher',
        coachEnergyCheckLine(
          progress: _progress(),
          estimate: _estimate(step: 100),
        ),
        'erhöhen',
      ),
      (
        'fits',
        coachEnergyCheckLine(
          progress: _progress(),
          estimate: _estimate(withinNoise: true),
        ),
        'passt',
      ),
      (
        'held at a limit',
        coachEnergyCheckLine(progress: _progress(), estimate: _estimate()),
        'Grenze',
      ),
      (
        'answered recently',
        coachEnergyCheckLine(
          progress: _progress(pausedUntil: DateTime(2026, 10, 26)),
        ),
        'beantwortet',
      ),
      (
        'collecting',
        coachEnergyCheckLine(progress: _progress(logged: 9, weighIns: 2)),
        RegExp('erfasste Tage.*Wiegungen'),
      ),
    ];
    for (final (name, line, expected) in rows) {
      if (expected == null) {
        expect(line, isNull, reason: name);
        continue;
      }
      expect(line, contains(expected), reason: name);
      expect(line, isNot(matches(RegExp(r'\d'))), reason: '$name: no figures');
    }
  });
}
