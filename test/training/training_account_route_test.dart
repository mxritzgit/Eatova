import 'dart:async';
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:eatova/src/app/auth_gate.dart';
import 'package:eatova/src/app/eatova_home_page.dart';
import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/auth/auth_repository.dart';
import 'package:eatova/src/models/coach_training_proposal.dart';
import 'package:eatova/src/models/training_plan.dart';
import 'package:eatova/src/models/training_session.dart';
import 'package:eatova/src/screens/training/training_player_screen.dart';
import 'package:eatova/src/screens/coach/coach_chat_screen.dart';
import 'package:eatova/src/services/eatova_sync.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/recipe_image_store.dart';
import 'package:eatova/src/services/secure_cache_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase/supabase.dart';

import '../fixlauf_a_helpers.dart';
import '../flows/flow_test_helpers.dart' show pumpUntil;
import '../support/harness.dart';

const _userA = EatovaUser(id: 'training-account-a', displayName: 'Account A');
const _userB = EatovaUser(id: 'training-account-b', displayName: 'Account B');
final _now = DateTime.utc(2026, 9, 8, 12);

class _ScriptedAuth extends Fake implements AuthRepository {
  EatovaUser? _user = _userA;
  final _events = StreamController<EatovaUser?>.broadcast();

  @override
  EatovaUser? get currentUser => _user;
  @override
  Stream<EatovaUser?> get authStateChanges => _events.stream;

  void emit(EatovaUser? user) {
    _user = user;
    _events.add(user);
  }

  @override
  Future<void> signOut() async => emit(null);

  Future<void> dispose() => _events.close();
}

class _NoPhotoFiles extends RecipeImageStore {
  @override
  Future<void> setActiveUser(String? userId) async {}
}

TrainingPlan _plan(String id, String title) => TrainingPlan(
  id: id,
  proposal: CoachTrainingProposal(
    title: title,
    workouts: [
      TrainingWorkout(
        title: 'Session',
        exercises: [
          TrainingExercise(
            name: 'Plank',
            sets: 2,
            durationSeconds: 30,
            restSeconds: 10,
          ),
        ],
      ),
    ],
  ),
);

TrainingSessionSnapshot _snapshot(TrainingPlan plan) => TrainingSessionSnapshot(
  plan: plan,
  workoutIndex: 0,
  exerciseIndex: 0,
  setIndex: 0,
  phase: TrainingSessionPhase.exercise,
  remainingMilliseconds: 30000,
);

Future<void> _frames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
}

HomeStore _currentStore(WidgetTester tester) =>
    (tester.state(find.byType(EatovaHomePage)) as HomePageDebugAccess)
        .debugStore;

void main() {
  for (final signOut in [false, true]) {
    testWidgets(
      'real auth gate retires training player and rejects late checkpoint '
      '(${signOut ? 'logout' : 'A to B'})',
      (tester) async {
        await withClock(Clock.fixed(_now), () async {
          final repository = _ScriptedAuth();
          addTearDown(repository.dispose);
          RecipeImageStore.instance = _NoPhotoFiles();
          addTearDown(RecipeImageStore.resetInstance);
          addTearDown(IntentionalSignOut.clear);
          final storage = InMemoryKeyValueStore();
          final caches = {
            _userA.id: LocalCache(storage, _userA.id),
            _userB.id: LocalCache(storage, _userB.id),
          };
          final servers = {
            for (final user in [_userA, _userB])
              user.id: FixlaufServer()
                ..profileRow = {
                  ...serverProfileRow(completedProfile),
                  'id': user.id,
                },
          };
          final syncs = {
            for (final user in [_userA, _userB])
              user.id: EatovaSync.forUser(
                SupabaseClient(
                  'https://example.invalid',
                  'fixture-anon-key',
                  httpClient: servers[user.id]!.client(),
                  authOptions: const AuthClientOptions(autoRefreshToken: false),
                ),
                user.id,
              ),
          };
          for (final cache in caches.values) {
            addTearDown(cache.close);
          }
          final purged = <String>[];
          final bSnapshot = _snapshot(_plan('b-plan', 'Private B training'));
          await caches[_userB.id]!.writeTrainingSession(bSnapshot);

          await pumpLocalized(
            tester,
            AuthGate(
              authRepository: repository,
              debugPurgeCache: (userId) async {
                // The production namespace-close and purge functions, with only
                // SharedPreferences/keystore creation replaced by the test store.
                await LocalCache.closeInstancesFor(userId);
                final purgeCache = LocalCache(storage, userId);
                await purgePersonalCache(purgeCache);
                purged.add(userId);
              },
              builder: (context, user, freshLogin) => EatovaHomePage(
                key: ValueKey('home-${user.id}'),
                // EatovaApp also rebuilds this wrapper on token refresh.
                sync: EatovaSync.forUser(syncs[user.id]!.client, user.id),
                debugCache: caches[user.id],
                authRepository: repository,
                onSignOut: repository.signOut,
                initialUserName: user.displayName!,
                showWelcome: freshLogin,
              ),
            ),
            surfaceSize: const Size(390, 844),
            scaffold: false,
            safeArea: false,
          );
          await pumpUntil(
            tester,
            () =>
                find.byKey(const ValueKey('screen-welcome')).evaluate().isEmpty,
            'A finishes boot',
          );
          final storeA = _currentStore(tester);
          await storeA.saveTrainingPlan(_plan('a-plan', 'Private A training'));
          storeA.setTab(4);
          await _frames(tester);
          final coachService = tester.widget<CoachChatScreen>(
            find.byType(CoachChatScreen),
          ).service;
          storeA.setTab(3);
          await _frames(tester);
          final start = find.byKey(const ValueKey('training-start'));
          await tester.ensureVisible(start);
          await tester.tap(start);
          await _frames(tester);
          await pumpUntil(
            tester,
            () => storeA.trainingSession != null,
            'the actual player persisted its initial checkpoint',
          );
          final player = tester.widget<TrainingPlayerScreen>(
            find.byType(TrainingPlayerScreen),
          );
          final latePersist = player.onPersist;
          final oldSnapshot = storeA.trainingSession!;
          repository.emit(_userA);
          await _frames(tester);
          expect(find.byType(TrainingPlayerScreen), findsOneWidget);
          await latePersist(oldSnapshot);
          expect(
            tester.widget<CoachChatScreen>(
              find.byType(CoachChatScreen, skipOffstage: false),
            ).service,
            same(coachService),
            reason: 'token refresh keeps the active Coach request and draft',
          );
          expect(
            (await caches[_userA.id]!.readTrainingSession())?.plan.id,
            'a-plan',
          );

          if (signOut) {
            await repository.signOut();
          } else {
            repository.emit(_userB);
          }
          await _frames(tester);
          await pumpUntil(
            tester,
            () => purged.contains(_userA.id),
            'the actual auth gate purges A',
          );
          expect(find.byType(TrainingPlayerScreen), findsNothing);
          expect(caches[_userA.id]!.isClosed, isTrue);
          expect(
            storage.snapshot.keys.where((key) => key.endsWith('.${_userA.id}')),
            everyElement(contains('.outbox.')),
          );

          if (signOut) {
            expect(find.byKey(const ValueKey('screen-auth')), findsOneWidget);
          } else {
            await pumpUntil(
              tester,
              () => !_currentStore(tester).bootLoadInFlight,
              'B finishes boot',
            );
            expect(identical(_currentStore(tester), storeA), isFalse);
            expect(_currentStore(tester).trainingPlans, isEmpty);
            expect(_currentStore(tester).trainingSession?.plan.id, 'b-plan');
          }
          final beforeLate = storage.snapshot;
          final requestsBeforeLate = servers[_userB.id]!.requests.length;
          await expectLater(latePersist(oldSnapshot), throwsStateError);
          await expectLater(latePersist(null), throwsStateError);
          await expectLater(
            storeA.saveTrainingSession(oldSnapshot),
            throwsStateError,
          );
          await _frames(tester);
          expect(
            storage.snapshot,
            beforeLate,
            reason: 'A callback must neither recreate A slots nor change B',
          );
          expect(servers[_userB.id]!.requests.length, requestsBeforeLate);
          expect(
            (await caches[_userB.id]!.readTrainingSession())?.toJson(),
            bSnapshot.toJson(),
          );
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          await _frames(tester);
        });
      },
    );
  }

  test(
    'session checkpoint roundtrips through the real encrypted cache',
    () async {
      await withClock(Clock.fixed(_now), () async {
        final raw = InMemoryKeyValueStore();
        final cipher = AesGcmCacheCipher(
          Uint8List.fromList(List.filled(32, 23)),
        );
        final encrypted = EncryptedKeyValueStore(raw, cipher);
        final a = LocalCache(encrypted, _userA.id);
        final b = LocalCache(encrypted, _userB.id);
        addTearDown(a.close);
        addTearDown(b.close);
        final snapshot = _snapshot(
          _plan('secret-plan', 'Private recovery title'),
        );
        expect(await a.writeTrainingSession(snapshot), isTrue);
        final stored = raw.snapshot['eatova.v1.training_session.${_userA.id}']!;
        expect(stored, startsWith(cacheCipherMagic));
        expect(stored, isNot(contains('Private recovery title')));
        expect(stored, isNot(contains('secret-plan')));
        expect((await a.readTrainingSession())?.toJson(), snapshot.toJson());
        expect(await b.readTrainingSession(), isNull);
        // Copying ciphertext to another account namespace fails authenticated
        // decryption because the slot key is bound as associated data.
        await raw.setString('eatova.v1.training_session.${_userB.id}', stored);
        expect(await b.readTrainingSession(), isNull);
        await a.clear(preserveOutbox: true);
        expect(await a.readTrainingSession(), isNull);
        expect(
          raw.snapshot.keys.where((key) => key.contains('training_session')),
          isEmpty,
        );
      });
    },
  );
}
