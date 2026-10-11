// The editor's save queues behind other plan writes and then waits for its
// delivery window. Only its close button was disabled meanwhile: a scrim
// tap, back or a pull on the handle closed the sheet, so the "saved" toast
// and any refusal or storage error were never shown.

import 'dart:async';

import 'package:clock/clock.dart';
import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/planned_meal.dart';
import 'package:eatova/src/screens/recipes/meal_plan_screen.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/services/sync_error_messages.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../outbox/outbox_test_helpers.dart' as h;
import '../support/harness.dart';

/// Holds every plan save until [gate] completes, then fails with [failure]
/// or saves.
class _GatedStore extends HomeStore {
  _GatedStore()
    : super(
        sync: null,
        health: const NoopHealthService(),
        notificationService: const NoopNotificationService(),
        initialUserName: 'Fixture',
        emitSnack: h.SnackCapture().call,
      );

  final Completer<void> gate = Completer<void>();
  Object? failure;

  @override
  Future<SyncDelivery> savePlannedMeal(PlannedMeal plan) async {
    await gate.future;
    final error = failure;
    if (error != null) throw error;
    return super.savePlannedMeal(plan);
  }
}

final _today = DateTime(2026, 9, 10, 12);

Finder get _save => find.byKey(const ValueKey('meal-plan-save'));

/// Opens the editor, picks the first catalog recipe and taps save.
Future<void> _startSave(WidgetTester tester, HomeStore store) async {
  await pumpLocalized(
    tester,
    MealPlanScreen(store: store),
    locale: const Locale('en'),
    // Tall enough that the sheet leaves scrim above it.
    surfaceSize: const Size(390, 1400),
  );
  await tester.tap(find.text('Plan a meal').first);
  await tester.pumpAndSettle();
  await tester.tap(find.text(recipeCatalogEn.first.title));
  await tester.pumpAndSettle();
  await tester.ensureVisible(_save);
  await tester.pumpAndSettle();
  await tester.tap(_save);
  await tester.pump();
  expect(find.text('Saving …'), findsOneWidget);
}

/// Scrim, Android back and a pull at the sheet's top edge.
Future<void> _tryToClose(WidgetTester tester) async {
  final top = tester.getTopLeft(find.byType(BottomSheet)).dy;
  expect(top, greaterThan(20), reason: 'room for a scrim tap');
  await tester.tapAt(Offset(20, top / 2));
  await tester.pumpAndSettle();
  expect(_save, findsOneWidget, reason: 'scrim');
  await tester.binding.handlePopRoute();
  await tester.pumpAndSettle();
  expect(_save, findsOneWidget, reason: 'back');
  await tester.flingFrom(Offset(195, top + 8), const Offset(0, 500), 2000);
  await tester.pumpAndSettle();
  expect(_save, findsOneWidget, reason: 'handle');
}

void main() {
  testWidgets('a save in flight keeps the editor and then confirms', (
    tester,
  ) async {
    final store = _GatedStore();
    addTearDown(store.dispose);
    await withClock(Clock.fixed(_today), () async {
      await _startSave(tester, store);
      await _tryToClose(tester);

      store.gate.complete();
      await tester.pumpAndSettle();
      expect(_save, findsNothing);
      expect(find.text('Saved.'), findsOneWidget);
      expect(store.plannedMeals, hasLength(1));
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('a refusal after a close attempt is still shown', (tester) async {
    final store = _GatedStore()..failure = const MealPlanLimitReached();
    addTearDown(store.dispose);
    await withClock(Clock.fixed(_today), () async {
      await _startSave(tester, store);
      await _tryToClose(tester);

      store.gate.complete();
      await tester.pumpAndSettle();
      expect(_save, findsOneWidget);
      await tester.ensureVisible(_save);
      expect(
        find.text(
          'You already have 500 open planned meals. '
          'Remove some to plan more.',
        ),
        findsOneWidget,
      );
      expect(store.plannedMeals, isEmpty);
      expect(tester.takeException(), isNull);
    });
  });
}
