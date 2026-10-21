// The step bonus reaches the trends page through the SHELL (F7-05, Review
// I-4): "goal hit" on Trends must use goal + step bonus like the Today tab,
// so the shell hands `burnedKcalFor: store.burnedKcalForFoodDate` to the
// TrendsScreen it pushes (`_openTrends` in eatova_home_page.dart).
//
// The suite used to check `MealAnalysisScreen.trendBurnedKcalFor` instead.
// The shell also passes `onOpenTrends`, and with it set the food tab never
// reads that prop — so the old check stayed green with the real wiring
// deleted. This one opens Trends the way the user does and reads the screen
// that is actually shown.
//
// Boots the real EatovaHomePage without sync (preview path) with a health
// double that reports steps.

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/eatova_home_page.dart';
import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/screens/trends_screen.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/trend_service.dart';

import '../support/harness.dart';

/// Health double with a fixed step count, so the store KNOWS activity today.
class _StepsHealth implements HealthService {
  @override
  HealthAuthState get authState => HealthAuthState.granted;

  @override
  Future<HealthAuthState> requestAuthorization() async =>
      HealthAuthState.granted;

  @override
  Future<HealthSnapshot?> readSnapshot() async =>
      HealthSnapshot(stepsToday: 7000, fetchedAt: clock.now());

  @override
  void reset() {}

  @override
  Future<bool> writeWeight(double kg, DateTime when) async => false;

  @override
  Future<int?> readStepsOnDay(DateTime day) async => null;
}

HomeStore _storeOf(WidgetTester tester) =>
    (tester.state(find.byType(EatovaHomePage)) as HomePageDebugAccess)
        .debugStore;

/// Frames without `pumpAndSettle`: the shell carries endless animations.
Future<void> _pumpFrames(WidgetTester tester, {int frames = 12}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 40));
  }
}

/// Midday of a fixed day, far from any midnight.
final DateTime _mittag = DateTime(2026, 8, 27, 12);

void main() {
  testWidgets('die Trends aus der Schale rechnen mit dem Schritt-Bonus des '
      'Stores', (tester) async {
    await withClock(Clock.fixed(_mittag), () async {
      tester.view.physicalSize = const Size(1179, 2556);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      // Headless font metrics produce overflows that never happen on a
      // device (same reasoning as test/flows/flow_test_helpers.dart).
      final prior = FlutterError.onError;
      FlutterError.onError = (details) {
        if (details.exception.toString().contains('overflowed')) return;
        prior?.call(details);
      };
      addTearDown(() => FlutterError.onError = prior);

      await pumpLocalized(
        tester,
        EatovaHomePage(
          healthService: _StepsHealth(),
          // No Supabase in this test: the server window is empty.
          trendTotalsLoader: () async => const <TrendDayTotals>[],
        ),
        reducedMotion: false,
        scaffold: false,
        safeArea: false,
      );
      await _pumpFrames(tester);

      final store = _storeOf(tester);
      final heute = clock.now();
      expect(store.dailySteps, 7000,
          reason: 'Vorbedingung: der Boot-Refresh hat die Schritte geliefert');
      final erwartet = store.burnedKcalForFoodDate(heute);
      expect(erwartet, greaterThan(0), reason: 'Vorbedingung: es gibt Bonus');

      // The way the user goes: the food tab's header button.
      store.setTab(1);
      await _pumpFrames(tester);
      await tester.tap(find.byKey(const ValueKey('food-trends')));
      await _pumpFrames(tester);

      final trends = tester.widget<TrendsScreen>(find.byType(TrendsScreen));
      expect(
        trends.burnedKcalFor(heute),
        erwartet,
        reason: 'ohne die Bonus-Quelle rechnen die Trends gegen das '
            'Basisziel, obwohl der Heute-Tab den Bonus zeigt (F7-05)',
      );
      expect(tester.takeException(), isNull);
    });
  });
}
