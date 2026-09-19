import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/eatova_home_page.dart';
import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/screens/today/today_screen.dart';
import 'package:eatova/src/services/health_service.dart';

import 'support/harness.dart';

class _Health extends NoopHealthService {
  HealthSnapshot? snapshot;

  @override
  HealthAuthState get authState => HealthAuthState.granted;

  @override
  Future<HealthAuthState> requestAuthorization() async => authState;

  @override
  Future<HealthSnapshot?> readSnapshot() async => snapshot;
}

Future<HomeStore> _pumpHome(WidgetTester tester, _Health health) async {
  pinPhoneViewport(tester);
  await pumpLocalized(
    tester,
    EatovaHomePage(initialUserName: 'Test', healthService: health),
    reducedMotion: false,
    scaffold: false,
    safeArea: false,
  );
  await tester.pumpAndSettle();
  return (tester.state(find.byType(EatovaHomePage)) as HomePageDebugAccess)
      .debugStore;
}

TodayScreen _today(WidgetTester tester) =>
    tester.widget<TodayScreen>(find.byType(TodayScreen));

void main() {
  testWidgets('open profile and Today stop displaying yesterday activity', (
    tester,
  ) async {
    var now = DateTime(2026, 9, 18, 23, 50);
    await withClock(Clock(() => now), () async {
      final yesterday = now;
      final health = _Health()
        ..snapshot = HealthSnapshot(stepsToday: 12000, fetchedAt: now);
      final store = await _pumpHome(tester, health);
      expect(_today(tester).steps, 12000);
      expect(_today(tester).burnedKcal, greaterThan(0));

      await tester.tap(find.byKey(const ValueKey('today-profile')));
      await tester.pumpAndSettle();
      expect(find.text('12000/8000'), findsOneWidget);

      health.snapshot = null;
      now = DateTime(2026, 9, 19, 0, 10);
      store.maybeRollOverToToday();
      await tester.pumpAndSettle();
      expect(find.text('12000/8000'), findsNothing);
      expect(find.text('–/8000'), findsOneWidget);
      expect(store.stepsForFoodDate(yesterday), 12000);

      await tester.tap(find.byKey(const ValueKey('profile-close')));
      await tester.pumpAndSettle();
      expect(_today(tester).steps, isNull);
      expect(_today(tester).burnedKcal, 0);

      health.snapshot = HealthSnapshot(stepsToday: 500, fetchedAt: now);
      await store.refreshHealthSteps();
      await tester.pumpAndSettle();
      expect(_today(tester).steps, 500);
      expect(_today(tester).burnedKcal, greaterThan(0));
    });
  });

  testWidgets('Today selector observes unknown becoming a measured zero', (
    tester,
  ) async {
    final now = DateTime(2026, 9, 19, 12);
    await withClock(Clock.fixed(now), () async {
      final health = _Health();
      final store = await _pumpHome(tester, health);
      expect(_today(tester).steps, isNull);

      // A cached aggregate is not proof that this session obtained a reading.
      store.dailyActivity = {'2026-09-19': (steps: 0, kcal: 0)};
      await store.refreshHealthSteps();
      await tester.pumpAndSettle();
      final activity = store.dailyActivity;
      expect(_today(tester).steps, isNull);

      health.snapshot = HealthSnapshot(stepsToday: 0, fetchedAt: now);
      await store.refreshHealthSteps();
      await tester.pumpAndSettle();
      expect(store.dailyActivity, same(activity));
      expect(_today(tester).steps, 0);
      expect(_today(tester).burnedKcal, 0);

      await tester.tap(find.byKey(const ValueKey('today-profile')));
      await tester.pumpAndSettle();
      expect(find.text('0/8000'), findsOneWidget);
    });
  });
}
