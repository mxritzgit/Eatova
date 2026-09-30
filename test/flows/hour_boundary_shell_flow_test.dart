// Final review A-I1 (2026-09-30): the next meal slot follows the clock alone
// (lunch ends at 15:00, dinner at 21:00). Through the REAL shell, every tab
// that shows the recipe pick or the accent slot — Today, Food, Recipes, and
// Coach as before — moves on at an hour boundary without any store change:
// on the hour tick while the app stays open, and on resume after the phone
// slept. Before the fix only Coach listened to the clock, so Today, Food and
// the Recipes hero kept lunch, and the hero's add logged into lunch at 15:30.

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/eatova_home_page.dart';
import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/screens/meal_analysis_screen.dart';
import 'package:eatova/src/screens/recipes/recipes_screen.dart';
import 'package:eatova/src/screens/today/today_screen.dart';

import '../support/harness.dart';
import 'flow_test_helpers.dart'
    show FakeProductLookupService, pumpUntil, settleFrames, storeOf;

const UserProfile _profile = UserProfile(
  weightKg: 80,
  heightCm: 180,
  dailyKcalGoal: 2123,
  proteinGoalG: 162,
  onboardingCompleted: true,
  manualEnergy: true,
);

const int _today = 0;
const int _food = 1;
const int _recipes = 2;
const int _training = 3;
const int _coach = 4;

/// The signed-out shell with every tab mounted once, ending on [endOn].
Future<HomeStore> _pumpShell(WidgetTester tester, {required int endOn}) async {
  pinPhoneViewport(tester);
  await pumpLocalized(
    tester,
    EatovaHomePage(productService: FakeProductLookupService()),
    locale: const Locale('en'),
    scaffold: false,
    safeArea: false,
  );
  await pumpUntil(
    tester,
    () => find.byKey(const ValueKey('screen-welcome')).evaluate().isEmpty,
    'boot completes',
  );
  final store = storeOf(tester);
  store.profile = _profile;
  for (final tab in [_today, _food, _recipes, _training, _coach, endOn]) {
    store.setTab(tab);
    await settleFrames(tester);
  }
  return store;
}

/// The slot each tab currently shows (null = no pick / no accent), read from
/// the built screens, hidden tabs included.
({MealSlot? todayPick, MealSlot? accent, MealSlot? foodPick, MealSlot? hero})
_shown(WidgetTester tester) {
  T screen<T extends Widget>() =>
      tester.widget<T>(find.byType(T, skipOffstage: false));
  final today = screen<TodayScreen>();
  return (
    todayPick: today.pick?.slot,
    accent: today.accentSlot,
    foodPick: screen<MealAnalysisScreen>().recipePick?.slot,
    hero: screen<RecipesScreen>().mealPick?.slot,
  );
}

void _expectEverywhere(WidgetTester tester, MealSlot? slot, String when) {
  expect(_shown(tester), (
    todayPick: slot,
    accent: slot,
    foodPick: slot,
    hero: slot,
  ), reason: when);
}

AppLocalizations _l10n(WidgetTester tester) =>
    tester.element(find.byType(EatovaHomePage)).l10n;

/// A phone put away and picked up again: the app goes through every
/// background state and comes back.
void _sleepAndResume(WidgetTester tester) {
  for (final state in [
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
    AppLifecycleState.hidden,
    AppLifecycleState.inactive,
    AppLifecycleState.resumed,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(state);
  }
}

void main() {
  testWidgets('left open across 15:00 and 21:00, every tab moves on with '
      'the hour tick alone', (tester) async {
    var now = DateTime(2026, 9, 28, 14, 10);
    await withClock(Clock(() => now), () async {
      // The Recipes tab stays in front: nothing below changes the store.
      await _pumpShell(tester, endOn: _recipes);
      final l10n = _l10n(tester);
      _expectEverywhere(tester, MealSlot.lunch, '14:10: lunch is open');
      expect(find.text(l10n.recipesHeroAddToSlot('lunch')), findsOneWidget);

      // The hour ticker fires a second after 15:00 (armed at 14:10).
      now = DateTime(2026, 9, 28, 15, 0, 30);
      await tester.pump(const Duration(minutes: 51));
      await settleFrames(tester);
      _expectEverywhere(tester, MealSlot.dinner, 'lunch is over at 15:00');
      expect(find.text(l10n.recipesHeroAddToSlot('dinner')), findsOneWidget);

      now = DateTime(2026, 9, 28, 21, 0, 30);
      await tester.pump(const Duration(minutes: 61));
      await settleFrames(tester);
      _expectEverywhere(tester, null, 'no main meal is ahead from 21:00');
      expect(find.text(l10n.recipesHeroAddToSlot('dinner')), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  testWidgets('after device sleep over 15:00, the resume moves every tab to '
      'dinner, and the Recipes hero logs into dinner', (tester) async {
    var now = DateTime(2026, 9, 28, 14, 10);
    await withClock(Clock(() => now), () async {
      final store = await _pumpShell(tester, endOn: _recipes);
      final l10n = _l10n(tester);
      _expectEverywhere(tester, MealSlot.lunch, '14:10: lunch is open');

      // Timers do not run while the phone sleeps: only the resume catches up.
      now = DateTime(2026, 9, 28, 15, 30);
      _sleepAndResume(tester);
      await settleFrames(tester);
      _expectEverywhere(tester, MealSlot.dinner, 'lunch is over at 15:00');

      // What the user sees on each tab, the hero first (switching tabs
      // notifies the store).
      expect(find.text(l10n.recipesHeroAddToSlot('dinner')), findsOneWidget);
      store.setTab(_today);
      await settleFrames(tester);
      expect(
        find.text(l10n.todayPickEyebrow('dinner').toUpperCase()),
        findsOneWidget,
      );
      store.setTab(_food);
      await settleFrames(tester);
      expect(find.textContaining('FITS TONIGHT'), findsOneWidget);

      // The hero's add logs the pick into today's dinner, not lunch.
      store.setTab(_recipes);
      await settleFrames(tester);
      await tester.tap(find.byKey(const ValueKey('recipe-hero-add')));
      await settleFrames(tester);
      expect(store.loggedMeals.single.slot, MealSlot.dinner);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
