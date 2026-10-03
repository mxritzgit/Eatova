import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/training_log.dart';
import 'package:eatova/src/models/training_plan.dart';
import 'package:eatova/src/models/training_session.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/services/eatova_sync.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/services/secure_cache_store.dart';
import 'package:eatova/src/services/sqlite_key_value_store.dart';
import 'package:eatova/src/services/sync_error_messages.dart';
import 'package:eatova/src/services/sync_outbox.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import '../outbox/outbox_test_helpers.dart' as h;
import '../support/atomic_store_faults.dart';
import 'training_timer_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final source in ['unchanged', 'deleted', 're-adopted']) {
    test(
      'a concurrent SQLite handle leaves a held checkpoint safe: $source',
      () async {
        await withClock(Clock.fixed(DateTime.utc(2026, 9, 20, 12)), () async {
          final directory = await Directory.systemTemp.createTemp(
            'eatova_checkpoint_race_',
          );
          final first = await SqliteKeyValueStore.open(
            '${directory.path}/cache.sqlite',
          );
          final second = await SqliteKeyValueStore.open(
            '${directory.path}/cache.sqlite',
          );
          EncryptedKeyValueStore encrypted(SqliteKeyValueStore db) =>
              EncryptedKeyValueStore(
                db,
                AesGcmCacheCipher(Uint8List(32)),
                acceptLegacyPlaintext: false,
              );
          final controlled = AtomicStoreFaults(encrypted(first));
          final cache = LocalCache(controlled, 'A');
          final worker = LocalCache(encrypted(second), 'A');
          final client = SupabaseClient(
            'https://ci.invalid',
            'ci-dummy-key',
            httpClient: MockClient(
              (request) async => throw http.ClientException('fixture offline'),
            ),
            authOptions: const AuthClientOptions(autoRefreshToken: false),
          );
          HomeStore makeStore(LocalCache local) => HomeStore(
            sync: EatovaSync.forUser(client, 'A'),
            debugCache: local,
            health: const NoopHealthService(),
            notificationService: const NoopNotificationService(),
            initialUserName: 'Fixture',
            emitSnack: h.SnackCapture().call,
          );
          final store = makeStore(cache);
          var disposed = false;
          HomeStore? reboot;
          LocalCache? rebootCache;
          final entered = Completer<void>();
          final release = Completer<void>();
          Future<bool>? saving;
          try {
            final plan = timerPlan();
            await cache.writeProfile(
              const UserProfile(onboardingCompleted: true),
            );
            await cache.writeTrainingPlans([plan]);
            await h.bootUntilIdle(store);
            expect(store.trainingPlans.single.id, plan.id);
            final snapshot = TrainingSessionSnapshot(
              plan: plan,
              workoutIndex: 0,
              exerciseIndex: 0,
              setIndex: 0,
              phase: TrainingSessionPhase.exercise,
              remainingMilliseconds: 0,
            );
            controlled.beforeWrite = (changes) async {
              if (changes.containsKey('eatova.v1.training_session.A')) {
                if (!entered.isCompleted) entered.complete();
                await release.future;
              }
            };
            saving = store
                .saveTrainingSession(snapshot)
                .then((_) => true, onError: (Object _) => false);
            await entered.future.timeout(const Duration(seconds: 5));
            if (source != 'unchanged') {
              final deletion = SyncOp.trainingPlanDelete(plan.id);
              await worker.commitSyncOperations([deletion]);
              await worker.acknowledgeSyncOperation(
                deletion.operationId,
                const LocalSyncResult(entityDeleted: true),
              );
              expect(await worker.readTrainingPlans(), isEmpty);
              if (source == 're-adopted') {
                final adoption = SyncOp.trainingPlanUpsert(plan);
                await worker.commitSyncOperations([adoption]);
                await worker.acknowledgeSyncOperation(
                  adoption.operationId,
                  const LocalSyncResult(),
                );
              }
            } else {
              expect(
                (await worker.readTrainingPlans())!.single.toRow(),
                plan.toRow(),
              );
            }
            expect(await worker.readTrainingSession(), isNull);
            release.complete();
            final saved = await saving;
            store.dispose();
            disposed = true;
            rebootCache = LocalCache(encrypted(second), 'A');
            reboot = makeStore(rebootCache);
            await h.bootUntilIdle(reboot);
            if (source == 'unchanged') {
              expect(saved, isTrue);
              expect(reboot.trainingSession!.toJson(), snapshot.toJson());
              expect(
                (await worker.readTrainingSession())!.toJson(),
                snapshot.toJson(),
              );
            } else {
              expect(
                reboot.trainingSession,
                isNull,
                reason:
                    'The offline app must not offer Resume for the retired source',
              );
              expect(
                saved,
                isFalse,
                reason:
                    'A newer source retirement must invalidate the held checkpoint commit',
              );
              expect(await worker.readTrainingSession(), isNull);
            }
            expect(
              reboot.trainingPlans,
              source == 'deleted' ? isEmpty : hasLength(1),
            );
          } finally {
            if (!release.isCompleted) release.complete();
            await saving;
            controlled.beforeWrite = null;
            reboot?.dispose();
            if (!disposed) store.dispose();
            cache.close();
            worker.close();
            rebootCache?.close();
            await cache.settle();
            await worker.settle();
            await rebootCache?.settle();
            await client.dispose();
            await first.close();
            await second.close();
            final temporaryRoot = await Directory.systemTemp
                .resolveSymbolicLinks();
            final actualDirectory = await directory.resolveSymbolicLinks();
            expect(
              actualDirectory.startsWith(
                '$temporaryRoot${Platform.pathSeparator}',
              ),
              isTrue,
            );
            await directory.delete(recursive: true);
          }
        });
      },
    );
  }

  final shapes = <String, TrainingSessionSnapshot Function(DateTime now)>{
    'rest between exercises': (now) => TrainingSessionSnapshot(
      plan: timerPlan(),
      workoutIndex: 0,
      exerciseIndex: 0,
      setIndex: 1,
      phase: TrainingSessionPhase.rest,
      remainingMilliseconds: 15000,
      phaseEndsAt: now.add(const Duration(seconds: 15)),
      completedSets: const [
        TrainingSetReference(exerciseIndex: 0, setIndex: 0),
        TrainingSetReference(exerciseIndex: 0, setIndex: 1),
      ],
      actualSets: [
        for (final set in [0, 1])
          TrainingSetActual(
            reference: TrainingSetReference(exerciseIndex: 0, setIndex: set),
            completedAt: now,
          ),
      ],
    ),
    'running timed interval': (now) => TrainingSessionSnapshot(
      plan: timerPlan(),
      workoutIndex: 0,
      exerciseIndex: 0,
      setIndex: 0,
      phase: TrainingSessionPhase.exercise,
      remainingMilliseconds: 30000,
      phaseEndsAt: now.add(const Duration(seconds: 30)),
    ),
  };
  for (final shape in shapes.entries) {
    test(
      'a ${shape.key} checkpoint survives a foreign history insert, another plan and restart',
      () async {
        await withClock(Clock.fixed(DateTime.utc(2026, 9, 20, 12)), () async {
          final directory = await Directory.systemTemp.createTemp(
            'eatova_checkpoint_shape_',
          );
          final path = '${directory.path}/cache.sqlite';
          final client = SupabaseClient(
            'https://ci.invalid',
            'ci-dummy-key',
            httpClient: MockClient(
              (request) async => throw http.ClientException('fixture offline'),
            ),
            authOptions: const AuthClientOptions(autoRefreshToken: false),
          );
          final handles = <SqliteKeyValueStore>[];
          final caches = <LocalCache>[];
          final stores = <HomeStore>[];
          Future<HomeStore> open() async {
            final db = await SqliteKeyValueStore.open(path);
            handles.add(db);
            final cache = LocalCache(
              EncryptedKeyValueStore(
                db,
                AesGcmCacheCipher(Uint8List(32)),
                acceptLegacyPlaintext: false,
              ),
              'A',
            );
            caches.add(cache);
            final store = HomeStore(
              sync: EatovaSync.forUser(client, 'A'),
              debugCache: cache,
              health: const NoopHealthService(),
              notificationService: const NoopNotificationService(),
              initialUserName: 'Fixture',
              emitSnack: h.SnackCapture().call,
            );
            stores.add(store);
            return store;
          }

          try {
            final now = clock.now();
            final checkpoint = shape.value(now);
            final first = await open();
            await caches.last.writeProfile(
              const UserProfile(onboardingCompleted: true),
            );
            await caches.last.writeTrainingPlans([timerPlan()]);
            await h.bootUntilIdle(first);
            expect(await first.saveTrainingSession(checkpoint), isTrue);
            final local = now.toLocal();
            final foreign = buildLoggedWorkout(
              historyId: '44444444-4444-4444-8444-444444444444',
              draft: LoggedWorkoutDraft(
                title: 'Garage session',
                performedOn: DateTime(local.year, local.month, local.day),
                exercises: const [
                  LoggedExercise(
                    name: 'Bench press',
                    timed: false,
                    sets: [LoggedSet(reps: 8, weightKg: 60)],
                  ),
                ],
              ),
              now: now,
              fallbackTitle: 'Workout',
            );
            expect(
              await first.logCompletedWorkout(foreign),
              SyncDelivery.queuedOffline,
            );
            await first.saveTrainingPlan(
              TrainingPlan(id: 'other_plan', proposal: timerPlan().proposal),
            );
            expect(first.trainingSession?.toJson(), checkpoint.toJson());
            stores.remove(first);
            first.dispose();
            await caches.last.settle();

            final reboot = await open();
            await h.bootUntilIdle(reboot);
            expect(
              (await caches.last.readTrainingSession())?.toJson(),
              checkpoint.toJson(),
            );
            expect(reboot.trainingSession?.toJson(), checkpoint.toJson());
            expect(reboot.trainingHistory.single.id, foreign.id);
          } finally {
            for (final store in stores) {
              store.dispose();
            }
            for (final cache in caches) {
              cache.close();
              await cache.settle();
            }
            await client.dispose();
            for (final db in handles) {
              await db.close();
            }
            await directory.delete(recursive: true);
          }
        });
      },
    );
  }
}
