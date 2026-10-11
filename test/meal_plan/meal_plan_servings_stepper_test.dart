import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/recipe_catalog_de.dart';
import 'package:eatova/src/models/recipe_catalog_en.dart';
import 'package:eatova/src/screens/recipes/meal_plan_screen.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/notification_service.dart';

import '../outbox/outbox_test_helpers.dart' as h;
import '../support/harness.dart';

// The plan editor's servings stepper: minus and plus move by half a serving
// within 0.5..100, snap an off-grid entry to the grid, write the locale's
// separator and stop at the ends.

final _heute = DateTime(2026, 9, 10, 12);

final _feld = find.byKey(const ValueKey('meal-plan-servings'));
final _minus = find.byKey(const ValueKey('meal-plan-servings-dec'));
final _plus = find.byKey(const ValueKey('meal-plan-servings-inc'));

String _wert(WidgetTester tester) =>
    tester.widget<TextField>(_feld).controller!.text;

bool _aktiv(WidgetTester tester, Finder button) =>
    tester.widget<InkWell>(button).onTap != null;

Future<void> _tippe(WidgetTester tester, Finder button) async {
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pumpAndSettle();
}

Future<HomeStore> _oeffneEditor(WidgetTester tester, Locale locale) async {
  final store = HomeStore(
    sync: null,
    health: const NoopHealthService(),
    notificationService: const NoopNotificationService(),
    initialUserName: 'Fixture',
    emitSnack: h.SnackCapture().call,
  );
  addTearDown(store.dispose);
  final l10n = lookupAppLocalizations(locale);
  await pumpLocalized(
    tester,
    MealPlanScreen(store: store),
    locale: locale,
    surfaceSize: const Size(390, 850),
  );
  await tester.tap(find.text(l10n.mealPlanAdd).first);
  await tester.pumpAndSettle();
  await tester.tap(
    find.text(
      locale.languageCode == 'de'
          ? recipeCatalogDe.first.title
          : recipeCatalogEn.first.title,
    ),
  );
  await tester.pumpAndSettle();
  await tester.ensureVisible(_feld);
  return store;
}

void main() {
  testWidgets('Portionen: Plus und Minus in halben Schritten, mit Komma', (
    tester,
  ) async {
    await withClock(Clock.fixed(_heute), () async {
      final store = await _oeffneEditor(tester, const Locale('de'));
      expect(_wert(tester), '1');

      await _tippe(tester, _plus);
      expect(_wert(tester), '1,5', reason: 'deutsches Komma');
      await _tippe(tester, _plus);
      expect(_wert(tester), '2');
      await _tippe(tester, _minus);
      await _tippe(tester, _minus);
      await _tippe(tester, _minus);
      expect(_wert(tester), '0,5');

      // 0.5 is the lower end: minus stops, plus still steps.
      expect(_aktiv(tester, _minus), isFalse);
      expect(_aktiv(tester, _plus), isTrue);
      await _tippe(tester, _minus);
      expect(_wert(tester), '0,5');

      // The stepped value is what gets planned.
      await _tippe(tester, _plus);
      final speichern = find.byKey(const ValueKey('meal-plan-save'));
      await tester.ensureVisible(speichern);
      await tester.tap(speichern);
      await tester.pumpAndSettle();
      expect(store.plannedMeals.single.servings, 1);
    });
  });

  testWidgets('servings: an off-grid entry snaps to the next half', (
    tester,
  ) async {
    await withClock(Clock.fixed(_heute), () async {
      await _oeffneEditor(tester, const Locale('en'));

      await tester.enterText(_feld, '1.25');
      await tester.pumpAndSettle();
      await _tippe(tester, _plus);
      expect(_wert(tester), '1.5', reason: 'up from 1.25');

      await tester.enterText(_feld, '1.25');
      await tester.pumpAndSettle();
      await _tippe(tester, _minus);
      expect(_wert(tester), '1', reason: 'down from 1.25');

      // Below the first half step there is nothing lower to step to.
      await tester.enterText(_feld, '0.3');
      await tester.pumpAndSettle();
      expect(_aktiv(tester, _minus), isFalse);
      await _tippe(tester, _plus);
      expect(_wert(tester), '0.5');
    });
  });

  testWidgets('servings: 100 is the upper end, an invalid entry stops both', (
    tester,
  ) async {
    await withClock(Clock.fixed(_heute), () async {
      await _oeffneEditor(tester, const Locale('en'));

      await tester.enterText(_feld, '99.5');
      await tester.pumpAndSettle();
      await _tippe(tester, _plus);
      expect(_wert(tester), '100');
      expect(_aktiv(tester, _plus), isFalse);
      await _tippe(tester, _plus);
      expect(_wert(tester), '100');
      await _tippe(tester, _minus);
      expect(_wert(tester), '99.5');

      // No guess from an unreadable value: neither button moves it.
      await tester.enterText(_feld, 'abc');
      await tester.pumpAndSettle();
      expect(_aktiv(tester, _plus), isFalse);
      expect(_aktiv(tester, _minus), isFalse);
      expect(_wert(tester), 'abc');
    });
  });
}
