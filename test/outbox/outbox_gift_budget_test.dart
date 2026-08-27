import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';

// kOutboxDeleteMinAge lives in the store's sync part, not in sync_outbox.
import 'package:eatova/src/app/home_store.dart' show kOutboxDeleteMinAge;
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/sync_error_messages.dart'
    show outboxDeleteLossHint, outboxLossHint;
import 'package:eatova/src/services/sync_outbox.dart';

import 'outbox_test_helpers.dart';

// When an op may die: poison SQLSTATEs, the attempt budget plus its 24 h wall
// clock, and the delete path with its own, longer budget — a dropped delete
// re-displays the meal instead of letting it resurrect silently.

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
      'Gift-Op (23502 not_null_violation) wird beim ERSTEN Replay verworfen, '
      'verschwindet aus der persistierten Queue und meldet sich GENAU EINMAL',
      () async {
    final s = setup();
    await boot(s.store);
    s.server.poisonMealWrites = true;

    final id = s.store.addResultToDailyTotal(mealResult('Kaputt-Bowl'));
    await settle();

    // The live write does not classify: the op is queued first.
    expect(s.store.pendingOutbox.map((o) => o.entityKey),
        contains('meal:$id'));

    s.store.flushPendingWrites();
    await settle();

    // ONE replay is enough: the op is gone from memory AND the blob.
    expect(s.store.pendingOutbox.where((o) => o.entityKey == 'meal:$id'),
        isEmpty);
    final persisted = await s.cache.readOutbox();
    expect(persisted!.where((o) => o.entityKey == 'meal:$id'), isEmpty);

    // ONE loss hint, even after further flush rounds.
    s.store.flushPendingWrites();
    await settle();
    expect(s.snacks.messages.where((m) => m == outboxLossHint()), hasLength(1));

    // Schema-leak guard.
    for (final m in s.snacks.messages) {
      expect(m, isNot(contains('23502')));
      expect(m, isNot(contains('logged_meals')));
      expect(m, isNot(contains('not-null constraint')));
      expect(m, isNot(contains('PostgrestException')));
    }
  });

  test(
      '500 verbrennt Versuche, wird aber NICHT vorzeitig verworfen — '
      'Erholung vor dem Budget-Ende synchronisiert normal', () async {
    final s = setup();
    await boot(s.store);
    s.server.rejectMealWrites = true;

    final id = s.store.addResultToDailyTotal(mealResult('Flaky-Bowl'));
    await settle();
    expect(
        s.store.pendingOutbox
            .singleWhere((o) => o.entityKey == 'meal:$id')
            .attempts,
        0,
        reason: 'der Live-Versuch zaehlt nicht, erst der Replay');

    for (var i = 0; i < 3; i++) {
      s.store.flushPendingWrites();
      await settle();
    }

    final op =
        s.store.pendingOutbox.singleWhere((o) => o.entityKey == 'meal:$id');
    expect(op.attempts, 3);
    expect(s.snacks.messages.where((m) => m == outboxLossHint()), isEmpty,
        reason: 'ein 500 ist kein Grund, Nutzerdaten wegzuwerfen');

    s.server.rejectMealWrites = false;
    s.store.flushPendingWrites();
    await settle();

    expect(s.store.pendingOutbox, isEmpty);
    expect(s.server.mealRows.keys, contains(id));
  });

  test(
      'Netzwerkfehler verbrennen NIE Versuche: 3x das ganze Budget offline '
      'durchspielen laesst die Op unangetastet', () async {
    final s = setup();
    await boot(s.store);
    s.server.offline = true;

    final id = s.store.addResultToDailyTotal(mealResult('Offline-Bowl'));
    await settle();

    for (var i = 0; i < kOutboxMaxAttempts * 3; i++) {
      s.store.flushPendingWrites();
      await settle();
    }

    final op =
        s.store.pendingOutbox.singleWhere((o) => o.entityKey == 'meal:$id');
    expect(op.attempts, 0,
        reason: 'ein Offline-Wochenende darf kein Budget kosten');
    expect(s.snacks.messages.where((m) => m == outboxLossHint()), isEmpty);

    s.server.offline = false;
    s.store.flushPendingWrites();
    await settle();

    expect(s.store.pendingOutbox, isEmpty);
    expect(s.server.mealRows.keys, contains(id));
  });

  // --- Review 2026-08-08: A4 (budget), A6 (orphan), A8 (corrupt payload) ----

  test(
      'A4: Lifecycle-Churn frisst das Versuchs-Budget nicht mehr auf — 12 '
      'Durchlaeufe in Sekunden lassen die Op stehen', () async {
    final s = setup();
    await boot(s.store);
    s.server.rejectMealWrites = true;

    final id = s.store.addResultToDailyTotal(mealResult('Ausfall-Bowl'));
    await settle();

    // One app switch triggers up to four flushes: an outage burns a dozen.
    for (var i = 0; i < 12; i++) {
      s.store.flushPendingWrites();
      await settle();
    }

    expect(
      s.store.pendingOutbox.where((o) => o.entityKey == 'meal:$id'),
      hasLength(1),
      reason: 'Wanduhrzeit entscheidet, nicht die Zahl der Durchlaeufe',
    );
    expect(s.snacks.messages.where((m) => m == outboxLossHint()), isEmpty);

    s.server.rejectMealWrites = false;
    s.store.flushPendingWrites();
    await settle();
    expect(s.store.pendingOutbox, isEmpty);
    expect(s.server.mealRows.keys, contains(id));
  });

  test(
      'A4: das Budget ist trotzdem eine Notbremse — eine seit ueber 24 h '
      'abgelehnte Op wird verworfen', () async {
    final kv = InMemoryKeyValueStore();
    final meal = LoggedMeal(
      id: 'm-uralt',
      result: mealResult('Uralt-Bowl'),
      loggedAt: DateTime.now(),
    );
    await seedRawOutbox(kv, [
      SyncOp.mealInsert(meal, trackDay: false).toJson()
        ..['queued_at'] = DateTime.now()
            .subtract(const Duration(hours: 25))
            .toIso8601String()
        ..['attempts'] = kOutboxMaxAttempts - 1,
    ]);

    final s = setup(kv: kv);
    s.server.rejectMealWrites = true;
    await boot(s.store);

    expect(s.store.pendingOutbox.where((o) => o.entityKey == 'meal:m-uralt'),
        isEmpty);
    expect(s.snacks.messages.where((m) => m == outboxLossHint()), hasLength(1));
  });

  test(
      'Nebenbefund: die 24-h-Frist haengt an der injizierten Uhr, nicht an '
      'DateTime.now() — vorher war sie ueberhaupt nicht pruefbar', () async {
    // Reference time far from the system clock, else both cases collapse.
    final queuedAt = DateTime(2030, 5, 17, 8);
    Future<List<SyncOp>> runAt(DateTime now) async {
      final kv = InMemoryKeyValueStore();
      await seedRawOutbox(kv, [
        SyncOp.mealInsert(
                LoggedMeal(
                    id: 'm-uhr',
                    result: mealResult('Uhr-Bowl'),
                    loggedAt: queuedAt),
                trackDay: false)
            .toJson()
          ..['queued_at'] = queuedAt.toIso8601String()
          ..['attempts'] = kOutboxMaxAttempts - 1,
      ]);
      return withClock(Clock.fixed(now), () async {
        final s = setup(kv: kv);
        s.server.rejectMealWrites = true;
        await boot(s.store);
        return s.store.pendingOutbox.toList();
      });
    }

    // 23 h after enqueueing: budget spent, wall clock says no, meal stays.
    expect(
      (await runAt(queuedAt.add(const Duration(hours: 23))))
          .map((o) => o.entityKey),
      contains('meal:m-uhr'),
    );
    // 25 h: now the emergency brake bites.
    expect(
      (await runAt(queuedAt.add(const Duration(hours: 25))))
          .map((o) => o.entityKey),
      isNot(contains('meal:m-uhr')),
    );
  });

  test(
      'A6: nach einem Verwurf ist die Entitaet nicht verwaist — die naechste '
      'Aenderung laeuft als frischer Upsert statt als 0-Zeilen-PATCH',
      () async {
    final s = setup();
    await boot(s.store);
    s.server.poisonMealWrites = true;

    final id = s.store.addResultToDailyTotal(mealResult('Waisen-Bowl'));
    await settle();
    s.store.flushPendingWrites();
    await settle();

    // Precondition: op dropped, meal visible locally, absent on the server.
    expect(
        s.store.pendingOutbox.where((o) => o.entityKey == 'meal:$id'), isEmpty);
    expect(s.store.loggedMeals.map((m) => m.id), contains(id));
    expect(s.server.mealRows.keys, isNot(contains(id)));
    expect(s.snacks.messages.where((m) => m == outboxLossHint()), hasLength(1));

    s.server.poisonMealWrites = false;
    s.store.updateLoggedMealResult(id, mealResult('Waisen-Bowl', kcal: 500));
    await settle();

    // A PATCH hitting 0 rows is a 204, not an error: silent loss.
    expect(
      s.server.requests.where(
          (r) => r.method == 'PATCH' && r.url.path.contains('/logged_meals')),
      isEmpty,
      reason: 'kein PATCH auf eine Zeile, die es serverseitig nicht gibt',
    );

    s.store.flushPendingWrites();
    await settle();

    expect(s.server.mealRows.keys, contains(id),
        reason: 'der Upsert-Weg repariert die Entitaet');
    expect(s.server.mealRows[id]!['calories_kcal'], 500);
    expect(s.store.pendingOutbox, isEmpty);
  });

  test(
      'A8: eine korrupte Payload verschwindet nicht als "Erfolg", sondern '
      'laeuft ueber den Verwurfs-Pfad', () async {
    final kv = InMemoryKeyValueStore();
    await seedRawOutbox(kv, [
      <String, dynamic>{
        'kind': 'mealInsert',
        'entity_id': 'm-korrupt',
        'queued_at': DateTime.now().toIso8601String(),
        // Non-map payload: tryFromJson KEEPS the op with {}, reaching this.
        'payload': 'kaputt',
      },
    ]);

    final s = setup(kv: kv);
    await boot(s.store);

    expect(s.store.pendingOutbox, isEmpty);
    expect(
      s.server.requests.where(
          (r) => r.method == 'POST' && r.url.path.contains('/logged_meals')),
      isEmpty,
    );
    // The user is told: this used to be the only silent data-loss path.
    expect(s.snacks.messages.where((m) => m == outboxLossHint()), hasLength(1));
  });

  // --- Verification V1 (wave 6): the delete path ----------------------------

  test(
      'L1: ein Delete gegen einen kalten Schema-Cache (400/SQLSTATE) wird '
      'NICHT sofort verworfen — die Mahlzeit bleibt geloescht', () async {
    final s = setup();
    await boot(s.store);
    final id = s.store.addResultToDailyTotal(mealResult('Fehlscan-Bowl'));
    await settle();
    expect(s.server.mealRows.keys, contains(id),
        reason: 'Vorbedingung: die Zeile steht auf dem Server');

    // Schema cache cold: EVERY logged_meals write, DELETE included, 400s.
    s.server.poisonMealWrites = true;
    s.store.removeLoggedMeal(id);
    await settle();
    for (var i = 0; i < 5; i++) {
      s.store.flushPendingWrites();
      await settle();
    }

    // Dropping on the first replay left the server row, so the next cold
    // start brought the meal back.
    expect(s.store.pendingOutbox.map((o) => o.entityKey), contains('meal:$id'),
        reason: 'die Loeschung darf nicht am Code-Verdikt sterben');
    expect(s.server.mealRows.keys, contains(id));
    expect(s.snacks.messages.where((m) => m == outboxLossHint()), isEmpty);
    expect(s.snacks.messages.where((m) => m == outboxDeleteLossHint()), isEmpty);

    s.server.poisonMealWrites = false;
    s.store.flushPendingWrites();
    await settle();
    expect(s.store.pendingOutbox, isEmpty);
    expect(s.server.mealRows.keys, isNot(contains(id)));
  });

  test(
      'L2: ein endgueltig gescheiterter Delete blendet die Mahlzeit lokal '
      'wieder ein und sagt es — statt sie still auferstehen zu lassen',
      () async {
    final kv = InMemoryKeyValueStore();
    // A delete at the end of its budget and its deadline.
    await seedRawOutbox(kv, [
      SyncOp.mealDelete('m-geist').toJson()
        ..['queued_at'] = DateTime.now()
            .subtract(kOutboxDeleteMinAge + const Duration(hours: 1))
            .toIso8601String()
        ..['attempts'] = kOutboxDeleteMaxAttempts - 1,
    ]);

    final s = setup(kv: kv);
    // Boot offline: the replay is free and the boot load brings no meal, so
    // the re-display is what is proven.
    s.server.offline = true;
    await boot(s.store);
    expect(s.store.pendingOutbox, hasLength(1));
    expect(s.store.loggedMeals, isEmpty);

    // Network back; the row is still there and the delete keeps failing.
    s.server.offline = false;
    s.server.mealRows['m-geist'] = serverMealRow('m-geist', kcal: 1800);
    s.server.poisonMealWrites = true;
    s.store.flushPendingWrites();
    await settle();

    // The op is gone and the queue drains, else the retry timer never stops.
    expect(s.store.pendingOutbox, isEmpty);
    expect((await s.cache.readOutbox())!, isEmpty);
    // The meal is visible again and the user is told what to do.
    expect(s.store.loggedMeals.map((m) => m.id), contains('m-geist'));
    expect(s.store.dailyConsumedKcal, 1800,
        reason: 'die Kalorien zaehlen wieder — das darf nicht unsichtbar sein');
    expect(s.snacks.messages.where((m) => m == outboxDeleteLossHint()),
        hasLength(1));
    for (final m in s.snacks.messages) {
      expect(m, isNot(contains('logged_meals')));
      expect(m, isNot(contains('23502')));
      expect(m, isNot(contains('PostgrestException')));
    }
  });

  test(
      'L2 ausserhalb des Boot-Fensters: auch eine ALTE Mahlzeit wird nach dem '
      'endgueltigen Delete-Verwurf wieder eingeblendet — der "wieder da"-'
      'Hinweis muss auch fuer Alt-Tage stimmen', () async {
    final kv = InMemoryKeyValueStore();
    await seedRawOutbox(kv, [
      SyncOp.mealDelete('m-alt').toJson()
        ..['queued_at'] = DateTime.now()
            .subtract(kOutboxDeleteMinAge + const Duration(hours: 1))
            .toIso8601String()
        ..['attempts'] = kOutboxDeleteMaxAttempts - 1,
    ]);
    final s = setup(kv: kv);
    s.server.offline = true;
    await boot(s.store);

    // The row is 60 days old: only a targeted read by id brings it back.
    s.server.offline = false;
    final oldRow = serverMealRow('m-alt', kcal: 1200);
    oldRow['logged_at'] = DateTime.now()
        .toUtc()
        .subtract(const Duration(days: 60))
        .toIso8601String();
    s.server.mealRows['m-alt'] = oldRow;
    s.server.poisonMealWrites = true;
    s.store.flushPendingWrites();
    await settle();

    expect(s.store.pendingOutbox, isEmpty);
    expect(s.snacks.messages.where((m) => m == outboxDeleteLossHint()),
        hasLength(1));
    expect(s.store.loggedMeals.map((m) => m.id), contains('m-alt'),
        reason: 'die Meldung verspricht die Wiedereinblendung — fuer eine '
            'Zeile ausserhalb des 35-Tage-Fensters muss sie gezielt geladen '
            'werden, nicht ueber den Fenster-Load');
  });

  test(
      'L2: der Nutzer kann die wieder eingeblendete Mahlzeit erneut loeschen '
      '— frisches Budget, frische Frist', () async {
    final kv = InMemoryKeyValueStore();
    await seedRawOutbox(kv, [
      SyncOp.mealDelete('m-geist').toJson()
        ..['queued_at'] = DateTime.now()
            .subtract(kOutboxDeleteMinAge + const Duration(hours: 1))
            .toIso8601String()
        ..['attempts'] = kOutboxDeleteMaxAttempts - 1,
    ]);
    final s = setup(kv: kv);
    s.server.offline = true;
    await boot(s.store);
    s.server.offline = false;
    s.server.mealRows['m-geist'] = serverMealRow('m-geist', kcal: 1800);
    s.server.poisonMealWrites = true;
    s.store.flushPendingWrites();
    await settle();
    expect(s.store.loggedMeals.map((m) => m.id), contains('m-geist'));

    s.server.poisonMealWrites = false;
    s.store.removeLoggedMeal('m-geist');
    await settle();
    s.store.flushPendingWrites();
    await settle();

    expect(s.store.loggedMeals, isEmpty);
    expect(s.server.mealRows.keys, isNot(contains('m-geist')));
    expect(s.store.pendingOutbox, isEmpty);
  });

  test(
      'L2: verlorener Write UND verlorene Loeschung im selben Replay — beide '
      'Meldungen kommen, die Loeschung wird nicht verschluckt', () async {
    final kv = InMemoryKeyValueStore();
    await seedRawOutbox(kv, [
      SyncOp.mealDelete('m-geist').toJson()
        ..['queued_at'] = DateTime.now()
            .subtract(kOutboxDeleteMinAge + const Duration(hours: 1))
            .toIso8601String()
        ..['attempts'] = kOutboxDeleteMaxAttempts - 1,
    ]);
    final s = setup(kv: kv);
    s.server.offline = true;
    await boot(s.store);

    // Server poisoned: the fresh write dies as poison, the old delete on age.
    s.server.offline = false;
    s.server.mealRows['m-geist'] = serverMealRow('m-geist', kcal: 1800);
    s.server.poisonMealWrites = true;
    s.store.addResultToDailyTotal(mealResult('Gift-Bowl'));
    await settle();
    s.store.flushPendingWrites();
    await settle();

    // The episode latch must not swallow the second, DIFFERENT message.
    expect(s.snacks.messages.where((m) => m == outboxLossHint()), hasLength(1));
    expect(s.snacks.messages.where((m) => m == outboxDeleteLossHint()),
        hasLength(1));
    expect(s.store.loggedMeals.map((m) => m.id), contains('m-geist'));
  });
}
