import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/widgets/common/app_snack.dart';

class _IosHealth extends NoopHealthService {
  HealthSnapshot? snapshot;
  Future<HealthSnapshot?> Function()? read;
  HealthAuthState state = HealthAuthState.granted;
  int reads = 0;

  @override
  HealthAuthState get authState => state;

  @override
  Future<HealthSnapshot?> readSnapshot() async {
    reads++;
    return read == null ? snapshot : await read!();
  }

  @override
  void reset() => state = HealthAuthState.unknown;
}

HomeStore _store(_IosHealth health, {bool autoDispose = true}) {
  final store = HomeStore(
    sync: null,
    health: health,
    notificationService: const NoopNotificationService(),
    initialUserName: 'Test',
    emitSnack:
        (
          _, {
          IconData icon = Icons.info_outline,
          SnackTone tone = SnackTone.positive,
          Duration? duration,
          SnackBarAction? action,
        }) {},
  );
  if (autoDispose) addTearDown(store.dispose);
  return store;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'failed next-day iOS read preserves history without crediting today',
    () async {
      var now = DateTime(2026, 9, 18, 23, 50);
      await withClock(Clock(() => now), () async {
        final measuredAt = now;
        final health = _IosHealth()
          ..snapshot = HealthSnapshot(stepsToday: 12000, fetchedAt: measuredAt);
        final store = _store(health);
        await store.refreshHealthSteps();
        final previousKcal = store.burnedKcalForFoodDate(now);
        expect(previousKcal, greaterThan(0));

        now = DateTime(2026, 9, 19, 8);
        expect(store.maybeRollOverToToday(), isTrue);
        health.snapshot = null;
        await store.refreshHealthSteps();

        expect(store.dailySteps, 12000);
        expect(store.healthLastFetch, measuredAt);
        expect(store.stepsForFoodDate(measuredAt), 12000);
        expect(store.burnedKcalForFoodDate(measuredAt), previousKcal);
        expect(store.dailyActivity, isNot(contains('2026-09-19')));
        expect(store.stepsForFoodDate(now), isNull);
        expect(store.burnedKcalForFoodDate(now), 0);

        health.snapshot = HealthSnapshot(stepsToday: 1500, fetchedAt: now);
        await store.refreshHealthSteps();
        expect(store.stepsForFoodDate(now), 1500);
        expect(store.burnedKcalForFoodDate(now), greaterThan(0));
        expect(store.stepsForFoodDate(measuredAt), 12000);
      });
    },
  );

  test('late previous-day snapshot never becomes today activity', () async {
    var now = DateTime(2026, 9, 18, 23, 59);
    await withClock(Clock(() => now), () async {
      final requestedAt = now;
      final response = Completer<HealthSnapshot?>();
      final health = _IosHealth()..read = () => response.future;
      final store = _store(health);
      final refresh = store.refreshHealthSteps();
      expect(store.healthSyncing, isTrue);

      now = DateTime(2026, 9, 19, 0, 1);
      store.maybeRollOverToToday();
      response.complete(
        HealthSnapshot(stepsToday: 9000, fetchedAt: requestedAt),
      );
      await refresh;

      expect(store.healthSyncing, isFalse);
      expect(store.healthLastFetch, requestedAt);
      expect(store.stepsForFoodDate(requestedAt), 9000);
      expect(store.burnedKcalForFoodDate(requestedAt), greaterThan(0));
      expect(store.stepsForFoodDate(now), isNull);
      expect(store.burnedKcalForFoodDate(now), 0);
      expect(store.dailyActivity, isNot(contains('2026-09-19')));
    });
  });

  test(
    'same-day iOS failure retains its real measurement and timestamp',
    () async {
      var now = DateTime(2026, 9, 19, 12);
      await withClock(Clock(() => now), () async {
        final measuredAt = now;
        final health = _IosHealth()
          ..snapshot = HealthSnapshot(stepsToday: 4500, fetchedAt: measuredAt);
        final store = _store(health);
        await store.refreshHealthSteps();
        final activity = store.dailyActivity;
        final kcal = store.burnedKcalForFoodDate(now);

        now = now.add(const Duration(hours: 1));
        health
          ..snapshot = null
          ..state = HealthAuthState.unverified;
        await store.refreshHealthSteps();

        expect(store.healthAuthState, HealthAuthState.unverified);
        expect(store.healthLastFetch, measuredAt);
        expect(store.dailyActivity, same(activity));
        expect(store.stepsForFoodDate(now), 4500);
        expect(store.burnedKcalForFoodDate(now), kcal);
        expect(health.reads, 2, reason: 'Same-day failure must not retry.');
      });
    },
  );

  for (final secondDayChange in [false, true]) {
    test('late read catches up once across midnight (second rollover: '
        '$secondDayChange)', () async {
      var now = DateTime(2026, 9, 18, 23, 59);
      await withClock(Clock(() => now), () async {
        final firstDay = now;
        final first = Completer<HealthSnapshot?>();
        final second = Completer<HealthSnapshot?>();
        final health = _IosHealth();
        health.read = () => health.reads == 1 ? first.future : second.future;
        addTearDown(() {
          if (!second.isCompleted) second.complete(null);
        });
        final store = _store(health);
        final refresh = store.refreshHealthSteps();
        expect(health.reads, 1);
        now = DateTime(2026, 9, 19, 0, 1);
        store.maybeRollOverToToday();
        first.complete(HealthSnapshot(stepsToday: 9000, fetchedAt: firstDay));
        await pumpEventQueue();
        expect(
          health.reads,
          2,
          reason: 'The refresh requested during midnight must not be lost.',
        );
        expect(store.stepsForFoodDate(now), isNull);
        expect(store.stepsForFoodDate(firstDay), 9000);
        final secondDay = now;
        if (secondDayChange) now = DateTime(2026, 9, 20, 0, 1);
        second.complete(HealthSnapshot(stepsToday: 500, fetchedAt: secondDay));
        await refresh;

        expect(
          health.reads,
          2,
          reason: 'Day catch-up is bounded to one retry.',
        );
        expect(store.healthSyncing, isFalse);
        expect(store.stepsForFoodDate(now), secondDayChange ? isNull : 500);
        expect(store.stepsForFoodDate(secondDay), 500);
      });
    });
  }

  for (final state in [HealthAuthState.unknown, HealthAuthState.granted]) {
    test('$state without a snapshot never invents a measured zero', () async {
      final now = DateTime(2026, 9, 19, 12);
      await withClock(Clock.fixed(now), () async {
        final store = _store(_IosHealth()..state = state);
        await store.refreshHealthSteps();
        expect(store.healthAuthState, state);
        expect(store.healthLastFetch, isNull);
        expect(store.stepsForFoodDate(now), isNull);
        expect(store.burnedKcalForFoodDate(now), 0);
        expect(store.dailyActivity, isEmpty);
        expect((store.health as _IosHealth).reads, 1);
      });
    });
  }

  test('a measured zero is known only on its measurement day', () async {
    var now = DateTime(2026, 9, 19, 0, 10);
    await withClock(Clock(() => now), () async {
      final measuredAt = now;
      final health = _IosHealth()
        ..snapshot = HealthSnapshot(stepsToday: 0, fetchedAt: now);
      final store = _store(health);
      await store.refreshHealthSteps();
      expect(store.stepsForFoodDate(now), 0);
      expect(store.dailyActivity['2026-09-19'], (steps: 0, kcal: 0));

      health.snapshot = null;
      await store.refreshHealthSteps();
      expect(store.stepsForFoodDate(now), 0);
      expect(store.healthLastFetch, measuredAt);

      now = DateTime(2026, 9, 20, 0, 10);
      store.maybeRollOverToToday();
      expect(store.stepsForFoodDate(now), isNull);
      expect(store.stepsForFoodDate(measuredAt), 0);
    });
  });

  test(
    'ending the account session invalidates even a same-day snapshot',
    () async {
      final now = DateTime(2026, 9, 19, 12);
      await withClock(Clock.fixed(now), () async {
        final health = _IosHealth()
          ..snapshot = HealthSnapshot(stepsToday: 12000, fetchedAt: now);
        final store = _store(health);
        await store.refreshHealthSteps();
        expect(store.stepsForFoodDate(now), 12000);
        await store.signOutCleanup();
        expect(store.stepsForFoodDate(now), isNull);
        expect(store.burnedKcalForFoodDate(now), 0);
      });
    },
  );

  for (final dispose in [false, true]) {
    test('session end fences midnight catch-up (dispose: $dispose)', () async {
      var now = DateTime(2026, 9, 18, 23, 59);
      await withClock(Clock(() => now), () async {
        final requestedAt = now;
        final response = Completer<HealthSnapshot?>();
        final health = _IosHealth()..read = () => response.future;
        final store = _store(health, autoDispose: !dispose);
        final refresh = store.refreshHealthSteps();
        now = DateTime(2026, 9, 19, 0, 1);
        if (dispose) {
          store.dispose();
        } else {
          await store.signOutCleanup();
        }
        response.complete(
          HealthSnapshot(stepsToday: 12000, fetchedAt: requestedAt),
        );
        await refresh;
        expect(health.reads, 1);
        expect(store.dailyActivity, isEmpty);
        expect(store.stepsForFoodDate(now), isNull);
      });
    });
  }
}
