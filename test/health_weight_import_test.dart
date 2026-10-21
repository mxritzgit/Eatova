// The scale import (review 2026-10-22): weigh-ins from Apple Health or Health
// Connect come into the weight log only after the account's one-time
// opt-in, then by themselves on every read. Each keeps its measurement time,
// nothing is written back, duplicates and out-of-range values stay out, a
// deleted import stays deleted, and a failed commit consumes nothing.

import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/local_cache.dart';

import 'outbox/outbox_test_helpers.dart';

final DateTime _now = DateTime(2026, 10, 22, 12);

DateTime _at(int day, int hour, [int minute = 0]) =>
    DateTime(2026, 10, day, hour, minute);

/// A connected health store with a scale: its weigh-ins, and what the store
/// writes back.
class _Scale implements HealthService, HealthWeightSource {
  List<WeightSample> samples = <WeightSample>[];
  int writes = 0;
  bool weightAccess = true;

  @override
  HealthAuthState get authState => HealthAuthState.granted;

  @override
  void reset() {}

  @override
  Future<HealthAuthState> requestAuthorization() async => authState;

  @override
  Future<HealthSnapshot?> readSnapshot() async =>
      HealthSnapshot(stepsToday: 4200, fetchedAt: clock.now());

  @override
  Future<int?> readStepsOnDay(DateTime day) async => null;

  @override
  Future<bool> writeWeight(double kg, DateTime when) async {
    writes++;
    return true;
  }

  @override
  Future<List<WeightSample>?> readWeightSamples(
    DateTime from,
    DateTime to,
  ) async => [
    for (final s in samples)
      if (!s.measuredAt.isBefore(from) && !s.measuredAt.isAfter(to)) s,
  ];

  @override
  Future<bool> ensureWeightAccess() async => weightAccess;
}

class _HealthConnectScale extends _Scale implements HealthConnectAccess {
  @override
  Future<bool> openSettings() async => true;

  @override
  void restoreConnection() {}
}

/// The weight log commit can fail or be held, like a full or slow disk.
class _WeightCommitStore extends InMemoryKeyValueStore {
  _WeightCommitStore(super.initial);

  bool rejectWeightCommits = false;
  Completer<void>? heldCommit;
  int weightCommitAttempts = 0;

  @override
  Future<KeyValueCommit> writeBatch(
    Map<String, String?> changes, {
    Map<String, int> expectedVersions = const {},
  }) async {
    const weightsKey = 'eatova.v1.weight_log.user-outbox';
    final weights = changes[weightsKey];
    if (weights != null && weights != snapshot[weightsKey]) {
      weightCommitAttempts++;
      await heldCommit?.future;
      if (rejectWeightCommits) throw StateError('Injected local write failure');
    }
    return super.writeBatch(changes, expectedVersions: expectedVersions);
  }
}

/// An account that connected its health source, optionally with an answer
/// to the import already stored.
Map<String, String> _account({required bool android, String? mode}) => {
  if (android)
    'eatova.v1.health_connect_enabled.user-outbox': '{"enabled":true}'
  else
    'eatova.v1.health_prompt.user-outbox': '{"state":"connected"}',
  if (mode != null)
    'eatova.v1.health_weight_import.user-outbox': '{"mode":"$mode"}',
};

Iterable<(double, DateTime)> _log(HomeStore store) =>
    store.weightLog.entries.map((e) => (e.weightKg, e.timestamp.toLocal()));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final android in [false, true]) {
    final source = android ? 'Health Connect' : 'Apple Health';
    test('$source: nothing comes in before the opt-in; then every new '
        'weigh-in, with its time and without duplicates', () => withClock(
      Clock.fixed(_now),
      () async {
        final health = android ? _HealthConnectScale() : _Scale();
        final kv = InMemoryKeyValueStore(_account(android: android));
        final a = setup(kv: kv, health: health, disposeStore: false);
        a.server.profileRow = serverProfileRow(testProfile());
        a.server.weightRows['w1'] = <String, dynamic>{
          'recorded_at': _at(19, 7).toUtc().toIso8601String(),
          'weight_kg': 80.0,
        };
        health.samples = [
          // The log's weigh-in, typed in from the scale: the same reading.
          WeightSample(kg: 80.04, measuredAt: _at(19, 7, 2)),
          WeightSample(kg: 79.6, measuredAt: _at(20, 7)),
          WeightSample(kg: 79.4, measuredAt: _at(21, 7)),
          // A second app mirroring the same reading.
          WeightSample(kg: 79.42, measuredAt: _at(21, 7, 1)),
          // Unit or sensor errors.
          WeightSample(kg: 7.55, measuredAt: _at(21, 8)),
          WeightSample(kg: 755, measuredAt: _at(21, 9)),
        ];
        await bootUntilIdle(a.store);
        await a.store.refreshHealthSteps();
        await settle();

        expect(a.store.healthWeightImportOfferVisible, isTrue);
        expect(a.store.weightLog.entries, hasLength(1),
            reason: 'nothing before the answer');

        // "Not now" holds across a restart.
        await a.store.disableHealthWeightImport();
        expect(a.store.healthWeightImportOfferVisible, isFalse);
        a.store.dispose();
        final b = setup(kv: kv, geteilterServer: a.server, health: health);
        await bootUntilIdle(b.store);
        await b.store.refreshHealthSteps();
        await settle();
        expect(b.store.weightLog.entries, hasLength(1));
        expect(b.store.healthWeightImportOfferVisible, isFalse);
        expect(b.store.healthWeightImportEnabled, isFalse);

        // The profile's switch turns it on.
        await b.store.enableHealthWeightImport();
        await settle();
        expect(_log(b.store), [
          (80.0, _at(19, 7)),
          (79.6, _at(20, 7)),
          (79.4, _at(21, 7)),
        ]);
        expect(a.server.weightRows, hasLength(3),
            reason: 'through the weight sync path');
        expect(health.writes, 0, reason: 'no echo into the health store');
        expect(
          (await LocalCache(kv, 'user-outbox').readHealthWeightImport())?['mode'],
          'auto',
        );

        // From now on by itself.
        health.samples = [
          ...health.samples,
          WeightSample(kg: 79.1, measuredAt: _at(22, 7)),
        ];
        await b.store.refreshHealthSteps();
        await settle();
        expect(_log(b.store).last, (79.1, _at(22, 7)));
        expect(b.store.weightLog.entries, hasLength(4));
      },
    ));
  }

  test('an edited or deleted weigh-in does not come back as an import, also '
      'after a restart', () => withClock(Clock.fixed(_now), () async {
    final health = _Scale()
      ..samples = [
        WeightSample(kg: 79.6, measuredAt: _at(20, 7)),
        WeightSample(kg: 79.4, measuredAt: _at(21, 7)),
        // The scale's reading the user also typed in by hand.
        WeightSample(kg: 79.12, measuredAt: _at(22, 7)),
      ];
    final kv = InMemoryKeyValueStore(_account(android: false, mode: 'auto'));
    final a = setup(kv: kv, health: health, disposeStore: false);
    a.server.profileRow = serverProfileRow(testProfile());
    await bootUntilIdle(a.store);
    await a.store.logWeight(79.1, at: _at(22, 7, 5));
    await a.store.refreshHealthSteps();
    await settle();
    expect(a.store.weightLog.entries, hasLength(3), reason: 'precondition');

    String id(int day) => a.store.weightLog.entries
        .firstWhere((e) => e.timestamp.toLocal().day == day)
        .id!;
    await a.store.updateWeighIn(id(20), kg: 79.0, at: _at(20, 7));
    await a.store.deleteWeighIn(id(21));
    await a.store.deleteWeighIn(id(22));
    await a.store.refreshHealthSteps();
    await settle();
    expect(_log(a.store), [(79.0, _at(20, 7))]);

    a.store.dispose();
    final b = setup(kv: kv, geteilterServer: a.server, health: health);
    await bootUntilIdle(b.store);
    await b.store.refreshHealthSteps();
    await settle();
    expect(_log(b.store), [(79.0, _at(20, 7))]);
  }));

  test('a read waits for the server\'s weight log', () => withClock(
    Clock.fixed(_now),
    () async {
      final health = _Scale()
        ..samples = [
          // Already in the server's log (a write-back of another device).
          WeightSample(kg: 80.0, measuredAt: _at(21, 7, 30)),
          WeightSample(kg: 79.2, measuredAt: _at(22, 7, 30)),
        ];
      final a = setup(
        kv: InMemoryKeyValueStore(_account(android: false, mode: 'auto')),
        health: health,
      );
      a.server.profileRow = serverProfileRow(testProfile());
      a.server.weightRows['w1'] = <String, dynamic>{
        'recorded_at': _at(21, 7, 30).toUtc().toIso8601String(),
        'weight_kg': 80.0,
      };
      a.server.rejectWeightLogReads = true;
      await bootUntilIdle(a.store);

      await a.store.refreshHealthSteps();
      await settle();
      expect(a.store.weightLog.entries, isEmpty,
          reason: 'against an unknown log every weigh-in looks new');

      a.server.rejectWeightLogReads = false;
      await a.store.retryBoot();
      await settle();
      expect(_log(a.store), [(80.0, _at(21, 7, 30)), (79.2, _at(22, 7, 30))]);
    },
  ));

  test('a failed commit consumes nothing; concurrent reads import once',
      () => withClock(Clock.fixed(_now), () async {
    final health = _Scale()
      ..samples = [WeightSample(kg: 79.6, measuredAt: _at(21, 7))];
    final kv = _WeightCommitStore(_account(android: false, mode: 'auto'));
    final a = setup(kv: kv, health: health);
    a.server.profileRow = serverProfileRow(testProfile());
    await bootUntilIdle(a.store);
    a.server.offline = true;

    kv.rejectWeightCommits = true;
    await a.store.refreshHealthSteps();
    await settle();
    expect(a.store.weightLog.entries, isEmpty);
    expect(a.store.pendingOutbox, isEmpty);

    kv.rejectWeightCommits = false;
    final gate = kv.heldCommit = Completer<void>();
    final attempts = kv.weightCommitAttempts;
    final first = a.store.refreshHealthSteps();
    await pumpUntil(() => kv.weightCommitAttempts > attempts);
    await a.store.refreshHealthSteps();
    gate.complete();
    await first;
    await settle();

    expect(kv.weightCommitAttempts - attempts, 1);
    expect(_log(a.store), [(79.6, _at(21, 7))]);
  }));
}
