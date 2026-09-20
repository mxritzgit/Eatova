import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/favorite_meal.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/models/weight_log.dart';
import 'package:eatova/src/screens/settings/goals_screen.dart';
import 'package:eatova/src/screens/onboarding_screen.dart';
import 'package:eatova/src/widgets/kcal/edit_meal_sheet.dart';
import 'package:eatova/src/widgets/kcal/diary_meal_card.dart';
import 'package:eatova/src/widgets/kcal/favorites_sheet.dart';
import 'package:eatova/src/widgets/kcal/manual_meal_sheet.dart';
import 'package:eatova/src/widgets/kcal/meal_analysis_sheet.dart';
import 'package:eatova/src/widgets/profile/profile_widgets.dart';

import 'support/harness.dart';
import 'support/onboarding_harness.dart';

const meal = MealAnalysisResult(
  mealName: 'Bowl',
  caloriesKcal: 300,
  estimatedGrams: 200,
  kcalPer100G: 150,
  protein: '20 g',
  carbs: '40 g',
  fat: '5 g',
  confidence: 'high',
  portionNotes: '',
);

Finder key(String value) => find.byKey(ValueKey(value));

void main() {
  testWidgets('profile goals keep the changed draft after a rejected commit', (
    tester,
  ) async {
    pinPhoneViewport(tester);
    final commit = Completer<void>();
    var closed = false;
    await pumpLocalized(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            await Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => GoalsScreen(
                  profile: const UserProfile(),
                  onSave: (_) => commit.future,
                ),
              ),
            );
            closed = true;
          },
          child: const Text('open'),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(key('settings-height'));
    await tester.enterText(key('settings-height'), '180');
    await tester.pump();
    await tester.ensureVisible(key('settings-save'));
    await tester.pumpAndSettle();
    await tester.tap(key('settings-save'));
    await tester.pump();
    expect(closed, isFalse);
    commit.completeError(StateError('disk full'));
    await tester.pumpAndSettle();
    expect(closed, isFalse);
    expect(key('screen-goals'), findsOneWidget);
    expect(
      tester.widget<TextField>(key('settings-height')).controller!.text,
      '180',
    );
  });

  testWidgets(
    'onboarding waits for one commit and can retry a storage failure',
    (tester) async {
      pinPhoneViewport(tester);
      var commit = Completer<void>();
      var calls = 0;
      await pumpLocalized(
        tester,
        OnboardingScreen(
          firstName: 'Test',
          initialProfile: const UserProfile(),
          onComplete: (_) {
            calls++;
            return commit.future;
          },
        ),
        settle: true,
      );
      await goToOnboarding(tester, 'summary');
      await tapOnboarding(tester, 'onboarding-finish');
      await tester.tap(key('onboarding-finish'), warnIfMissed: false);
      expect(calls, 1);
      commit.completeError(StateError('disk full'));
      await tester.pumpAndSettle();
      expect(key('onboarding-step-summary'), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      commit = Completer<void>();
      await tapOnboarding(tester, 'onboarding-finish');
      expect(calls, 2);
      commit.complete();
      await tester.pumpAndSettle();
    },
  );

  testWidgets('swipe deletion preserves the row when the commit fails', (
    tester,
  ) async {
    pinPhoneViewport(tester);
    final commit = Completer<void>();
    var calls = 0;
    await pumpLocalized(
      tester,
      DiaryMealCard(
        slot: MealSlot.lunch,
        entries: [
          DiaryEntry(
            LoggedMeal(
              id: 'meal-1',
              result: meal,
              loggedAt: DateTime(2026, 9, 20, 12),
              forcedSlot: MealSlot.lunch,
            ),
            0,
          ),
        ],
        onRemoveMeal: (_) {
          calls++;
          return commit.future;
        },
      ),
      settle: true,
    );
    // Reveal the delete action without removing the row before storage agrees.
    await tester.tap(find.text('Mittagessen').first);
    await tester.pumpAndSettle();
    await tester.drag(key('food-history-entry-0'), const Offset(-600, 0));
    await tester.pumpAndSettle();
    await tester.tap(key('food-history-delete-0'));
    await tester.pump();
    expect(calls, 1);
    expect(key('food-history-entry-0'), findsOneWidget);
    commit.completeError(StateError('disk full'));
    await tester.pumpAndSettle();
    expect(key('food-history-entry-0'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed edit-sheet deletion neither closes nor reports deleted', (
    tester,
  ) async {
    pinPhoneViewport(tester);
    final commit = Completer<void>();
    var closed = false;
    await pumpLocalized(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            await showEditMealSheet(
              context,
              meal: LoggedMeal(
                id: 'meal-1',
                result: meal,
                loggedAt: DateTime(2026, 9, 20, 12),
                forcedSlot: MealSlot.lunch,
              ),
              onUpdateMeal: (_, {result, slot, day}) => null,
              onRemoveMeal: (_) => commit.future,
            );
            closed = true;
          },
          child: const Text('open'),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(key('edit-meal-delete-button'));
    await tester.tap(key('edit-meal-delete-button'));
    await tester.pump();
    expect(closed, isFalse);
    commit.completeError(StateError('disk full'));
    await tester.pumpAndSettle();
    expect(closed, isFalse);
    expect(key('edit-meal-sheet'), findsOneWidget);
  });

  testWidgets(
    'manual draft waits for commit, rejects double save, survives failure',
    (tester) async {
      pinPhoneViewport(tester);
      var commit = Completer<void>();
      var calls = 0;
      MealAnalysisResult? closedWith;
      await pumpLocalized(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              closedWith = await showManualMealSheet(
                context,
                onSave: (_) {
                  calls++;
                  return commit.future;
                },
              );
            },
            child: const Text('open'),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(key('manual-meal-name'), 'Saved draft');
      await tester.enterText(key('manual-meal-kcal100'), '123');
      await tester.pump();
      await tester.ensureVisible(key('manual-meal-save'));
      await tester.pumpAndSettle();
      await tester.tap(key('manual-meal-save'));
      await tester.pump();
      await tester.tap(key('manual-meal-save'), warnIfMissed: false);
      expect(calls, 1);
      expect(closedWith, isNull);
      expect(key('manual-meal-name'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.tapAt(const Offset(4, 4));
      await tester.drag(find.byType(ManualMealSheet), const Offset(0, 550));
      await tester.pump();
      expect(key('manual-meal-name'), findsOneWidget,
          reason: 'Back, barrier and drag cannot hide an unresolved commit.');
      commit.completeError(StateError('synthetic disk failure'));
      await tester.pumpAndSettle();
      expect(closedWith, isNull);
      expect(
        tester.widget<TextField>(key('manual-meal-name')).controller!.text,
        'Saved draft',
      );
      expect(
        tester.widget<FilledButton>(key('manual-meal-save')).onPressed,
        isNotNull,
      );
      commit = Completer<void>();
      await tester.tap(key('manual-meal-save'));
      await tester.pump();
      expect(calls, 2);
      expect(closedWith, isNull);
      commit.complete();
      await tester.pumpAndSettle();
      expect(closedWith?.mealName, 'Saved draft');
      expect(key('manual-meal-name'), findsNothing);
    },
  );

  testWidgets('edit retains the sheet until a durable result', (tester) async {
    await withClock(Clock.fixed(DateTime(2026, 9, 20, 12)), () async {
      pinPhoneViewport(tester);
      final logged = LoggedMeal(
        id: 'meal-1',
        result: meal,
        loggedAt: clock.now(),
        forcedSlot: MealSlot.breakfast,
      );
      var commit = Completer<LoggedMeal?>();
      MealEditOutcome? outcome;
      await pumpLocalized(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              outcome = await showEditMealSheet(
                context,
                meal: logged,
                onUpdateMeal: (_, {result, slot, day}) => commit.future,
                onRemoveMeal: (_) =>
                    Future<void>.error(StateError('disk full')),
              );
            },
            child: const Text('open'),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(key('edit-slot-select-lunch'));
      await tester.pump();
      await tester.ensureVisible(key('edit-meal-save-button'));
      await tester.tap(key('edit-meal-save-button'));
      await tester.pump();
      expect(outcome, isNull);
      expect(key('edit-meal-sheet'), findsOneWidget);
      commit.completeError(StateError('disk full'));
      await tester.pumpAndSettle();
      expect(key('edit-meal-sheet'), findsOneWidget);
      expect(outcome, isNull);
      commit = Completer<LoggedMeal?>();
      await tester.tap(key('edit-meal-save-button'));
      await tester.pump();
      commit.complete(logged.copyWith(forcedSlot: MealSlot.lunch));
      await tester.pumpAndSettle();
      expect(outcome?.meal?.slot, MealSlot.lunch);
    });
  });

  testWidgets('analysis never marks a meal added before the commit', (
    tester,
  ) async {
    pinPhoneViewport(tester);
    final commit = Completer<String>();
    var calls = 0;
    await pumpLocalized(
      tester,
      MealAnalysisSheet(
        slot: MealSlot.lunch,
        resultFuture: Future.value(meal),
        previewImage: null,
        onAdd: (_, __) {
          calls++;
          return commit.future;
        },
        onUpdateMeal: (_, __) {},
        failureMessage: 'failed',
      ),
      settle: true,
    );
    await tester.ensureVisible(key('analyse-add-daily-button'));
    await tester.tap(key('analyse-add-daily-button'));
    await tester.pump();
    await tester.tap(key('analyse-add-daily-button'));
    expect(calls, 1);
    expect(find.textContaining('hinzugefügt'), findsNothing);
    commit.complete('meal-1');
    await tester.pump();
    expect(find.textContaining('hinzugefügt'), findsWidgets);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('failed favorite unpin keeps the row and reports no success', (
    tester,
  ) async {
    pinPhoneViewport(tester);
    final commit = Completer<void>();
    var calls = 0;
    await pumpLocalized(
      tester,
      FavoritesSheet(
        favorites: [
          FavoriteMeal(
            id: 'favorite-1',
            result: meal,
            addedAt: DateTime(2026, 9, 20),
            pinned: true,
          ),
        ],
        slot: MealSlot.lunch,
        onAdd: (_, __) => 'meal-1',
        onUnpin: (_) {
          calls++;
          return commit.future;
        },
      ),
      settle: true,
    );
    await tester.tap(key('favorites-sheet-fav-0'));
    await tester.pump();
    await tester.tap(key('favorites-sheet-fav-0'));
    expect(calls, 1);
    expect(find.text('Bowl'), findsOneWidget);
    expect(find.text('Favorit entfernt'), findsNothing);
    commit.completeError(StateError('disk full'));
    await tester.pumpAndSettle();
    expect(find.text('Bowl'), findsOneWidget);
    expect(find.text('Favoriten (1)'), findsOneWidget);
    expect(find.text('Favorit entfernt'), findsNothing);
  });

  testWidgets(
    'weight stays editable after failed commit and closes after retry',
    (tester) async {
      pinPhoneViewport(tester);
      var commit = Completer<void>();
      final values = <double>[];
      await pumpLocalized(
        tester,
        WeightCard(
          profile: const UserProfile(),
          log: WeightLog(
            entries: [
              WeightLogEntry(timestamp: DateTime(2026, 9, 20), weightKg: 80),
            ],
          ),
          onLogWeight: (kg) {
            values.add(kg);
            return commit.future;
          },
        ),
        settle: true,
      );
      await tester.tap(key('profile-log-weight'));
      await tester.pumpAndSettle();
      await tester.enterText(key('profile-weight-input'), '79,5');
      await tester.tap(key('profile-weight-save'));
      await tester.pump();
      expect(key('profile-weight-input'), findsOneWidget);
      commit.completeError(StateError('disk full'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(key('profile-weight-input')).controller!.text,
        '79,5',
      );
      commit = Completer<void>();
      await tester.tap(key('profile-weight-save'));
      await tester.pump();
      commit.complete();
      await tester.pumpAndSettle();
      expect(values, [79.5, 79.5]);
      expect(key('profile-weight-input'), findsNothing);
    },
  );
}
