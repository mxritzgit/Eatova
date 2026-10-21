// The trends page's six-month step backfill (review 2026-10-19, section 5):
// all days it finds land in ONE notify and ONE encrypted cache write instead
// of one each, and on Android it reads only the days Health Connect can
// answer without the history permission Eatova never requests: back to 30
// days before the account connected.

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/local_day.dart';

import '../outbox/outbox_test_helpers.dart';

final DateTime _now = DateTime(2026, 10, 19, 12, 30);

DateTime _day(int back) => DateTime(2026, 10, 19 - back);

class _Health implements HealthService {
  _Health(this.steps);

  /// Steps per local day key; a missing day reads as null.
  final Map<String, int> steps;
  final List<DateTime> reads = <DateTime>[];

  @override
  HealthAuthState get authState => HealthAuthState.granted;

  @override
  Future<HealthAuthState> requestAuthorization() async => authState;

  @override
  Future<HealthSnapshot?> readSnapshot() async => null;

  @override
  void reset() {}

  @override
  Future<bool> writeWeight(double kg, DateTime when) async => false;

  @override
  Future<int?> readStepsOnDay(DateTime day) async {
    reads.add(day);
    return steps[localDayKey(day)];
  }
}

class _HealthConnect extends _Health implements HealthConnectAccess {
  _HealthConnect(super.steps);

  @override
  Future<bool> openSettings() async => true;

  @override
  void restoreConnection() {}
}

/// Counts the encrypted cache writes of the daily-activity slot, for an
/// account that connected Apple Health itself.
class _CountingStore extends InMemoryKeyValueStore {
  _CountingStore() : super(healthConnectedKv().snapshot);

  int activityWrites = 0;

  @override
  Future<void> setString(String key, String value) {
    if (key.startsWith('eatova.v1.daily_activity.')) activityWrites++;
    return super.setString(key, value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('found days land in one notify and one cache write', () => withClock(Clock.fixed(_now), () async {
    // Older than the weekly check's 21-day window, which the boot reads.
    final found = [24, 26, 30, 45, 90, 150];
    final health = _Health({
      for (final back in found) localDayKey(_day(back)): 1000 * back,
    });
    final kv = _CountingStore();
    final a = setup(kv: kv, health: health);
    a.server.profileRow = serverProfileRow(testProfile());
    await boot(a.store);
    await settle();
    final writesBefore = kv.activityWrites;
    var notifies = 0;
    a.store.addListener(() => notifies++);

    await a.store.backfillStepsForTrends(181);
    await settle();

    for (final back in found) {
      expect(a.store.stepsForFoodDate(_day(back)), 1000 * back, reason: '$back');
    }
    expect(kv.activityWrites - writesBefore, 1);
    expect(notifies, 1);
    final cached = await LocalCache(kv, 'user-outbox').readDailyActivity();
    expect(cached![localDayKey(_day(150))]?.steps, 150000);

    // Once per session: a second pass reads and writes nothing.
    health.reads.clear();
    await a.store.backfillStepsForTrends(181);
    await settle();
    expect(health.reads, isEmpty);
    expect(kv.activityWrites - writesBefore, 1);
  }));

  test('without findings nothing is written', () => withClock(Clock.fixed(_now), () async {
    final kv = _CountingStore();
    final a = setup(kv: kv, health: _Health(const {}));
    a.server.profileRow = serverProfileRow(testProfile());
    await boot(a.store);
    await settle();
    final writesBefore = kv.activityWrites;
    final activity = a.store.dailyActivity;

    await a.store.backfillStepsForTrends(60);
    await settle();

    expect(kv.activityWrites, writesBefore);
    expect(identical(a.store.dailyActivity, activity), isTrue);
  }));

  test('Health Connect: only the days it can answer are asked', () => withClock(Clock.fixed(_now), () async {
    // Readable: 30 days before the first grant, so a connection 60 days old
    // reaches 90 days back. An opt-in an older build stored has no date and
    // counts from today.
    for (final (connected, readable) in [(null, 30), (_day(60), 90)]) {
      final health = _HealthConnect({
        for (var back = 1; back <= 180; back++) localDayKey(_day(back)): 5000,
      });
      final a = setup(
        kv: InMemoryKeyValueStore({
          if (connected != null)
            'eatova.v1.health_connect_enabled.user-outbox':
                '{"enabled":true,"since":"${connected.toUtc().toIso8601String()}"}',
        }),
        health: health,
      );
      a.server.profileRow = serverProfileRow(testProfile());
      await boot(a.store);
      await settle();
      health.reads.clear();

      await a.store.backfillStepsForTrends(181);
      await settle();

      final asked = {
        for (final day in health.reads) localDayKey(day),
        for (final key in a.store.dailyActivity.keys) key,
      };
      expect(
        asked,
        {for (var back = 1; back <= readable; back++) localDayKey(_day(back))},
        reason: 'connected $connected',
      );
      expect(a.store.stepsForFoodDate(_day(readable)), 5000);
      expect(a.store.stepsForFoodDate(_day(readable + 1)), isNull);
    }
  }));

  test('Apple Health reads the whole range', () => withClock(Clock.fixed(_now), () async {
    final health = _Health(const {});
    final a = setup(kv: healthConnectedKv(), health: health);
    a.server.profileRow = serverProfileRow(testProfile());
    await boot(a.store);
    await settle();
    health.reads.clear();

    await a.store.backfillStepsForTrends(181);
    await settle();

    expect(health.reads.map(localDayKey), contains(localDayKey(_day(180))));
  }));
}
