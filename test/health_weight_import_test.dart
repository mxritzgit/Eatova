import 'dart:async';

import 'package:clock/clock.dart';
import 'package:supabase/supabase.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/services/eatova_sync.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/sync_outbox.dart';

import 'outbox/outbox_test_helpers.dart'
    show FakeServer, bootUntilIdle, pumpUntil, testProfile;

import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/widgets/common/app_snack.dart';

// HealthKit weight import: refreshHealthSteps() also reads
// snapshot.latestWeightKg and offers it via a snack action. Covered:
//  * offer on a new weight, even with no prior log,
//  * in-memory dedup, so a resume does not re-offer the same value,
//  * 0.1 kg threshold against the last logged weight,
//  * importHealthWeight does not write back to HealthKit (no echo
//    duplicate), logWeight does,
//  * the import updates weightLog and thereby suppresses further offers.

/// Fake HealthService: controllable snapshot (steps + optional weight) and a
/// writeWeight call counter.
class _FakeHealthService implements HealthService {
  int steps = 4200;
  double? nextWeightKg;
  int writeWeightCalls = 0;

  @override
  HealthAuthState get authState => HealthAuthState.granted;

  @override
  void reset() {}

  @override
  Future<HealthAuthState> requestAuthorization() async =>
      HealthAuthState.granted;

  @override
  Future<HealthSnapshot?> readSnapshot() async => HealthSnapshot(
    stepsToday: steps,
    fetchedAt: clock.now(),
    latestWeightKg: nextWeightKg,
  );

  @override
  Future<bool> writeWeight(double kg, DateTime when) async {
    writeWeightCalls++;
    return true;
  }

  @override
  Future<List<WeightSample>> readWeightSamples({
    required DateTime from,
    required DateTime to,
  }) async => const <WeightSample>[];

  @override
  Future<int?> readStepsOnDay(DateTime day) async => null;
}

/// Capture for the store's context-free SnackEmitter: records message and
/// action per call so tests can check the offer and its tap.
class _SnackCapture {
  final List<String> messages = <String>[];
  final List<SnackTone> tones = <SnackTone>[];
  final List<SnackBarAction?> actions = <SnackBarAction?>[];

  void call(
    String message, {
    IconData icon = Icons.info_outline,
    SnackTone tone = SnackTone.positive,
    Duration? duration,
    SnackBarAction? action,
  }) {
    messages.add(message);
    tones.add(tone);
    actions.add(action);
  }
}

({HomeStore store, _FakeHealthService health, _SnackCapture snacks}) _setup() {
  final health = _FakeHealthService();
  final snacks = _SnackCapture();
  final store = HomeStore(
    sync: null,
    health: health,
    notificationService: const NoopNotificationService(),
    initialUserName: 'Test',
    emitSnack: snacks.call,
  );
  addTearDown(store.dispose);
  return (store: store, health: health, snacks: snacks);
}

class _WeightCommitStore extends InMemoryKeyValueStore {
  bool rejectWeightCommits = false;
  Completer<void>? heldCommit;
  int weightCommitAttempts = 0;

  @override
  Future<KeyValueCommit> writeBatch(
    Map<String, String?> changes, {
    Map<String, int> expectedVersions = const {},
  }) async {
    const weightsKey = 'eatova.v1.weight_log.user-health-import';
    final weights = changes[weightsKey];
    if (weights != null && weights != snapshot[weightsKey]) {
      weightCommitAttempts++;
      await heldCommit?.future;
      if (rejectWeightCommits) throw StateError('Injected local write failure');
    }
    return super.writeBatch(changes, expectedVersions: expectedVersions);
  }
}

Future<
  ({
    HomeStore store,
    _FakeHealthService health,
    _SnackCapture snacks,
    LocalCache cache,
    FakeServer server,
  })
>
_setupDurable(_WeightCommitStore kv) async {
  final server = FakeServer();
  final client = SupabaseClient(
    'https://example.supabase.co',
    'test-anon-key',
    httpClient: server.client(),
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );
  addTearDown(client.dispose);
  final health = _FakeHealthService();
  final snacks = _SnackCapture();
  final cache = LocalCache(kv, 'user-health-import');
  await cache.writeProfile(testProfile());
  final store = HomeStore(
    sync: EatovaSync.forUser(client, 'user-health-import'),
    health: health,
    notificationService: const NoopNotificationService(),
    initialUserName: 'Test',
    emitSnack: snacks.call,
    debugCache: cache,
  );
  addTearDown(store.dispose);
  await bootUntilIdle(store);
  kv.weightCommitAttempts = 0;
  server.offline = true;
  return (
    store: store,
    health: health,
    snacks: snacks,
    cache: cache,
    server: server,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'Snapshot-Gewicht ohne bisheriges Log -> Angebot mit deutschem Format',
    () async {
      final s = _setup();
      s.health.nextWeightKg = 82.4;

      await s.store.refreshHealthSteps();

      expect(s.snacks.messages, ['Apple Health: 82,4 kg übernehmen?']);
      expect(s.snacks.actions.single, isNotNull);
      expect(s.snacks.actions.single!.label, 'Übernehmen');
      // The steps path stays untouched.
      expect(s.store.dailySteps, 4200);
    },
  );

  test(
    'derselbe Wert wird bei erneutem Refresh (Resume) NICHT erneut angeboten',
    () async {
      final s = _setup();
      s.health.nextWeightKg = 82.4;

      await s.store.refreshHealthSteps();
      await s.store.refreshHealthSteps();

      expect(
        s.snacks.messages,
        hasLength(1),
        reason: 'In-Memory-Dedup: pro Wert nur ein Angebot',
      );
    },
  );

  test(
    'ein NEUER Wert nach einem alten Angebot wird wieder angeboten',
    () async {
      final s = _setup();
      s.health.nextWeightKg = 82.4;
      await s.store.refreshHealthSteps();

      s.health.nextWeightKg = 81.2;
      await s.store.refreshHealthSteps();

      expect(s.snacks.messages, [
        'Apple Health: 82,4 kg übernehmen?',
        'Apple Health: 81,2 kg übernehmen?',
      ]);
    },
  );

  test(
    'Abweichung < 0.1 kg vom letzten geloggten Gewicht -> kein Angebot',
    () async {
      final s = _setup();
      await s.store.logWeight(80.0);
      s.health.nextWeightKg = 80.05;

      await s.store.refreshHealthSteps();

      expect(s.snacks.messages, isEmpty);
    },
  );

  test('Snapshot ohne Gewicht -> kein Angebot, Steps laufen normal', () async {
    final s = _setup();
    s.health.nextWeightKg = null;

    await s.store.refreshHealthSteps();

    expect(s.snacks.messages, isEmpty);
    expect(s.store.dailySteps, 4200);
  });

  test(
    'importHealthWeight loggt OHNE HealthKit-Write-Back, logWeight MIT',
    () async {
      final s = _setup();

      await s.store.importHealthWeight(82.4);
      expect(
        s.health.writeWeightCalls,
        0,
        reason: 'Import aus HealthKit darf kein Echo-Duplikat zurueckschreiben',
      );
      expect(s.store.weightLog.latest?.weightKg, 82.4);
      expect(s.store.lifetimeStats.weightLogs, 1);

      await s.store.logWeight(81.0);
      expect(
        s.health.writeWeightCalls,
        1,
        reason: 'manuelles Wiegen spiegelt weiterhin nach HealthKit',
      );
      expect(s.store.weightLog.latest?.weightKg, 81.0);
    },
  );

  test('importHealthWeight VERWIRFT Werte ausserhalb 20..400 kg statt zu '
      'klemmen (G M-4)', () async {
    final s = _setup();

    await s.store.importHealthWeight(7.55);
    await s.store.importHealthWeight(755);
    await s.store.importHealthWeight(double.nan);

    expect(
      s.store.weightLog.entries,
      isEmpty,
      reason: 'ein geklemmtes 20 kg / 400 kg waere eine Fiktion im Log',
    );
    expect(s.store.lifetimeStats.weightLogs, 0);
    expect(s.health.writeWeightCalls, 0);

    // The manual path keeps the clamp as its last barrier.
    await s.store.logWeight(7.55);
    expect(s.store.weightLog.latest?.weightKg, 20.0);
  });

  test('ein Snapshot-Gewicht ausserhalb 20..400 kg wird gar nicht erst '
      'angeboten', () async {
    final s = _setup();
    s.health.nextWeightKg = 755;

    await s.store.refreshHealthSteps();

    expect(
      s.snacks.messages,
      isEmpty,
      reason: 'der Tap wuerde sonst ins Leere laufen',
    );
    expect(s.store.dailySteps, 4200);
  });

  test(
    'Aktions-Tap importiert den Wert und unterdrueckt weitere Angebote',
    () async {
      final s = _setup();
      s.health.nextWeightKg = 82.4;
      await s.store.refreshHealthSteps();
      expect(s.snacks.actions.single, isNotNull);

      // Tap the action; the page forwards onPressed unchanged.
      s.snacks.actions.single!.onPressed();
      await Future<void>.delayed(Duration.zero);

      expect(s.store.weightLog.latest?.weightKg, 82.4);
      expect(s.health.writeWeightCalls, 0);

      // Next resume with unchanged HealthKit data: weightLog.latest == kg, so
      // the 0.1 kg threshold suppresses the offer.
      await s.store.refreshHealthSteps();
      expect(s.snacks.messages, hasLength(1));
    },
  );

  for (final l10n in [deL10n, enL10n]) {
    test(
      'Health-Snack ${l10n.localeName}: Commitfehler sichtbar, unveraendert, wiederholbar',
      () => withClock(Clock.fixed(DateTime(2026, 9, 20, 12)), () async {
        final kv = _WeightCommitStore();
        final s = await _setupDurable(kv);
        s.store.setLocalizations(l10n);
        s.health.nextWeightKg = 82.4;
        await s.store.refreshHealthSteps();
        final failedAction = s.snacks.actions.last!;
        kv.rejectWeightCommits = true;
        failedAction.onPressed();
        await pumpUntil(
          () => s.snacks.messages.contains(l10n.commonLocalSaveFailed),
        );

        expect(s.snacks.messages.last, l10n.commonLocalSaveFailed);
        expect(s.snacks.tones.last, SnackTone.error);
        expect(s.store.weightLog.entries, isEmpty);
        expect(s.store.lifetimeStats.weightLogs, 0);
        expect(s.store.pendingOutbox, isEmpty);
        expect((await s.cache.readWeightLog())?.entries ?? [], isEmpty);
        expect(await s.cache.readOutbox(), isEmpty);
        expect(s.health.writeWeightCalls, 0);
        expect(kv.weightCommitAttempts, 1);

        kv.rejectWeightCommits = false;
        await s.store.refreshHealthSteps();
        expect(
          s.snacks.actions.last,
          isNotNull,
          reason:
              'der fehlgeschlagene Versuch darf die Health-Offerte nicht verbrauchen',
        );
        s.snacks.actions.last!.onPressed();
        await pumpUntil(() => s.store.weightLog.entries.length == 1);
        await s.store.syncPendingWrites();
        expect(s.store.weightLog.latest?.weightKg, 82.4);
        expect(s.store.lifetimeStats.weightLogs, 1);
        expect(s.store.pendingOutbox.single.kind, SyncOpKind.weightInsert);
        expect((await s.cache.readWeightLog())!.entries, hasLength(1));
        expect(s.health.writeWeightCalls, 0);
        final notices = s.snacks.messages.length;
        await s.store.refreshHealthSteps();
        expect(s.snacks.messages, hasLength(notices));
      }),
    );
  }

  test(
    'Health-Snack: doppelte Taps waehrend und nach Commit erzeugen nur ein Log',
    () => withClock(Clock.fixed(DateTime(2026, 9, 20, 12)), () async {
      final kv = _WeightCommitStore();
      final s = await _setupDurable(kv);
      s.health.nextWeightKg = 82.4;
      await s.store.refreshHealthSteps();
      final action = s.snacks.actions.last!;
      final gate = kv.heldCommit = Completer<void>();
      action.onPressed();
      action.onPressed();
      await pumpUntil(() => kv.weightCommitAttempts == 1);
      expect(kv.weightCommitAttempts, 1);
      expect(
        s.store.weightLog.entries,
        isEmpty,
        reason: 'RAM darf dem noch unbestaetigten DB-Commit nicht vorauslaufen',
      );
      await s.store.refreshHealthSteps();
      expect(s.snacks.actions.whereType<SnackBarAction>(), hasLength(1));
      gate.complete();
      await pumpUntil(() => s.store.weightLog.entries.length == 1);
      await s.store.syncPendingWrites();
      action.onPressed();
      await pumpEventQueue(times: 30);
      expect(kv.weightCommitAttempts, 1);
      expect(s.store.weightLog.entries, hasLength(1));
      expect(s.store.lifetimeStats.weightLogs, 1);
      expect(
        (await s.cache.readOutbox())!.where(
          (op) => op.kind == SyncOpKind.weightInsert,
        ),
        hasLength(1),
      );
      expect(s.health.writeWeightCalls, 0);
    }),
  );
}
