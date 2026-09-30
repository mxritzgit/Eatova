// The shared recipe-pick actions (controller ruling 2026-09-29): a planned
// pick is only ever logged through the plan conversion, never through the
// generic recipe add; a suggestion opens its recipe or logs its servings.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/planned_meal.dart';
import 'package:eatova/src/models/recipe_pick.dart';
import 'package:eatova/src/screens/recipes/recipes_screen.dart';
import 'package:eatova/src/widgets/recipes/recipe_pick_actions.dart';

import '../../support/harness.dart';

final DateTime _day = DateTime(2026, 9, 28, 18, 30);
final FitnessRecipe _recipe = recipeCatalogForLocale(
  'en',
).firstWhere((r) => recipeSuitsSlot(r, MealSlot.dinner) && r.canLogServings(2));

RecipePick _suggested() => RecipePick(
  recipe: _recipe,
  slot: MealSlot.dinner,
  source: RecipePickSource.suggested,
  servings: 1,
  kcal: _recipe.toMealResultForServings(1, enL10n).caloriesKcal,
  proteinG: 40,
  remainingKcalBefore: 902,
);

RecipePick _planned({int? kcal = 1220}) {
  final plan = PlannedMeal.create(
    recipe: _recipe,
    day: _day,
    slot: MealSlot.dinner,
    servings: 2,
  );
  return RecipePick(
    recipe: _recipe,
    slot: MealSlot.dinner,
    source: RecipePickSource.planned,
    servings: 2,
    kcal: kcal,
    proteinG: 80,
    remainingKcalBefore: 902,
    plannedMeal: plan,
  );
}

/// Records every call the helpers make.
class _Calls {
  final added = <(MealAnalysisResult, MealSlot)>[];
  final eaten = <String>[];
  var plansOpened = 0;
  var failEat = false;

  void add(MealAnalysisResult result, MealSlot slot) =>
      added.add((result, slot));

  Future<void> eat(String id) async {
    if (failEat) throw StateError('write failed');
    eaten.add(id);
  }

  void openPlan() => plansOpened++;
}

Future<BuildContext> _context(WidgetTester tester) async {
  late BuildContext captured;
  await pumpLocalized(
    tester,
    Builder(
      builder: (context) {
        captured = context;
        return const SizedBox.shrink();
      },
    ),
    locale: const Locale('en'),
  );
  return captured;
}

void main() {
  group('openRecipePick', () {
    testWidgets('a suggestion opens its recipe detail', (tester) async {
      final calls = _Calls();
      final context = await _context(tester);
      openRecipePick(
        context,
        _suggested(),
        addMeal: calls.add,
        openMealPlan: calls.openPlan,
      );
      await tester.pumpAndSettle();
      final detail = tester.widget<RecipeDetailScreen>(
        find.byType(RecipeDetailScreen),
      );
      expect(detail.recipe.slug, _recipe.slug);
      expect(calls.plansOpened, 0);
    });

    testWidgets('a planned pick opens the meal plan, never the generic add', (
      tester,
    ) async {
      for (final kcal in <int?>[1220, null]) {
        final calls = _Calls();
        final context = await _context(tester);
        openRecipePick(
          context,
          _planned(kcal: kcal),
          addMeal: calls.add,
          openMealPlan: calls.openPlan,
        );
        await tester.pumpAndSettle();
        expect(calls.plansOpened, 1, reason: 'kcal $kcal');
        expect(find.byType(RecipeDetailScreen), findsNothing);
        expect(calls.added, isEmpty);
      }
    });

    testWidgets('nothing opens once the session ended', (tester) async {
      final calls = _Calls();
      final context = await _context(tester);
      for (final pick in [_suggested(), _planned()]) {
        openRecipePick(
          context,
          pick,
          addMeal: calls.add,
          openMealPlan: calls.openPlan,
          isSessionCurrent: () => false,
        );
      }
      await tester.pumpAndSettle();
      expect(find.byType(RecipeDetailScreen), findsNothing);
      expect(calls.plansOpened, 0);
    });
  });

  group('logRecipePick', () {
    testWidgets('a planned pick is eaten through the plan conversion only', (
      tester,
    ) async {
      final calls = _Calls();
      final context = await _context(tester);
      final pick = _planned();
      final ok = await logRecipePick(
        context,
        pick,
        addMeal: calls.add,
        eatPlannedMeal: calls.eat,
        openMealPlan: calls.openPlan,
      );
      expect(ok, isTrue);
      expect(calls.eaten, [pick.plannedMeal!.id]);
      expect(calls.added, isEmpty);
      expect(calls.plansOpened, 0);
    });

    testWidgets('a planned pick without loggable nutrition opens the plan '
        'and logs nothing', (tester) async {
      final calls = _Calls();
      final context = await _context(tester);
      final ok = await logRecipePick(
        context,
        _planned(kcal: null),
        addMeal: calls.add,
        eatPlannedMeal: calls.eat,
        openMealPlan: calls.openPlan,
      );
      expect(ok, isFalse);
      expect(calls.plansOpened, 1);
      expect(calls.eaten, isEmpty);
      expect(calls.added, isEmpty);
    });

    testWidgets('a suggestion logs its servings into its slot', (tester) async {
      final calls = _Calls();
      final context = await _context(tester);
      final pick = _suggested();
      final ok = await logRecipePick(
        context,
        pick,
        addMeal: calls.add,
        eatPlannedMeal: calls.eat,
        openMealPlan: calls.openPlan,
      );
      expect(ok, isTrue);
      expect(calls.eaten, isEmpty);
      final (result, slot) = calls.added.single;
      expect(slot, MealSlot.dinner);
      expect(result.caloriesKcal, pick.kcal);
    });

    testWidgets('a failed write reports false and shows the save error', (
      tester,
    ) async {
      final calls = _Calls()..failEat = true;
      final context = await _context(tester);
      final ok = await logRecipePick(
        context,
        _planned(),
        addMeal: calls.add,
        eatPlannedMeal: calls.eat,
        openMealPlan: calls.openPlan,
      );
      await tester.pump();
      expect(ok, isFalse);
      expect(calls.added, isEmpty);
      expect(find.text(enL10n.commonLocalSaveFailed), findsOneWidget);
    });

    testWidgets('nothing is logged once the session ended', (tester) async {
      final calls = _Calls();
      final context = await _context(tester);
      for (final pick in [_suggested(), _planned()]) {
        final ok = await logRecipePick(
          context,
          pick,
          addMeal: calls.add,
          eatPlannedMeal: calls.eat,
          openMealPlan: calls.openPlan,
          isSessionCurrent: () => false,
        );
        expect(ok, isFalse);
      }
      expect(calls.added, isEmpty);
      expect(calls.eaten, isEmpty);
    });

    testWidgets('logging a pick again while its write is in flight writes '
        'nothing; afterwards it logs again', (tester) async {
      final context = await _context(tester);
      for (final pick in [_suggested(), _planned()]) {
        var gate = Completer<void>();
        var writes = 0;
        Future<void> slowWrite() async {
          writes++;
          await gate.future;
        }

        Future<bool> log() => logRecipePick(
          context,
          pick,
          addMeal: (_, _) => slowWrite(),
          eatPlannedMeal: (_) => slowWrite(),
          openMealPlan: () {},
        );

        final first = log();
        final second = log();
        await tester.pump();
        expect(writes, 1, reason: 'a double tap: ${pick.source}');
        gate.complete();
        expect(await first, isTrue);
        expect(await second, isFalse);

        // The guard is released: a later, deliberate log writes again.
        gate = Completer<void>()..complete();
        expect(await log(), isTrue);
        expect(writes, 2);
      }
    });

    testWidgets('different picks do not block each other, and a failed '
        'write releases its pick', (tester) async {
      final context = await _context(tester);
      final gate = Completer<void>();
      final calls = _Calls();
      final suggested = logRecipePick(
        context,
        _suggested(),
        addMeal: (result, slot) async {
          calls.add(result, slot);
          await gate.future;
        },
        eatPlannedMeal: calls.eat,
        openMealPlan: calls.openPlan,
      );
      final planned = _planned();
      expect(
        await logRecipePick(
          context,
          planned,
          addMeal: calls.add,
          eatPlannedMeal: calls.eat,
          openMealPlan: calls.openPlan,
        ),
        isTrue,
        reason: 'another pick logs while the first is in flight',
      );
      gate.complete();
      expect(await suggested, isTrue);
      expect(calls.added, hasLength(1));
      expect(calls.eaten, [planned.plannedMeal!.id]);

      calls.failEat = true;
      final failing = _planned();
      Future<bool> eat() => logRecipePick(
        context,
        failing,
        addMeal: calls.add,
        eatPlannedMeal: calls.eat,
        openMealPlan: calls.openPlan,
      );
      expect(await eat(), isFalse);
      calls.failEat = false;
      expect(await eat(), isTrue, reason: 'the failure released the pick');
      await tester.pump();
    });
  });
}
