import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/fitness_recipe.dart';
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
//   3. enqueueCoalesced keeps the queue short without breaking per-entity
//      order (insert -> update -> delete).
//   4. attempts roundtrips, stays backwards compatible (missing -> 0) and is
//      deliberately RESET on coalescing.
//   5. capOutbox caps the queue and drops the OLDEST ops. Deletes fall LAST —
//      losing one is the only loss the next cold start reverses rather than
//      heals — but they do fall: the cap is hard, else the blob grows without
//      bound.

/// The shared fixture plus the fields only the wire-format assertions here
/// care about: a component list, a barcode and a brand.
MealAnalysisResult _result({String name = 'Bowl', int kcal = 300}) =>
    testResult(
      name: name,
      kcal: kcal,
      items: const [
        MealComponent(name: 'Reis', grams: 150, caloriesKcal: 195),
      ],
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
      final upsert = SyncOp.tryFromJson(SyncOp.mealUpsert(_meal('m-2')).toJson());
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
      final fav =
          testFavorite('barcode:4001234', result: _result(), pinned: true);
      final back = SyncOp.tryFromJson(SyncOp.favoriteUpsert(fav).toJson());
      expect(back!.kind, SyncOpKind.favoriteUpsert);
      expect(back.favorite!.id, 'barcode:4001234');
      expect(back.favorite!.pinned, isTrue);
      expect(back.favorite!.addedAt, DateTime(2026, 8, 5, 13));

      final del = SyncOp.tryFromJson(
          SyncOp.favoriteDelete('barcode:4001234').toJson());
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

    test(
        'alle Profil-Ops teilen EINEN Entitaets-Schluessel — das Profil ist '
        'eine einzige Zeile', () {
      expect(SyncOp.profileUpsert(const UserProfile()).entityKey,
          'profile:self');
      expect(SyncOp.profileUpsert(const UserProfile(weightKg: 91)).entityKey,
          'profile:self',
          reason: 'sonst koaleszieren zwei Offline-Aenderungen nicht und '
              'ueberholen sich beim Replay');
    });

    test(
        'ein unvollstaendiges Profil in der Payload ist UNLESBAR (null), nicht '
        'halb erfunden', () {
      // Counter-check to sentinel finding 3: missing numeric fields used to
      // fall back to ctor defaults, so a replay would write invented values
      // over the real server row. Null means the replay drops the op instead.
      final vollstaendig =
          SyncOp.profileUpsert(const UserProfile(weightKg: 91)).toJson();
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
    });

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
      expect(op.payload, isEmpty,
          reason: 'der Tag IST die ganze Information — eine Payload waere nur '
              'eine zweite Stelle, an der er falsch stehen kann');
      final back = SyncOp.tryFromJson(op.toJson())!;
      expect(back.kind, SyncOpKind.trackingDay);
      expect(back.entityId, '2026-08-10');
    });

    test(
        'zwei Ops fuer denselben Tag koaleszieren zu einer, zwei Tage bleiben '
        'zwei', () {
      final eins = enqueueCoalesced(
          const <SyncOp>[], SyncOp.trackingDay('2026-08-10'));
      final nochmal =
          enqueueCoalesced(eins, SyncOp.trackingDay('2026-08-10'));
      expect(nochmal, hasLength(1),
          reason: 'sonst haengt sich bei jedem Log desselben Tages eine '
              'voellig identische Op an');
      final zweiTage =
          enqueueCoalesced(nochmal, SyncOp.trackingDay('2026-08-11'));
      expect(zweiTage.map((o) => o.entityId).toList(),
          <String>['2026-08-10', '2026-08-11'],
          reason: 'verschiedene Tage sind verschiedene Entitaeten und muessen '
              'in chronologischer Reihenfolge nachgespielt werden');
    });

  });

  group('SyncOp.attempts (Zustellversuchs-Budget)', () {
    test('frische Ops starten bei 0 — jede Factory, keine ausgelassen', () {
      final ops = <SyncOp>[
        SyncOp.mealInsert(_meal('m-1'), trackDay: true),
        SyncOp.mealUpsert(_meal('m-1')),
        SyncOp.mealDelete('m-1'),
        SyncOp.weightInsert(
            id: 'w-1', weightKg: 80, recordedAt: DateTime(2026, 8, 6)),
        SyncOp.favoriteUpsert(testFavorite('fav-1', result: _result())),
        SyncOp.favoriteDelete('fav-1'),
        SyncOp.recipeUpsert(_recipe()),
        SyncOp.recipeDelete('user_123'),
        SyncOp.profileUpsert(const UserProfile()),
        SyncOp.trackingDay('2026-08-10'),
        SyncOp.statsIncrement(
            requestId: '6561746f-7661-6d73-f461-74732d726964', meals: 1),
      ];
      expect(ops.map((o) => o.attempts), everyElement(0));
      // Completeness instead of a number in the test name: adding an op family
      // and forgetting it here turns the test red.
      expect(ops.map((o) => o.kind).toSet(), SyncOpKind.values.toSet());
    });

    test(
        'Delete-Ops zaehlen ihre Versuche MIT — ohne Zaehler waeren sie '
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
      ];
      for (final op in deletes) {
        expect(op.incrementAttempt().incrementAttempt().attempts, 2,
            reason: '${op.kind.name} muss zaehlbar sein');
        expect(op.incrementAttempt().toJson()['attempts'], 1,
            reason: '${op.kind.name}: der Zaehler ueberlebt den App-Neustart');
        expect(op.attempts, 0, reason: 'das Original bleibt unangetastet');
      }
      // Counter-check: write ops keep counting as before.
      expect(SyncOp.mealUpsert(_meal('m-1')).incrementAttempt().attempts, 1);
    });

    test('isDelete erkennt genau die drei Loesch-Familien', () {
      expect(SyncOp.mealDelete('m-1').isDelete, isTrue);
      expect(SyncOp.favoriteDelete('fav-1').isDelete, isTrue);
      expect(SyncOp.recipeDelete('user_123').isDelete, isTrue);

      // A dropped streak day costs a counter; a dropped delete resurrects user
      // data. capOutbox's ordering rests on that distinction.
      expect(SyncOp.trackingDay('2026-08-10').isDelete, isFalse,
          reason: 'ein Streak-Tag ist KEIN Delete — er faellt am Cap zuerst');
      expect(SyncOp.mealInsert(_meal('m-1'), trackDay: true).isDelete, isFalse);
      expect(SyncOp.mealUpsert(_meal('m-1')).isDelete, isFalse);
      expect(
          SyncOp.weightInsert(
                  id: 'w-1', weightKg: 80, recordedAt: DateTime(2026, 8, 6))
              .isDelete,
          isFalse);
      expect(SyncOp.favoriteUpsert(testFavorite('fav-1')).isDelete, isFalse);
      expect(SyncOp.recipeUpsert(_recipe()).isDelete, isFalse);
      expect(SyncOp.profileUpsert(const UserProfile()).isDelete, isFalse);
    });

    test(
        'profileUpsert ist ein Upsert — sonst koaleszieren zwei Aenderungen '
        'derselben Profilzeile nicht', () {
      final queue = enqueueCoalesced(
        <SyncOp>[SyncOp.profileUpsert(const UserProfile(weightKg: 84))],
        SyncOp.profileUpsert(const UserProfile(weightKg: 86)),
      );

      expect(SyncOp.profileUpsert(const UserProfile()).isUpsert, isTrue);
      expect(queue, hasLength(1));
      expect(queue.single.profile!.weightKg, 86,
          reason: 'die letzte Aenderung gewinnt');
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
      expect(next.queuedAt, op.queuedAt,
          reason: 'queuedAt ist die FIFO-Position, kein Versuchs-Merkmal');

      // The counter survives the blob: toJson carries it, tryFromJson reads it
      // back — without that the budget restarts at every app start.
      final json = next.toJson();
      expect(json['attempts'], 2);
      expect(SyncOp.tryFromJson(json)!.attempts, 2);
    });

    test('attempts == 0 taucht im JSON gar nicht auf (Wire-Format bleibt '
        'byte-identisch zum alten Build)', () {
      final json = SyncOp.mealUpsert(_meal('m-1')).toJson();
      expect(json.containsKey('attempts'), isFalse);
      expect(json.keys.toSet(),
          {'kind', 'entity_id', 'queued_at', 'payload'});
    });

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

  group('enqueueCoalesced', () {
    test('wiederholtes Upsert derselben Entitaet ersetzt den Payload', () {
      var queue = <SyncOp>[];
      queue = enqueueCoalesced(queue, SyncOp.mealUpsert(_meal('m-1', kcal: 300)));
      queue = enqueueCoalesced(queue, SyncOp.mealUpsert(_meal('m-1', kcal: 500)));

      expect(queue, hasLength(1));
      expect(queue.single.meal!.result.caloriesKcal, 500);
    });

    test('mealUpsert auf pendenden mealInsert behaelt Kind + track_day', () {
      var queue = <SyncOp>[];
      queue = enqueueCoalesced(
          queue, SyncOp.mealInsert(_meal('m-1', kcal: 300), trackDay: true));
      queue = enqueueCoalesced(queue, SyncOp.mealUpsert(_meal('m-1', kcal: 500)));

      expect(queue, hasLength(1));
      expect(queue.single.kind, SyncOpKind.mealInsert,
          reason: 'die Stats-Zaehlung des Erst-Inserts darf nicht verlorengehen');
      expect(queue.single.trackDay, isTrue);
      expect(queue.single.meal!.result.caloriesKcal, 500);
    });

    test('Delete wird angehaengt, nie koalesziert (FIFO pro Entitaet)', () {
      var queue = <SyncOp>[];
      queue = enqueueCoalesced(
          queue, SyncOp.mealInsert(_meal('m-1'), trackDay: false));
      queue = enqueueCoalesced(queue, SyncOp.mealDelete('m-1'));

      expect(queue.map((o) => o.kind),
          [SyncOpKind.mealInsert, SyncOpKind.mealDelete]);
    });

    test('Upsert NACH Delete (Undo) wird dahinter angehaengt', () {
      var queue = <SyncOp>[];
      queue = enqueueCoalesced(queue, SyncOp.mealDelete('m-1'));
      queue = enqueueCoalesced(queue, SyncOp.mealUpsert(_meal('m-1')));

      expect(queue.map((o) => o.kind),
          [SyncOpKind.mealDelete, SyncOpKind.mealUpsert]);
    });

    test('fremde Entitaeten bleiben unberuehrt', () {
      var queue = <SyncOp>[];
      queue = enqueueCoalesced(queue, SyncOp.mealUpsert(_meal('m-1')));
      queue = enqueueCoalesced(queue, SyncOp.mealUpsert(_meal('m-2')));

      expect(queue, hasLength(2));
    });

    test('appendOnly (Replay laeuft) haengt IMMER an', () {
      var queue = <SyncOp>[];
      queue = enqueueCoalesced(queue, SyncOp.mealUpsert(_meal('m-1', kcal: 300)));
      queue = enqueueCoalesced(
        queue,
        SyncOp.mealUpsert(_meal('m-1', kcal: 500)),
        appendOnly: true,
      );

      expect(queue, hasLength(2),
          reason: 'die gerade abgespielte Op darf nicht mutiert werden');
    });

    test(
        'Koaleszenz SETZT attempts ZURUECK — die korrigierte Eingabe darf '
        'nicht am Budget der kaputten sterben', () {
      // Scenario: 200000 kcal typed -> check constraint, counter climbs.
      var poisoned =
          SyncOp.mealInsert(_meal('m-1', kcal: 200000), trackDay: true);
      poisoned = poisoned.incrementAttempt().incrementAttempt().incrementAttempt();
      expect(poisoned.attempts, 3);

      // The user corrects to 500, a perfectly valid payload.
      final queue = enqueueCoalesced(
          <SyncOp>[poisoned], SyncOp.mealUpsert(_meal('m-1', kcal: 500)));

      expect(queue, hasLength(1));
      expect(queue.single.attempts, 0,
          reason: 'der Zaehler misst die alte Payload, nicht die neue');
      expect(queue.single.kind, SyncOpKind.mealInsert,
          reason: 'die Stats-Zaehlung des Erst-Inserts bleibt erhalten');
      expect(queue.single.trackDay, isTrue);
      expect(queue.single.meal!.result.caloriesKcal, 500);
      expect(queue.single.queuedAt, poisoned.queuedAt,
          reason: 'queuedAt = FIFO-Position, unabhaengig von der Payload');
    });

    test('appendOnly haengt eine frische Op mit attempts 0 an und laesst die '
        'in-flight-Op unberuehrt', () {
      final inFlight = SyncOp.mealUpsert(_meal('m-1', kcal: 300))
          .incrementAttempt()
          .incrementAttempt();
      final queue = enqueueCoalesced(
        <SyncOp>[inFlight],
        SyncOp.mealUpsert(_meal('m-1', kcal: 500)),
        appendOnly: true,
      );

      expect(queue, hasLength(2));
      expect(queue.first.attempts, 2);
      expect(queue.first.meal!.result.caloriesKcal, 300);
      expect(queue.last.attempts, 0);
      expect(queue.last.meal!.result.caloriesKcal, 500);
    });
  });

  group('capOutbox', () {
    test('unter dem Cap bleibt die Queue exakt dieselbe', () {
      final queue = <SyncOp>[
        SyncOp.mealDelete('a'),
        SyncOp.mealDelete('b'),
      ];
      final capped = capOutbox(queue, maxOps: 5);

      expect(capped.queue, same(queue));
      expect(capped.dropped, isEmpty);

      // Exactly at the cap nothing is touched either.
      expect(capOutbox(queue, maxOps: 2).dropped, isEmpty);
    });

    // Same head trim for both op families: the ONLY difference is whether the
    // queue holds writes or deletes. "Never cap deletes" would disable the cap
    // entirely for a queue of undeliverable deletes — exactly the unbounded
    // blob growth the cap exists against. Resolution: deletes fall LAST, but
    // they fall; the store then restores the affected entries and says so.
    for (final (art, baue) in <(String, SyncOp Function(int))>[
      ('Schreib-Ops', (i) => SyncOp.mealUpsert(_meal('m-$i'))),
      ('Loesch-Ops', (i) => SyncOp.mealDelete('m-$i')),
    ]) {
      test('ueber dem Cap fliegen die AELTESTEN $art raus (Kopf-Trim)', () {
        final queue = <SyncOp>[for (var i = 0; i < 6; i++) baue(i)];
        final capped = capOutbox(queue, maxOps: 4);

        expect(capped.queue, hasLength(4));
        expect(capped.queue.map((o) => o.entityId).toList(),
            <String>['m-2', 'm-3', 'm-4', 'm-5'],
            reason: 'das Neueste — worauf der User gerade schaut — bleibt');
        expect(capped.dropped.map((o) => o.entityId).toList(),
            <String>['m-0', 'm-1'],
            reason: 'aeltestes zuerst');
      });
    }

    test(
        'Deletes ueberleben den Kopf-Trim — sonst kehrt die geloeschte '
        'Mahlzeit beim naechsten Kaltstart vom Server zurueck', () {
      final queue = <SyncOp>[
        SyncOp.mealUpsert(_meal('m-0')),
        SyncOp.mealDelete('m-del'),
        SyncOp.mealUpsert(_meal('m-1')),
        SyncOp.favoriteDelete('barcode:4001234'),
        SyncOp.mealUpsert(_meal('m-2')),
        SyncOp.recipeDelete('user_123'),
        SyncOp.mealUpsert(_meal('m-3')),
      ];
      final capped = capOutbox(queue, maxOps: 4);

      // Trimming happens only from the head, oldest first.
      expect(capped.dropped.map((o) => o.entityId).toList(),
          <String>['m-0', 'm-1', 'm-2']);
      expect(capped.dropped.map((o) => o.isDelete), everyElement(isFalse));
      expect(
          capped.queue.map((o) => o.entityKey).toList(),
          <String>[
            'meal:m-del',
            'favorite:barcode:4001234',
            'recipe:user_123',
            'meal:m-3',
          ],
          reason: 'FIFO-Reihenfolge bleibt, alle drei Loeschungen bleiben');
    });

    test(
        'gemischte Queue ueber dem Cap: erst fallen ALLE Schreib-Ops, '
        'Deletes erst danach', () {
      final queue = <SyncOp>[
        SyncOp.mealUpsert(_meal('m-0')),
        SyncOp.mealDelete('d-0'),
        SyncOp.mealUpsert(_meal('m-1')),
        SyncOp.mealDelete('d-1'),
        SyncOp.mealDelete('d-2'),
      ];
      final capped = capOutbox(queue, maxOps: 2);

      expect(capped.dropped.map((o) => o.entityId).toList(),
          <String>['m-0', 'm-1', 'd-0'],
          reason: 'die zwei Schreib-Ops zuerst, dann der aelteste Delete');
      expect(capped.queue.map((o) => o.entityId).toList(),
          <String>['d-1', 'd-2']);
      expect(capped.queue.length + capped.dropped.length, queue.length,
          reason: 'nichts geht unterwegs verloren');
    });

    test('massiv uebergrosse Legacy-Queue kollabiert in EINEM Durchlauf', () {
      final queue = <SyncOp>[
        for (var i = 0; i < kOutboxMaxOps * 3; i++)
          SyncOp.weightInsert(
              id: 'w-$i', weightKg: 80, recordedAt: DateTime(2026, 8, 6)),
      ];
      final capped = capOutbox(queue);

      expect(capped.queue, hasLength(kOutboxMaxOps));
      expect(capped.dropped, hasLength(kOutboxMaxOps * 2));
      expect(capped.queue.first.entityId, 'w-${kOutboxMaxOps * 2}');
      expect(capped.queue.last.entityId, 'w-${kOutboxMaxOps * 3 - 1}');
      // Idempotent: a second pass finds nothing left to cap.
      expect(capOutbox(capped.queue).dropped, isEmpty);
    });
  });

  // --- Fix 3: the counter follow-up op (statsIncrement) ---------------------
  //
  // It carries its server request id as entityId, the only op family whose
  // identity is also its idempotency key. So the wire format must roundtrip
  // losslessly (else the retry sends something else), and the entry must never
  // be coalesced (that would swallow a counter whose id the server may already
  // have booked).

  group('SyncOp.statsIncrement (Fix 3)', () {
    const rid = '6561746f-7661-6d73-f461-74732d726964';

    test('Roundtrip: Id, Zahlen und Klassifizierung ueberleben den Blob', () {
      final op = SyncOp.statsIncrement(requestId: rid, meals: 1);
      expect(op.entityId, rid,
          reason: 'die entityId IST die Request-Id — daran haengt der '
              'Server-Dedup');
      expect(op.entityKey, 'stats:$rid');
      expect(op.isDelete, isFalse);
      expect(op.isUpsert, isFalse,
          reason: 'jeder Eintrag ist eine eigene idempotente Einheit und wird '
              'immer angehaengt, nie ersetzt');

      final back = SyncOp.tryFromJson(op.toJson())!;
      expect(back.kind, SyncOpKind.statsIncrement);
      expect(back.entityId, rid);
      expect(back.statsMeals, 1);
      expect(back.statsWeightLogs, 0);
      expect(back.entityKey, 'stats:$rid');

      // The weight entry takes the same path with the fields swapped.
      final gewicht = SyncOp.tryFromJson(
          SyncOp.statsIncrement(requestId: rid, weightLogs: 1).toJson())!;
      expect(gewicht.statsWeightLogs, 1);
      expect(gewicht.statsMeals, 0);
    });

    test('Wire-Sparsamkeit: nur gesetzte Schluessel stehen im Blob', () {
      final op = SyncOp.statsIncrement(requestId: rid, meals: 1);
      expect(op.payload, <String, dynamic>{'meals': 1},
          reason: 'ein 0-Schluessel waere Ballast in jedem persistierten '
              'Eintrag');
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

    test(
        'enqueueCoalesced haengt IMMER an — auch beim zweiten Eintrag mit '
        'demselben entityKey', () {
      final erste = enqueueCoalesced(
          const <SyncOp>[], SyncOp.statsIncrement(requestId: rid, meals: 1));
      final zweite = enqueueCoalesced(
          erste, SyncOp.statsIncrement(requestId: rid, meals: 1));
      expect(zweite, hasLength(2),
          reason: 'Ersetzen wuerde einen Zaehler verschlucken; ein Duplikat '
              'ist dagegen serverseitig ein No-op (gleiche Id)');
      final fremde = enqueueCoalesced(
          zweite,
          SyncOp.statsIncrement(
              requestId: '00000000-0000-4000-8000-000000000000',
              weightLogs: 1));
      expect(fremde, hasLength(3));
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
      expect(alt.every((e) => !e.containsKey('attempts')), isTrue,
          reason: 'die Fixture waere sonst keine Vor-Fix-3-Fixture');

      final gelesen = alt.map(SyncOp.tryFromJson).toList();
      expect(gelesen.every((o) => o != null), isTrue);
      expect(gelesen.map((o) => o!.kind).toList(), <SyncOpKind>[
        SyncOpKind.mealInsert,
        SyncOpKind.trackingDay,
        SyncOpKind.mealDelete,
      ]);
      expect(gelesen.map((o) => o!.entityId).toList(),
          <String>['m-alt', '2026-08-10', 'm-weg']);
      expect(gelesen.map((o) => o!.attempts).toList(), <int>[0, 0, 0]);

      final erste = gelesen.first!;
      expect(erste.trackDay, isTrue,
          reason: 'eine Alt-Op behaelt alles, was der neue Replay fuer ihren '
              'Folgeeintrag braucht — es gibt keinen Migrationspfad');
      expect(erste.queuedAt, DateTime(2026, 8, 5, 12, 30),
          reason: 'die FIFO-Position ueberlebt den Versionswechsel');
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
