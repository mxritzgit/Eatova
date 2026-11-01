// Cooking mode (feature review P6): from a recipe with at least two steps,
// one step per page in large type, a timer button per time a step names,
// the display kept on while cooking. A running timer rings with the phone
// locked through the training rests' local alert; one from the meal plan
// ends with "Log as eaten" through the plan.

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/app/timer_alerts_scope.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/planned_meal.dart';
import 'package:eatova/src/screens/recipes/meal_plan_screen.dart';
import 'package:eatova/src/screens/recipes/recipes_screen.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/services/rest_alerts.dart';
import 'package:eatova/src/services/screen_awake.dart';

import '../outbox/outbox_test_helpers.dart' as h;
import '../support/harness.dart';
import '../support/pinned_clock.dart';

const MethodChannel _screen = MethodChannel('eatova/screen');

/// The app's notification service as far as timers go: alerts by id, cues.
class _Alerts extends NoopNotificationService
    implements RestAlertScheduler, RestAlertCue, RestAlertPermissionGate {
  final Map<int, DateTime> pending = {};
  final List<int> cues = [];

  @override
  Future<void> scheduleRestAlert({
    required int id,
    required DateTime at,
    required String title,
    required String body,
  }) async {
    pending[id] = at;
  }

  @override
  Future<void> cancelRestAlert(int id) async {
    pending.remove(id);
  }

  @override
  Future<void> cueRestAlert({
    required int id,
    required String title,
    required String body,
  }) async {
    cues.add(id);
  }

  @override
  Future<RestAlertPermission> state() async => RestAlertPermission.granted;

  @override
  Future<bool> request() async => true;
}

FitnessRecipe _own(String preparation) => FitnessRecipe(
  slug: 'user_pasta',
  title: 'Pasta',
  description: '',
  portion: '1 Teller',
  ingredients: '200 g Nudeln\n1 Prise Salz',
  preparation: preparation,
  professionalHint: '',
  imageAsset: '',
  caloriesKcal: 520,
  proteinG: 20,
  carbsG: 80,
  fatG: 10,
  estimatedGrams: 400,
  categories: const ['Eigene'],
  userCreated: true,
);

Finder _key(String key) => find.byKey(ValueKey(key));

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  setUp(MethodChannelScreenAwake.debugReset);
  tearDown(MethodChannelScreenAwake.debugReset);

  testWidgets('Kochmodus: Schritte blättern, Timer-Knopf, Alarm und '
      'Bildschirm an, beim Verlassen beides wieder aus', (tester) async {
    await withClockAt(DateTime(2026, 11, 1, 12), () async {
      final awake = <Object?>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        _screen,
        (call) async {
          awake.add(call.arguments);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          _screen,
          null,
        ),
      );
      final alerts = _Alerts();
      // The narrowest phone and the largest text: the mode must stay usable.
      tester.view.physicalSize =
          const Size(320, 640) * tester.view.devicePixelRatio;
      addTearDown(tester.view.resetPhysicalSize);
      await tester.pumpWidget(
        TimerAlertsScope(
          notifications: alerts,
          child: localizedApp(
            RecipeDetailScreen(
              recipe: _own(
                '1. Wasser aufsetzen.\n'
                '2. Nudeln 10 Minuten kochen.\n'
                '3. Abgießen und servieren.',
              ),
              onAddMeal: (_, _) {},
            ),
            textScale: 2,
          ),
        ),
      );

      await _tap(tester, _key('recipe-detail-cook'));
      expect(awake, [
        {'on': true},
      ]);
      expect(find.text(deL10n.cookingModeStepOf(1, 3)), findsOneWidget);
      expect(find.text('Wasser aufsetzen.'), findsOneWidget);
      expect(_key('cooking-timer-start-0'), findsNothing);

      // Swiping forward reaches the step with a time and its timer.
      await tester.fling(_key('cooking-pages'), const Offset(-300, 0), 1000);
      await tester.pumpAndSettle();
      expect(find.text(deL10n.cookingModeStepOf(2, 3)), findsOneWidget);
      final start = _key('cooking-timer-start-0');
      expect(
        find.descendant(of: start, matching: find.text('10 Minuten')),
        findsOneWidget,
      );
      await tester.ensureVisible(start);
      await tester.pumpAndSettle();
      final startedAt = clock.now();
      await tester.tap(start);
      await tester.pump();
      final id = alerts.pending.keys.single;
      expect(isCookingTimerId(id), isTrue);
      expect(alerts.pending[id], startedAt.add(const Duration(minutes: 10)));

      // Leaving with a timer running asks first.
      await _tap(tester, _key('cooking-close'));
      expect(_key('cooking-leave-dialog'), findsOneWidget);
      await _tap(tester, _key('cooking-leave-stay'));
      expect(find.text(deL10n.cookingModeStepOf(2, 3)), findsOneWidget);

      // The deadline in front rings in the app; the late alert is dropped.
      await tester.pump(const Duration(minutes: 10));
      await tester.pumpAndSettle();
      expect(alerts.cues, [id]);
      expect(alerts.pending, isEmpty);
      expect(find.text(deL10n.cookingTimerUp), findsOneWidget);

      // Buttons step too; the last step ends with "Done", without a dialog.
      await _tap(tester, _key('cooking-next'));
      expect(find.text(deL10n.cookingModeStepOf(3, 3)), findsOneWidget);
      await _tap(tester, _key('cooking-done'));
      expect(_key('cooking-pages'), findsNothing);
      expect(_key('recipe-detail-cook'), findsOneWidget);
      expect(awake, [
        {'on': true},
        {'on': false},
      ]);
    });
  });

  testWidgets('aus dem Speiseplan endet er mit „Als gegessen eintragen" über '
      'den Plan und kehrt dorthin zurück', (tester) async {
    await withClock(Clock.fixed(DateTime(2026, 9, 7, 12)), () async {
      final store = HomeStore(
        sync: null,
        health: const NoopHealthService(),
        notificationService: const NoopNotificationService(),
        initialUserName: 'Fixture',
        emitSnack: h.SnackCapture().call,
      );
      addTearDown(store.dispose);
      await store.savePlannedMeal(
        PlannedMeal.create(
          recipe: recipeCatalogEn.firstWhere(
            (r) => r.slug == 'lachs_mit_sukartoffel_and_spargel',
          ),
          day: DateTime(2026, 9, 7),
          slot: MealSlot.dinner,
          servings: 2,
        ),
      );
      final plan = store.plannedMeals.single;
      await pumpLocalized(
        tester,
        MealPlanScreen(store: store),
        locale: const Locale('en'),
        surfaceSize: const Size(393, 852),
      );

      await _tap(tester, _key('meal-plan-open-${plan.id}'));
      await _tap(tester, _key('recipe-detail-cook'));
      while (_key('cooking-next').evaluate().isNotEmpty) {
        await _tap(tester, _key('cooking-next'));
      }
      expect(_key('cooking-done'), findsNothing);
      await _tap(tester, _key('cooking-eat'));

      expect(store.plannedMeals.single.isEaten, isTrue);
      expect(store.loggedMeals.single.id, plan.id);
      expect(find.byType(RecipeDetailScreen), findsNothing);
      expect(_key('meal-plan-eaten-${plan.id}'), findsOneWidget);
    });
  });

  testWidgets('ohne mindestens zwei Schritte gibt es keinen Kochmodus', (
    tester,
  ) async {
    final cases = {
      '1. Alles mischen.\n2. Servieren.': true,
      'Alles mischen und servieren.': false,
      '': false,
    };
    for (final MapEntry(key: preparation, value: offered) in cases.entries) {
      await pumpLocalized(
        tester,
        RecipeDetailScreen(
          key: ValueKey(preparation),
          recipe: _own(preparation),
          onAddMeal: (_, _) {},
        ),
      );
      expect(
        _key('recipe-detail-cook'),
        offered ? findsOneWidget : findsNothing,
        reason: preparation,
      );
    }
  });
}
