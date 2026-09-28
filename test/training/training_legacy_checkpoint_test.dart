import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/training_history.dart';
import 'package:eatova/src/models/training_plan.dart';
import 'package:eatova/src/models/training_session.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/services/eatova_sync.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/crash_reporter.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/services/sync_outbox.dart';
import 'package:eatova/src/services/training_session_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import '../outbox/outbox_test_helpers.dart' as h;
import '../support/atomic_store_faults.dart';
import 'legacy_checkpoint_fixture.dart';

const _user = 'user-legacy';
const _sessionKey = 'eatova.v1.training_session.$_user';
const _plansKey = 'eatova.v1.training_plans.$_user';
final _bootAt = DateTime.utc(2026, 9, 28, 8);

const _firstSquat = TrainingSetReference(exerciseIndex: 0, setIndex: 0);
const _secondSquat = TrainingSetReference(exerciseIndex: 0, setIndex: 1);

/// Deterministic wall clock that only moves when the test says so. Real time
/// always passes between hydration and a save; a fixed clock hides that.
class _Wall {
  DateTime now = _bootAt;
  void advance(Duration duration) => now = now.add(duration);
}

class _Env {
  _Env(this.storage, {KeyValueStore? backing})
    : cache = LocalCache(backing ?? storage, _user) {
    client = SupabaseClient(
      'https://ci.invalid',
      'ci-dummy-key',
      httpClient: MockClient(
        (request) async => throw http.ClientException('fixture offline'),
      ),
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    store = HomeStore(
      sync: EatovaSync.forUser(client, _user),
      debugCache: cache,
      health: const NoopHealthService(),
      notificationService: const NoopNotificationService(),
      initialUserName: 'Fixture',
      emitSnack: h.SnackCapture().call,
    );
  }

  final InMemoryKeyValueStore storage;
  final LocalCache cache;
  late final SupabaseClient client;
  late final HomeStore store;

  Future<void> boot() async {
    await cache.writeProfile(const UserProfile(onboardingCompleted: true));
    await h.bootUntilIdle(store);
  }

  bool _disposed = false;

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    store.dispose();
    cache.close();
    await cache.settle();
    await client.dispose();
  }
}

InMemoryKeyValueStore _legacyStorage() => InMemoryKeyValueStore({
  _sessionKey: legacyCheckpointSlot,
  _plansKey: legacyPlanLibrarySlot,
});

Map<String, dynamic> _legacyJson() =>
    (jsonDecode(legacyCheckpointSlot) as Map)['snapshot']
        as Map<String, dynamic>;

Map<String, dynamic>? _persisted(InMemoryKeyValueStore storage) =>
    (jsonDecode(storage.snapshot[_sessionKey]!) as Map)['snapshot']
        as Map<String, dynamic>?;

Future<int> _version(InMemoryKeyValueStore storage) async =>
    (await storage.readSnapshot([_sessionKey])).versions[_sessionKey]!;

Future<_Env> _bootLegacy(
  InMemoryKeyValueStore storage, {
  KeyValueStore? backing,
}) async {
  final env = _Env(storage, backing: backing);
  addTearDown(env.dispose);
  await env.boot();
  return env;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('an unpinned #70 checkpoint is rejected, not given a fresh start', () {
    expect(
      () => TrainingSessionSnapshot.fromJson(_legacyJson()),
      throwsFormatException,
    );
  });

  test(
    'only the pinned start depends on when a #70 checkpoint is upgraded',
    () {
      final early = TrainingSessionSnapshot.upgradeLegacyJson(
        _legacyJson(),
        observedAt: _bootAt,
      )!;
      final later = TrainingSessionSnapshot.upgradeLegacyJson(
        _legacyJson(),
        observedAt: _bootAt.add(const Duration(days: 3)),
      )!;
      expect(
        {
          for (final key in {...early.keys, ...later.keys})
            if (jsonEncode(early[key]) != jsonEncode(later[key])) key,
        },
        {'started_at'},
      );
      expect(early['schema_version'], 2);
      expect(early['started_at'], '2026-09-28T08:00:00.000Z');
      expect(early['completed_sets'], [_firstSquat.toJson()]);
      expect(early['actual_sets'], isEmpty);
      final decoded = TrainingSessionSnapshot.fromJson(
        jsonDecode(jsonEncode(early)) as Map,
      );
      expect(jsonEncode(decoded.toJson()), jsonEncode(early));
      expect(
        decoded.workout.exercises.map((exercise) => exercise.id),
        everyElement(startsWith('legacy_')),
      );
      expect(TrainingSessionSnapshot.upgradeLegacyJson(early), isNull);
    },
  );

  test('a recorded pending completion bounds the start and keeps its note', () {
    final json = _legacyJson()
      ..['exercise_index'] = 1
      ..['set_index'] = 0
      ..['phase'] = 'review'
      ..['remaining_milliseconds'] = 0
      ..['completed_sets'] = <Object>[]
      ..['skipped_sets'] = [
        _firstSquat.toJson(),
        _secondSquat.toJson(),
        const TrainingSetReference(exerciseIndex: 1, setIndex: 0).toJson(),
      ]
      ..['pending_completion_at'] = '2026-09-27T19:30:00.000Z'
      ..['pending_completion_note'] = 'Felt strong';
    final upgraded = TrainingSessionSnapshot.upgradeLegacyJson(
      json,
      observedAt: _bootAt,
    )!;
    expect(upgraded['started_at'], '2026-09-27T19:30:00.000Z');
    final entry = TrainingHistoryEntry.fromRecovery(
      TrainingSessionSnapshot.fromJson(upgraded),
    );
    expect(entry.note, 'Felt strong');
    expect(entry.finishedAt, DateTime.utc(2026, 9, 27, 19, 30));
  });

  test(
    'an atomic commit touching a #70 checkpoint pins it, never drops it',
    () {
      final wall = _Wall();
      return withClock(Clock(() => wall.now), () async {
        final storage = _legacyStorage();
        final cache = LocalCache(storage, _user);
        addTearDown(cache.close);
        final library = (await cache.readTrainingPlans())!.single;
        final other = TrainingPlan(
          id: 'manual_other',
          proposal: library.proposal,
        );

        await cache.commitSyncOperations([SyncOp.trainingPlanUpsert(other)]);

        final pinned = _persisted(storage)!;
        expect(pinned['schema_version'], 2);
        expect(
          pinned['session_id'],
          TrainingSessionSnapshot.upgradeLegacyJson(
            _legacyJson(),
          )!['session_id'],
        );
        expect(pinned['started_at'], '2026-09-28T08:00:00.000Z');
        expect(pinned['completed_sets'], [_firstSquat.toJson()]);
        wall.advance(const Duration(hours: 1));
        expect((await cache.readTrainingSession())!.toJson(), pinned);
      });
    },
  );

  test(
    'a #70 checkpoint resumes, saves and keeps updating after time passes',
    () async {
      final wall = _Wall();
      await withClock(Clock(() => wall.now), () async {
        final storage = _legacyStorage();
        final env = await _bootLegacy(storage);
        wall.advance(const Duration(minutes: 7));
        final recovery = await env.store.prepareTrainingSessionRecovery();
        expect(recovery, isNotNull);
        expect(recovery!.plan.id, legacyPlanId);
        expect(recovery.phase, TrainingSessionPhase.rest);
        expect(recovery.remainingMilliseconds, 42000);
        expect(recovery.completedSets, [_firstSquat]);

        final player = TrainingSessionController.fromSnapshot(
          recovery,
          autoTick: false,
        );
        addTearDown(player.dispose);
        wall.advance(const Duration(seconds: 3));
        // The resumed player checkpoints at once.
        await env.store.saveTrainingSession(player.snapshot());
        wall.advance(const Duration(seconds: 30));
        player.continueAfterRest();
        await env.store.saveTrainingSession(player.snapshot());
        wall.advance(const Duration(seconds: 40));
        player
          ..start()
          ..completeCurrentSet();
        await env.store.saveTrainingSession(player.snapshot());

        final persisted = _persisted(storage)!;
        expect(persisted['schema_version'], 2);
        expect(persisted['session_id'], recovery.sessionId);
        expect(
          persisted['started_at'],
          '2026-09-28T08:00:00.000Z',
          reason: 'The unknown legacy start is pinned at the first read',
        );
        expect(persisted['completed_sets'], [
          _firstSquat.toJson(),
          _secondSquat.toJson(),
        ]);
        expect(persisted['exercise_index'], 1);
        expect(env.store.trainingSession!.toJson(), persisted);
      });
    },
  );

  test('a direct read pins a #70 checkpoint once before decoding it', () {
    final wall = _Wall();
    return withClock(Clock(() => wall.now), () async {
      final storage = _legacyStorage();
      final cache = LocalCache(storage, _user);
      addTearDown(cache.close);

      final first = await cache.readTrainingSession();
      final pinned = storage.snapshot[_sessionKey];
      final version = await _version(storage);
      wall.advance(const Duration(hours: 5));
      final second = await cache.readTrainingSession(requireReadable: true);

      expect(first!.startedAt, _bootAt);
      expect(first.completedSets, [_firstSquat]);
      expect(second!.toJson(), first.toJson());
      expect(_persisted(storage), first.toJson());
      expect(storage.snapshot[_sessionKey], pinned);
      expect(await _version(storage), version);
    });
  });

  test(
    'a cache that cannot pin a #70 checkpoint never reports it empty',
    () async {
      final storage = _legacyStorage();
      final closed = LocalCache(storage, _user)..close();

      expect(await closed.readTrainingSession(), isNull);
      await expectLater(
        closed.readTrainingSession(requireReadable: true),
        throwsA(
          isA<UnreadableCacheSlot>()
              .having((error) => error.transient, 'transient', isTrue)
              .having((error) => error.slot, 'slot', 'training_session'),
        ),
      );
      expect(storage.snapshot[_sessionKey], legacyCheckpointSlot);
    },
  );

  test(
    'a failed hydration pin keeps the #70 recovery until a repair pins it',
    () async {
      final wall = _Wall();
      await withClock(Clock(() => wall.now), () async {
        final storage = _legacyStorage();
        final faults = AtomicStoreFaults(storage);
        var pinFailures = 1;
        faults.beforeWrite = (changes) async {
          if (changes.containsKey(_sessionKey) && pinFailures > 0) {
            pinFailures--;
            throw StateError('fixture pin failure');
          }
        };
        final env = await _bootLegacy(storage, backing: faults);
        expect(pinFailures, 0, reason: 'Hydration attempted the pin');
        wall.advance(const Duration(minutes: 2));

        final recovery = await env.store.prepareTrainingSessionRecovery();

        expect(recovery, isNotNull);
        expect(recovery!.completedSets, [_firstSquat]);
        expect(_persisted(storage), recovery.toJson());
        await env.store.saveTrainingSession(null);
        expect(_persisted(storage), isNull);
      });
    },
  );

  test('a #70 checkpoint can be discarded after time passes', () async {
    final wall = _Wall();
    await withClock(Clock(() => wall.now), () async {
      final storage = _legacyStorage();
      final env = await _bootLegacy(storage);
      wall.advance(const Duration(minutes: 7));
      expect(await env.store.prepareTrainingSessionRecovery(), isNotNull);
      wall.advance(const Duration(seconds: 2));

      await env.store.saveTrainingSession(null);

      expect(env.store.trainingSession, isNull);
      expect(_persisted(storage), isNull);
      expect(await env.cache.readTrainingSession(), isNull);
    });
  });

  test(
    'hydration pins a #70 checkpoint once; reboots read the same bytes',
    () async {
      final wall = _Wall();
      await withClock(Clock(() => wall.now), () async {
        final storage = _legacyStorage();
        final reports = <String?>[];
        CrashReporter.debugSentrySink = (error, stack, context) =>
            reports.add(context);
        addTearDown(() => CrashReporter.debugSentrySink = null);
        final first = await _bootLegacy(storage);
        expect(
          reports,
          isNot(contains('cache-hydrate-training_session')),
          reason: 'Hydration pins the checkpoint instead of hiding it',
        );
        final hydrated = first.store.trainingSession!.toJson();
        final pinned = storage.snapshot[_sessionKey];
        final pinnedVersion = await _version(storage);
        expect(_persisted(storage), hydrated);
        await first.dispose();

        wall.advance(const Duration(days: 2));
        final second = await _bootLegacy(storage);
        expect(second.store.trainingSession!.toJson(), hydrated);
        expect(storage.snapshot[_sessionKey], pinned);
        expect(
          await _version(storage),
          pinnedVersion,
          reason: 'An already pinned checkpoint is not rewritten',
        );
        expect((await second.cache.readTrainingSession())!.toJson(), hydrated);
      });
    },
  );

  for (final change in ['progressed', 'discarded']) {
    test(
      'another handle that $change the pinned recovery still fences a stale save',
      () async {
        final wall = _Wall();
        await withClock(Clock(() => wall.now), () async {
          final storage = _legacyStorage();
          final env = await _bootLegacy(storage);
          final held = await env.store.prepareTrainingSessionRecovery();
          wall.advance(const Duration(minutes: 1));

          final worker = LocalCache(storage, _user);
          addTearDown(worker.close);
          final seen = await worker.readTrainingSession();
          expect(seen!.toJson(), held!.toJson());
          final other = TrainingSessionController.fromSnapshot(
            seen,
            autoTick: false,
          )..continueAfterRest();
          addTearDown(other.dispose);
          await worker.commitTrainingCheckpoint(
            change == 'progressed' ? other.snapshot() : null,
            expectedSnapshot: seen,
          );
          final winner = storage.snapshot[_sessionKey];

          wall.advance(const Duration(seconds: 5));
          final stale = TrainingSessionController.fromSnapshot(
            held,
            autoTick: false,
          )..resetPhase();
          addTearDown(stale.dispose);
          await expectLater(
            env.store.saveTrainingSession(stale.snapshot()),
            throwsA(
              isA<StateError>().having(
                (error) => error.message,
                'message',
                'Training recovery changed',
              ),
            ),
          );
          await expectLater(
            env.store.saveTrainingSession(null),
            throwsA(isA<StateError>()),
          );
          expect(storage.snapshot[_sessionKey], winner);
        });
      },
    );
  }

  test('hydration leaves a current v2 checkpoint byte-identical', () async {
    final wall = _Wall();
    await withClock(Clock(() => wall.now), () async {
      final storage = InMemoryKeyValueStore({_plansKey: legacyPlanLibrarySlot});
      final writer = LocalCache(storage, _user);
      final plan = (await writer.readTrainingPlans())!.single;
      final current = TrainingSessionSnapshot(
        plan: plan,
        sessionId: '44f8625f-7f4b-4ffc-b6b0-ec94fcae1f39',
        startedAt: _bootAt.subtract(const Duration(hours: 1)),
        workoutIndex: 0,
        exerciseIndex: 0,
        setIndex: 1,
        phase: TrainingSessionPhase.exercise,
        remainingMilliseconds: 0,
        completedSets: const [_firstSquat],
        actualSets: [
          TrainingSetActual(
            reference: _firstSquat,
            completedAt: _bootAt.subtract(const Duration(minutes: 50)),
            reps: 8,
            weightKg: 42.5,
          ),
        ],
        draftReps: 7,
      );
      await writer.writeTrainingSession(current);
      writer.close();
      final bytes = storage.snapshot[_sessionKey];
      final version = await _version(storage);

      wall.advance(const Duration(minutes: 3));
      final env = await _bootLegacy(storage);

      expect(env.store.trainingSession!.toJson(), current.toJson());
      expect(storage.snapshot[_sessionKey], bytes);
      expect(await _version(storage), version);
    });
  });
}
