import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/coach_training_proposal.dart';
import 'package:eatova/src/models/training_plan.dart';
import 'package:eatova/src/models/training_history.dart';
import 'package:eatova/src/models/training_session.dart';
import 'package:eatova/src/models/planned_meal.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/meal_component.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/services/sync_outbox.dart';

import 'sync_test_helpers.dart';

// DATA-7 write outbox: SyncOp is the persistable wire format for failed sync
// writes. These tests pin:
//   1. every op kind roundtrips losslessly through toJson/tryFromJson.
//   2. corrupt/unknown entries yield null instead of crashing.
//   3. attempts roundtrips and stays backwards compatible (missing -> 0).

/// The shared fixture plus the fields only the wire-format assertions here
/// care about: a component list, a barcode and a brand.
MealAnalysisResult _result({String name = 'Bowl', int kcal = 300}) =>
    testResult(
      name: name,
      kcal: kcal,
      items: const [MealComponent(name: 'Reis', grams: 150, caloriesKcal: 195)],
      barcode: '4001234',
      brand: 'Testmarke',
    );

FitnessRecipe _recipe() => const FitnessRecipe(
  slug: 'user_123',
  title: 'Eigenes Rezept',
  description: 'Test',
  portion: '1 Portion',
  ingredients: '- 100 g Test',
  preparation: '1. Testen.',
  professionalHint: 'Selbst angelegt.',
  imageAsset: '',
  caloriesKcal: 420,
  proteinG: 33,
  carbsG: 44,
  fatG: 11,
  estimatedGrams: 350,
  categories: <String>['Eigene'],
  userCreated: true,
);

LoggedMeal _meal(String id, {int kcal = 300}) =>
    testMeal(id, result: _result(kcal: kcal));

void main() {
  group('SyncOp Serialisierung', () {
    test('mealInsert roundtrippt inkl. Meal-Payload und track_day', () {
      final op = SyncOp.mealInsert(_meal('m-1'), trackDay: true);
      final back = SyncOp.tryFromJson(op.toJson());

      expect(back, isNotNull);
      expect(back!.kind, SyncOpKind.mealInsert);
      expect(back.entityId, 'm-1');
      expect(back.entityKey, 'meal:m-1');
      expect(back.trackDay, isTrue);
      final meal = back.meal!;
      expect(meal.id, 'm-1');
      expect(meal.loggedAt, DateTime(2026, 8, 5, 12, 30));
      expect(meal.forcedSlot, MealSlot.lunch);
      expect(meal.localDay, '2026-08-05');
      expect(meal.result.caloriesKcal, 300);
      expect(meal.result.items.single.name, 'Reis');
      expect(meal.result.barcode, '4001234');
    });

    test('mealUpsert/mealDelete roundtrippen', () {
      final upsert = SyncOp.tryFromJson(
        SyncOp.mealUpsert(_meal('m-2')).toJson(),
      );
      expect(upsert!.kind, SyncOpKind.mealUpsert);
      expect(upsert.trackDay, isFalse);
      expect(upsert.meal!.id, 'm-2');

      final delete = SyncOp.tryFromJson(SyncOp.mealDelete('m-3').toJson());
      expect(delete!.kind, SyncOpKind.mealDelete);
      expect(delete.entityId, 'm-3');
      expect(delete.entityKey, 'meal:m-3');
    });

    test('weightInsert roundtrippt id + kg + Zeitstempel', () {
      final ts = DateTime(2026, 8, 6, 7, 45, 12, 345);
      final op = SyncOp.weightInsert(id: 'w-1', weightKg: 81.4, recordedAt: ts);
      final back = SyncOp.tryFromJson(op.toJson());

      expect(back!.kind, SyncOpKind.weightInsert);
      expect(back.entityId, 'w-1');
      expect(back.entityKey, 'weight:w-1');
      expect(back.weightKg, 81.4);
      expect(back.recordedAt, ts);
    });

    test('favoriteUpsert/-Delete roundtrippen inkl. pinned', () {
      final fav = testFavorite(
        'barcode:4001234',
        result: _result(),
        pinned: true,
      );
      final back = SyncOp.tryFromJson(SyncOp.favoriteUpsert(fav).toJson());
      expect(back!.kind, SyncOpKind.favoriteUpsert);
      expect(back.favorite!.id, 'barcode:4001234');
      expect(back.favorite!.pinned, isTrue);
      expect(back.favorite!.addedAt, DateTime(2026, 8, 5, 13));

      final del = SyncOp.tryFromJson(
        SyncOp.favoriteDelete('barcode:4001234').toJson(),
      );
      expect(del!.entityKey, 'favorite:barcode:4001234');
    });

    test('recipeUpsert/-Delete roundtrippen ueber toRow/fromRow', () {
      const recipe = FitnessRecipe(
        slug: 'user_123',
        title: 'Eigenes Rezept',
        description: 'Test',
        portion: '1 Portion',
        ingredients: '- 100 g Test',
        preparation: '1. Testen.',
        professionalHint: 'Selbst angelegt.',
        imageAsset: '',
        caloriesKcal: 420,
        proteinG: 33,
        carbsG: 44,
        fatG: 11,
        estimatedGrams: 350,
        categories: <String>['Eigene'],
        userCreated: true,
      );
      final back = SyncOp.tryFromJson(SyncOp.recipeUpsert(recipe).toJson());
      expect(back!.kind, SyncOpKind.recipeUpsert);
      expect(back.entityKey, 'recipe:user_123');
      final r = back.recipe!;
      expect(r.slug, 'user_123');
      expect(r.title, 'Eigenes Rezept');
      expect(r.caloriesKcal, 420);
      expect(r.userCreated, isTrue);

      final del = SyncOp.tryFromJson(SyncOp.recipeDelete('user_123').toJson());
      expect(del!.kind, SyncOpKind.recipeDelete);
    });

    test('profileUpsert roundtrippt jedes Profilfeld', () {
      const profile = UserProfile(
        weightKg: 84,
        heightCm: 186,
        ageYears: 41,
        sex: BiologicalSex.female,
        activityLevel: ActivityLevel.athlete,
        targetWeightKg: 79,
        dailyStepsGoal: 12000,
        dailyKcalGoal: 1900,
        dailyWaterGoalMl: 3000,
        dailySleepGoalMinutes: 480,
        proteinGoalG: 150,
        carbsGoalG: 180,
        fatGoalG: 60,
        weightGoal: WeightGoal.lose05kg,
        diet: DietPreference.vegan,
        onboardingCompleted: true,
      );
      final back = SyncOp.tryFromJson(SyncOp.profileUpsert(profile).toJson());

      expect(back!.kind, SyncOpKind.profileUpsert);
      final p = back.profile!;
      expect(p.weightKg, 84);
      expect(p.heightCm, 186);
      expect(p.ageYears, 41);
      expect(p.sex, BiologicalSex.female);
      expect(p.activityLevel, ActivityLevel.athlete);
      expect(p.targetWeightKg, 79);
      expect(p.dailyStepsGoal, 12000);
      expect(p.dailyKcalGoal, 1900);
      expect(p.dailyWaterGoalMl, 3000);
      expect(p.dailySleepGoalMinutes, 480);
      expect(p.proteinGoalG, 150);
      expect(p.carbsGoalG, 180);
      expect(p.fatGoalG, 60);
      expect(p.weightGoal, WeightGoal.lose05kg);
      expect(p.diet, DietPreference.vegan);
      expect(p.onboardingCompleted, isTrue);
    });

    test('alle Profil-Ops teilen EINEN Entitaets-Schluessel — das Profil ist '
        'eine einzige Zeile', () {
      expect(
        SyncOp.profileUpsert(const UserProfile()).entityKey,
        'profile:self',
      );
      expect(
        SyncOp.profileUpsert(const UserProfile(weightKg: 91)).entityKey,
        'profile:self',
        reason:
            'sonst koaleszieren zwei Offline-Aenderungen nicht und '
            'ueberholen sich beim Replay',
      );
    });

    test(
      'ein unvollstaendiges Profil in der Payload ist UNLESBAR (null), nicht '
      'halb erfunden',
      () {
        // Counter-check to sentinel finding 3: missing numeric fields used to
        // fall back to ctor defaults, so a replay would write invented values
        // over the real server row. Replay retains a blocked invalid operation.
        final vollstaendig =
            jsonDecode(
                  jsonEncode(
                    SyncOp.profileUpsert(
                      const UserProfile(weightKg: 91),
                    ).toJson(),
                  ),
                )
                as Map<String, dynamic>;
        final payload = (vollstaendig['payload'] as Map)
            .cast<String, dynamic>();
        final profil = (payload['profile'] as Map).cast<String, dynamic>();
        profil.remove('daily_kcal_goal');

        final op = SyncOp.tryFromJson(<String, dynamic>{
          ...vollstaendig,
          'payload': <String, dynamic>{'profile': profil},
        });
        expect(op, isNotNull, reason: 'die Op selbst bleibt lesbar');
        expect(op!.profile, isNull);
      },
    );

    test('korrupte Eintraege liefern null statt Crash', () {
      expect(SyncOp.tryFromJson(const {}), isNull);
      expect(SyncOp.tryFromJson(const {'kind': 'zeitmaschine'}), isNull);
      expect(
        SyncOp.tryFromJson(const {'kind': 'mealInsert'}),
        isNull,
        reason: 'ohne entity_id ist die Op nicht zuordenbar',
      );
      // Broken payload: the op stays readable, meal is null, and the replay
      // lets such an op expire silently.
      final op = SyncOp.tryFromJson(const {
        'kind': 'mealInsert',
        'entity_id': 'm-x',
        'payload': {'meal': 'kein-objekt'},
      });
      expect(op, isNotNull);
      expect(op!.meal, isNull);
    });
  });

  group('SyncOp.trackingDay (Streak-Tag)', () {
    test('Roundtrip: der Tag steckt im entityId, die Payload bleibt leer', () {
      final op = SyncOp.trackingDay('2026-08-10');
      expect(op.entityKey, 'tracking:2026-08-10');
      expect(
        op.payload,
        isEmpty,
        reason:
            'der Tag IST die ganze Information — eine Payload waere nur '
            'eine zweite Stelle, an der er falsch stehen kann',
      );
      final back = SyncOp.tryFromJson(op.toJson())!;
      expect(back.kind, SyncOpKind.trackingDay);
      expect(back.entityId, '2026-08-10');
    });

  });

  group('SyncOp.attempts (Zustellversuchs-Budget)', () {
    test('frische Ops starten bei 0 — jede Factory, keine ausgelassen', () {
      final now = DateTime.utc(2026, 9, 10, 12);
      const id = '20260910-0000-4000-8000-000000000001';
      final planned = PlannedMeal.create(
        id: id,
        recipe: _recipe(),
        day: now,
        slot: MealSlot.lunch,
      );
      final history = TrainingHistoryEntry(
        snapshot: TrainingSessionSnapshot(
          sessionId: id,
          startedAt: now,
          plan: TrainingPlan(
            id: 'history-plan',
            proposal: CoachTrainingProposal(
              title: 'Plan',
              workouts: [
                TrainingWorkout(
                  title: 'A',
                  exercises: [
                    TrainingExercise(
                      name: 'Squat',
                      sets: 1,
                      reps: 8,
                      restSeconds: 0,
                    ),
                  ],
                ),
              ],
            ),
          ),
          workoutIndex: 0,
          exerciseIndex: 0,
          setIndex: 0,
          phase: TrainingSessionPhase.review,
          remainingMilliseconds: 0,
          completedSets: const [
            TrainingSetReference(exerciseIndex: 0, setIndex: 0),
          ],
          actualSets: [
            TrainingSetActual(
              reference: const TrainingSetReference(
                exerciseIndex: 0,
                setIndex: 0,
              ),
              reps: 8,
              completedAt: now,
            ),
          ],
        ),
        finishedAt: now,
      );
      final ops = <SyncOp>[
        SyncOp.mealPlanUpsert(planned),
        SyncOp.mealPlanConvert(
          planned.copyWith(eatenAt: now),
          LoggedMeal(
            id: id,
            result: _recipe().toMealResult(),
            loggedAt: now,
            localDay: '2026-09-10',
            forcedSlot: MealSlot.lunch,
          ),
          trackDay: true,
        ),
        SyncOp.shoppingCheck(
          ShoppingCheck(id: '2026-09-07:${'a' * 64}', checked: true),
        ),
        SyncOp.trainingHistoryInsert(history),
        SyncOp.trainingHistoryDelete(id),
        SyncOp.mealInsert(_meal('m-1'), trackDay: true),
        SyncOp.mealUpsert(_meal('m-1')),
        SyncOp.mealDelete('m-1'),
        SyncOp.weightInsert(
          id: 'w-1',
          weightKg: 80,
          recordedAt: DateTime(2026, 8, 6),
        ),
        SyncOp.favoriteUpsert(testFavorite('fav-1', result: _result())),
        SyncOp.favoriteDelete('fav-1'),
        SyncOp.recipeUpsert(_recipe()),
        SyncOp.recipeDelete('user_123'),
        SyncOp.trainingPlanUpsert(
          TrainingPlan(
            id: 'training',
            proposal: CoachTrainingProposal(
              title: 'Plan',
              workouts: [
                TrainingWorkout(
                  title: 'A',
                  exercises: [
                    TrainingExercise(
                      name: 'Squat',
                      sets: 3,
                      reps: 8,
                      restSeconds: 60,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        SyncOp.trainingPlanDelete('training'),
        SyncOp.profileUpsert(const UserProfile()),
        SyncOp.trackingDay('2026-08-10'),
        SyncOp.statsIncrement(
          requestId: '6561746f-7661-6d73-f461-74732d726964',
          meals: 1,
        ),
      ];
      expect(ops.map((o) => o.attempts), everyElement(0));
      // Completeness instead of a number in the test name: adding an op family
      // and forgetting it here turns the test red.
      expect(ops.map((o) => o.kind).toSet(), SyncOpKind.values.toSet());
    });

    test('Delete-Ops zaehlen ihre Versuche MIT — ohne Zaehler waeren sie '
        'unsterblich und die Outbox nie leer', () {
      // A dropped delete is the one loss the next cold start actively
      // reverses: the meal comes back from the server. Deletes therefore get a
      // much bigger but still finite budget ([kOutboxDeleteMaxAttempts]).
      // Without a counter they would keep the queue full forever: endless
      // retry timers, `preserveOutbox` permanently true, and a cap that can no
      // longer drain the overflow.
      final deletes = <SyncOp>[
        SyncOp.mealDelete('m-1'),
        SyncOp.favoriteDelete('barcode:4001234'),
        SyncOp.recipeDelete('user_123'),
        SyncOp.trainingPlanDelete('training'),
      ];
      for (final op in deletes) {
        expect(
          op.incrementAttempt().incrementAttempt().attempts,
          2,
          reason: '${op.kind.name} muss zaehlbar sein',
        );
        expect(
          op.incrementAttempt().toJson()['attempts'],
          1,
          reason: '${op.kind.name}: der Zaehler ueberlebt den App-Neustart',
        );
        expect(op.attempts, 0, reason: 'das Original bleibt unangetastet');
      }
      // Counter-check: write ops keep counting as before.
      expect(SyncOp.mealUpsert(_meal('m-1')).incrementAttempt().attempts, 1);
    });

    test('isDelete erkennt genau die drei Loesch-Familien', () {
      expect(SyncOp.mealDelete('m-1').isDelete, isTrue);
      expect(SyncOp.favoriteDelete('fav-1').isDelete, isTrue);
      expect(SyncOp.recipeDelete('user_123').isDelete, isTrue);

      // A lost streak day costs a counter; a lost delete resurrects user
      // data. The larger delete retry budget rests on that distinction.
      expect(
        SyncOp.trackingDay('2026-08-10').isDelete,
        isFalse,
        reason: 'ein Streak-Tag ist KEIN Delete',
      );
      expect(SyncOp.mealInsert(_meal('m-1'), trackDay: true).isDelete, isFalse);
      expect(SyncOp.mealUpsert(_meal('m-1')).isDelete, isFalse);
      expect(
        SyncOp.weightInsert(
          id: 'w-1',
          weightKg: 80,
          recordedAt: DateTime(2026, 8, 6),
        ).isDelete,
        isFalse,
      );
      expect(SyncOp.favoriteUpsert(testFavorite('fav-1')).isDelete, isFalse);
      expect(SyncOp.recipeUpsert(_recipe()).isDelete, isFalse);
      expect(SyncOp.profileUpsert(const UserProfile()).isDelete, isFalse);
    });

    test('incrementAttempt zaehlt hoch und behaelt alles andere', () {
      final op = SyncOp.mealInsert(_meal('m-1', kcal: 300), trackDay: true);
      final next = op.incrementAttempt().incrementAttempt();

      expect(op.attempts, 0, reason: 'das Original bleibt unangetastet');
      expect(next.attempts, 2);
      expect(next.kind, SyncOpKind.mealInsert);
      expect(next.entityId, 'm-1');
      expect(next.entityKey, 'meal:m-1');
      expect(next.trackDay, isTrue);
      expect(next.meal!.result.caloriesKcal, 300);
      expect(
        next.queuedAt,
        op.queuedAt,
        reason: 'queuedAt ist die FIFO-Position, kein Versuchs-Merkmal',
      );

      // The counter survives the blob: toJson carries it, tryFromJson reads it
      // back — without that the budget restarts at every app start.
      final json = next.toJson();
      expect(json['attempts'], 2);
      expect(SyncOp.tryFromJson(json)!.attempts, 2);
    });

    test(
      'attempts == 0 bleibt optional, operation_id bleibt beim Roundtrip',
      () {
        final json = SyncOp.mealUpsert(_meal('m-1')).toJson();
        expect(json.containsKey('attempts'), isFalse);
        expect(json.keys.toSet(), {
          'operation_id',
          'kind',
          'entity_id',
          'queued_at',
          'payload',
        });
        expect(SyncOp.tryFromJson(json)!.operationId, json['operation_id']);
      },
    );

    test('Legacy-JSON ohne attempts-Key laedt als 0 (Migrations-Beweis)', () {
      // Hand-written 4-key format from a build before this fix.
      const legacy = <String, dynamic>{
        'kind': 'mealDelete',
        'entity_id': 'm-legacy',
        'queued_at': '2026-08-05T12:30:00.000',
        'payload': <String, dynamic>{},
      };
      expect(legacy.keys, hasLength(4));

      final op = SyncOp.tryFromJson(legacy);
      expect(op, isNotNull);
      expect(op!.attempts, 0);
      expect(op.kind, SyncOpKind.mealDelete);
      expect(op.entityId, 'm-legacy');
      expect(op.queuedAt, DateTime(2026, 8, 5, 12, 30));
    });

    test('korrupte attempts fallen auf die sichere Seite (0)', () {
      Map<String, dynamic> withAttempts(Object? raw) => <String, dynamic>{
        'kind': 'mealDelete',
        'entity_id': 'm-1',
        'payload': const <String, dynamic>{},
        'attempts': raw,
      };

      expect(SyncOp.tryFromJson(withAttempts(-3))!.attempts, 0);
      expect(SyncOp.tryFromJson(withAttempts('viele'))!.attempts, 0);
      expect(SyncOp.tryFromJson(withAttempts(null))!.attempts, 0);
      // A double (e.g. from a JSON roundtrip) is truncated, not rejected.
      expect(SyncOp.tryFromJson(withAttempts(2.0))!.attempts, 2);
    });
  });

  // --- Fix 3: the counter follow-up op (statsIncrement) ---------------------
  //
  // It carries its server request id as entityId, the only op family whose
  // identity is also its idempotency key. So the wire format must roundtrip
  // losslessly (else the retry sends something else).

  group('SyncOp.statsIncrement (Fix 3)', () {
    const rid = '6561746f-7661-6d73-f461-74732d726964';

    test('Roundtrip: Id, Zahlen und Klassifizierung ueberleben den Blob', () {
      final op = SyncOp.statsIncrement(requestId: rid, meals: 1);
      expect(
        op.entityId,
        rid,
        reason:
            'die entityId IST die Request-Id — daran haengt der '
            'Server-Dedup',
      );
      expect(op.entityKey, 'stats:$rid');
      expect(op.isDelete, isFalse);

      final back = SyncOp.tryFromJson(op.toJson())!;
      expect(back.kind, SyncOpKind.statsIncrement);
      expect(back.entityId, rid);
      expect(back.statsMeals, 1);
      expect(back.statsWeightLogs, 0);
      expect(back.entityKey, 'stats:$rid');

      // The weight entry takes the same path with the fields swapped.
      final gewicht = SyncOp.tryFromJson(
        SyncOp.statsIncrement(requestId: rid, weightLogs: 1).toJson(),
      )!;
      expect(gewicht.statsWeightLogs, 1);
      expect(gewicht.statsMeals, 0);
    });

    test('Wire-Sparsamkeit: nur gesetzte Schluessel stehen im Blob', () {
      final op = SyncOp.statsIncrement(requestId: rid, meals: 1);
      expect(
        op.payload,
        <String, dynamic>{'meals': 1},
        reason:
            'ein 0-Schluessel waere Ballast in jedem persistierten '
            'Eintrag',
      );
    });

    test('korrupte/fehlende Zahlen liefern 0 statt zu werfen', () {
      // A tampered or half-written blob. The store drops it (A8); an increment
      // of 0 would be a request that only burns a request id.
      final kaputt = SyncOp.tryFromJson(<String, dynamic>{
        'kind': 'statsIncrement',
        'entity_id': rid,
        'queued_at': '2026-08-15T10:00:00.000Z',
        'payload': <String, dynamic>{'meals': 'eins'},
      })!;
      expect(kaputt.statsMeals, 0);
      expect(kaputt.statsWeightLogs, 0);
    });

    test('Rueckwaertskompatibilitaet: alte Blobs parsen unveraendert', () {
      // HAND-WRITTEN wire form from a build before fix 3 (no statsIncrement
      // anywhere, no attempts key), same technique as the legacy fixture in
      // 'Legacy-JSON ohne attempts-Key laedt als 0' above. Encoding the
      // fixture with today's `toJson()` would only prove that the current
      // encoder pairs with the current decoder — a renamed key would move in
      // both at once and the test could never turn red.
      const alt = <Map<String, dynamic>>[
        <String, dynamic>{
          'kind': 'mealInsert',
          'entity_id': 'm-alt',
          'queued_at': '2026-08-05T12:30:00.000',
          'payload': <String, dynamic>{
            'meal': <String, dynamic>{
              'id': 'm-alt',
              'logged_at': '2026-08-05T12:30:00.000',
              'forced_slot': 'lunch',
              'local_day': '2026-08-05',
              'result': <String, dynamic>{
                'mealName': 'Bowl',
                'caloriesKcal': 300,
                'estimatedGrams': 350,
                'kcalPer100G': 85.7,
                'protein': '30 g',
                'carbs': '40 g',
                'fat': '10 g',
                'confidence': 'Hoch',
                'portionNotes': 'Testportion.',
                'items': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'name': 'Reis',
                    'grams': 150,
                    'caloriesKcal': 195,
                  },
                ],
                'isAdjusted': false,
                'sourceLabel': 'Foto-KI',
                'barcode': '4001234',
                'brand': 'Testmarke',
              },
            },
            'track_day': true,
          },
        },
        <String, dynamic>{
          'kind': 'trackingDay',
          'entity_id': '2026-08-10',
          'queued_at': '2026-08-10T09:00:00.000',
          'payload': <String, dynamic>{},
        },
        <String, dynamic>{
          'kind': 'mealDelete',
          'entity_id': 'm-weg',
          'queued_at': '2026-08-05T18:00:00.000',
          'payload': <String, dynamic>{},
        },
      ];
      expect(
        alt.every((e) => !e.containsKey('attempts')),
        isTrue,
        reason: 'die Fixture waere sonst keine Vor-Fix-3-Fixture',
      );

      final gelesen = alt.map(SyncOp.tryFromJson).toList();
      expect(gelesen.every((o) => o != null), isTrue);
      expect(gelesen.map((o) => o!.kind).toList(), <SyncOpKind>[
        SyncOpKind.mealInsert,
        SyncOpKind.trackingDay,
        SyncOpKind.mealDelete,
      ]);
      expect(gelesen.map((o) => o!.entityId).toList(), <String>[
        'm-alt',
        '2026-08-10',
        'm-weg',
      ]);
      expect(gelesen.map((o) => o!.attempts).toList(), <int>[0, 0, 0]);

      final erste = gelesen.first!;
      expect(
        erste.trackDay,
        isTrue,
        reason:
            'eine Alt-Op behaelt alles, was der neue Replay fuer ihren '
            'Folgeeintrag braucht — es gibt keinen Migrationspfad',
      );
      expect(
        erste.queuedAt,
        DateTime(2026, 8, 5, 12, 30),
        reason: 'die FIFO-Position ueberlebt den Versionswechsel',
      );
      // Not just the envelope: the nested meal payload is readable too.
      expect(erste.meal!.id, 'm-alt');
      expect(erste.meal!.forcedSlot, MealSlot.lunch);
      expect(erste.meal!.localDay, '2026-08-05');
      expect(erste.meal!.result.caloriesKcal, 300);
      expect(erste.meal!.result.items.single.name, 'Reis');
      expect(erste.meal!.result.barcode, '4001234');
    });

    // Deliberately no 'an unknown kind does not take the queue down' test
    // here: `whereType<SyncOp>()` in such a test does the skipping itself, so
    // it can only assert its own filter. Both halves of the claim are pinned
    // where they actually live — `tryFromJson` returning null for an unknown
    // kind in 'korrupte Eintraege liefern null statt Crash' above, and the
    // PRODUCTIVE skipping in `LocalCache.readOutbox` in
    // test/services/local_cache_offline_state_test.dart ('Outbox roundtrippt;
    // korrupte Einzel-Ops werden uebersprungen').
  });
}
