import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/sync_error_messages.dart'
    show outboxDeleteLossHint, outboxLossHint;
import 'package:eatova/src/services/sync_outbox.dart';

import 'outbox_test_helpers.dart';

// What has to survive a cold start: the cache slots, the persisted outbox blob
// and its attempt counters, the queue cap, and the logout that keeps the
// outbox while dropping the rest of the PII cache.

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Kaltstart OHNE Netz: Tagebuch kommt aus dem Cache', () async {
    final kv = InMemoryKeyValueStore();

    final a = setup(kv: kv);
    await boot(a.store);
    a.store.addResultToDailyTotal(mealResult('Gestern-online-Bowl'));
    await settle();
    // App shutdown flushes the 400 ms debounced diary writes; without it the
    // test would only prove the debounce is short.
    a.store.flushPendingWrites();
    await settle();

    final b = setup(kv: kv);
    b.server.offline = true;
    await boot(b.store);

    expect(b.store.loggedMeals, hasLength(1));
    expect(b.store.loggedMeals.single.result.mealName, 'Gestern-online-Bowl');
    expect(b.store.dailyConsumedKcal, 300);
  });

  test(
      'Boot-Merge: Outbox-Eintrag ueberlebt den Server-Refresh und wird '
      'beim Boot nachgespielt', () async {
    final kv = InMemoryKeyValueStore();

    final a = setup(kv: kv);
    await boot(a.store);
    a.server.offline = true;
    final id = a.store.addResultToDailyTotal(mealResult('Offline-Bowl'));
    await settle();
    expect((await a.cache.readOutbox())!, isNotEmpty);

    // Session 2: server knows a DIFFERENT meal; replay-then-load keeps both.
    final b = setup(kv: kv);
    b.server.mealRows['srv-1'] = serverMealRow('srv-1');
    await boot(b.store);

    expect(b.store.loggedMeals.map((m) => m.id), containsAll([id, 'srv-1']));
    expect(b.server.mealRows.keys, containsAll([id, 'srv-1']));
    expect(
      b.store.pendingOutbox.where((o) => o.entityKey == 'meal:$id'),
      isEmpty,
      reason: 'der Boot-Replay hat die Op abgearbeitet',
    );
  });

  // --- Gap F: one read error no longer topples the whole outbox -------------
  //
  // All seven boot-hydration reads sat in ONE try. An earlier throw left
  // `_outbox` empty and the next enqueue overwrote the blob.

  test(
      'Luecke F: ein Lesefehler im Profil-Slot laesst die Outbox unangetastet',
      () async {
    final kv = InMemoryKeyValueStore();
    final a = setup(kv: kv);
    await boot(a.store);
    a.server.offline = true;
    final id = a.store.addResultToDailyTotal(mealResult('Offline-Bowl'));
    await settle();
    expect((await a.cache.readOutbox())!.map((o) => o.entityKey),
        contains('meal:$id'),
        reason: 'Vorbedingung: der Blob traegt den nicht zugestellten Write');

    final b = setup(
      injizierterCache: ProfilLesefehlerCache(kv, 'user-outbox'),
    );
    b.server.offline = true;
    await boot(b.store);

    expect(b.store.pendingOutbox.map((o) => o.entityKey), contains('meal:$id'),
        reason: 'der Wurf im Profil-Slot uebersprang frueher jeden weiteren '
            'Read — auch den der Outbox');

    // Why that was expensive: the next write persists the queue over the blob.
    final zweite = b.store.addResultToDailyTotal(mealResult('Zweite-Bowl'));
    await settle();
    final blob = await b.cache.readOutbox();
    expect(blob!.map((o) => o.entityKey), containsAll(<String>[
      'meal:$id',
      'meal:$zweite',
    ]));
  });

  test(
      'Luecke F: ein Lesefehler im Outbox-Slot selbst ueberschreibt den Blob '
      'nicht — der naechste Schreibversuch holt ihn nach', () async {
    final kv = InMemoryKeyValueStore();
    final a = setup(kv: kv);
    await boot(a.store);
    a.server.offline = true;
    final id = a.store.addResultToDailyTotal(mealResult('Alt-Bowl'));
    await settle();

    final kaputt = OutboxLesefehlerCache(kv, 'user-outbox');
    final b = setup(injizierterCache: kaputt);
    b.server.offline = true;
    await boot(b.store);
    expect(b.store.pendingOutbox, isEmpty,
        reason: 'Vorbedingung: die Hydration konnte den Blob nicht lesen');

    final neue = b.store.addResultToDailyTotal(mealResult('Neu-Bowl'));
    await settle();

    final blob = await b.cache.readOutbox();
    expect(blob!.map((o) => o.entityKey), containsAll(<String>[
      'meal:$id',
      'meal:$neue',
    ]), reason: 'ein fehlgeschlagener Lesevorgang darf NIE die Grundlage '
        'eines Ueberschreibens sein');
    // The replayed write is visible again, not stuck as an invisible op.
    expect(b.store.loggedMeals.map((m) => m.id), contains(id));
  });

  test(
      'DATA-7: der Replay persistiert nach JEDER Op, nicht einmal am Ende — '
      'ein Kill mitten im Durchlauf darf keine zugestellte Op zurueckbringen',
      () async {
    final kv = InMemoryKeyValueStore();
    // Three deliverable ops of drei verschiedenen Entitaeten: keine blockiert
    // die andere, keine hat eine Payload, keine erzeugt einen Zaehler-
    // Folgeeintrag. Uebrig bleibt reine Kadenz.
    await seedRawOutbox(kv, <Map<String, dynamic>>[
      SyncOp.mealDelete('m-1').toJson(),
      SyncOp.mealDelete('m-2').toJson(),
      SyncOp.mealDelete('m-3').toJson(),
    ]);

    final mitschrift = OutboxSchreibMitschrift(kv, 'user-outbox');
    final s = setup(kv: kv, injizierterCache: mitschrift);
    await boot(s.store);
    await pumpUntil(() => s.store.pendingOutbox.isEmpty);

    expect(s.store.pendingOutbox, isEmpty,
        reason: 'Vorbedingung: der Boot-Replay hat alle drei zugestellt');
    // Der Kern: nach jeder einzelnen Zustellung liegt der VERKUERZTE Stand auf
    // der Platte. Wer die vier Schreibvorgaenge des Passes zu einem am Ende
    // zusammenfasst, kommt hier nur mit [3, 0] oder [0] an — und ein Kill nach
    // der zweiten Zustellung spielte beim naechsten Start alle drei erneut.
    expect(mitschrift.laengen, containsAllInOrder(<int>[2, 1, 0]),
        reason: 'die Zwischenstaende fehlen: die Kadenz ist auf einen Schreib'
            'vorgang pro Durchlauf gebuendelt worden');
  });

  // --- Attempt counter and queue cap across a restart -----------------------

  test('attempts ueberleben den App-Neustart (sonst waere Gift unsterblich)',
      () async {
    final kv = InMemoryKeyValueStore();

    // Session 1: two replays against a 500 -> the counter is at 2.
    final a = setup(kv: kv);
    await boot(a.store);
    a.server.rejectMealWrites = true;
    final id = a.store.addResultToDailyTotal(mealResult('Zaeh-Bowl'));
    await settle();
    for (var i = 0; i < 2; i++) {
      a.store.flushPendingWrites();
      await settle();
    }
    expect(
        a.store.pendingOutbox
            .singleWhere((o) => o.entityKey == 'meal:$id')
            .attempts,
        2);
    expect(
        (await a.cache.readOutbox())!
            .singleWhere((o) => o.entityKey == 'meal:$id')
            .attempts,
        2,
        reason: 'der Zaehler muss PERSISTIERT sein');

    // Session 2 (restart): the replay CONTINUES the count, else a crash loop
    // makes poison immortal.
    final b = setup(kv: kv);
    b.server.rejectMealWrites = true;
    await boot(b.store);

    expect(
        b.store.pendingOutbox
            .singleWhere((o) => o.entityKey == 'meal:$id')
            .attempts,
        3);
  });

  test(
      'Queue-Cap: eine Offline-Flut sprengt die persistierte Outbox nicht — '
      'das Neueste bleibt, das Aelteste faellt raus', () async {
    final s = setup();
    await boot(s.store);
    s.server.offline = true;

    final ids = <String>[];
    for (var i = 0; i < kOutboxMaxOps + 5; i++) {
      ids.add(s.store.addResultToDailyTotal(mealResult('Bowl')));
    }
    await pumpEventQueue(times: 200);

    expect(s.store.pendingOutbox.length, lessThanOrEqualTo(kOutboxMaxOps));
    final keys = s.store.pendingOutbox.map((o) => o.entityKey).toSet();
    expect(keys, contains('meal:${ids.last}'),
        reason: 'worauf der User gerade schaut, bleibt');
    expect(keys, isNot(contains('meal:${ids.first}')),
        reason: 'die aelteste Op ist die wahrscheinlichste Leiche');

    final persisted = await s.cache.readOutbox();
    expect(persisted!.length, lessThanOrEqualTo(kOutboxMaxOps));

    expect(s.snacks.messages.where((m) => m == outboxLossHint()), hasLength(1));
  }, timeout: const Timeout(Duration(minutes: 3)));

  test(
      'Hydrations-Cap: eine von einem alten, ungedeckelten Build gewachsene '
      'Queue wird beim Boot gekappt', () async {
    final kv = InMemoryKeyValueStore();
    // Written straight into the cache: no enqueue, yet the cap must bite.
    final seed = LocalCache(kv, 'user-outbox');
    // WRITE ops on purpose: deletes are cap-exempt (a dropped one resurrects).
    await seed.writeOutbox(<SyncOp>[
      for (var i = 0; i < kOutboxMaxOps + 100; i++)
        SyncOp.weightInsert(
          id: 'legacy-$i',
          weightKg: 80,
          recordedAt: DateTime(2026, 8, 1).add(Duration(minutes: i)),
        ),
    ]);

    final s = setup(kv: kv);
    // Offline, else the boot replay empties the queue and the test is vacuous.
    s.server.offline = true;
    await boot(s.store);

    expect(s.store.pendingOutbox, hasLength(kOutboxMaxOps));
    expect(s.store.pendingOutbox.map((o) => o.entityId),
        isNot(contains('legacy-0')));
    expect(s.store.pendingOutbox.last.entityId,
        'legacy-${kOutboxMaxOps + 99}');
  }, timeout: const Timeout(Duration(minutes: 3)));

  test(
      'Misch-Drop am Cap: faellt neben Deletes auch ein Write, meldet die '
      'Episode BEIDE Verluste — nicht nur die Loeschung', () async {
    final kv = InMemoryKeyValueStore();
    final meal = LoggedMeal(
      id: 'm-write-verlust',
      result: mealResult('Cap-Bowl'),
      loggedAt: DateTime.now(),
    );
    await seedRawOutbox(kv, [
      // Oldest entry is a WRITE, so it falls to the cap first.
      SyncOp.mealInsert(meal, trackDay: false).toJson(),
      // Then enough deletes that the overflow takes two after the one write.
      for (var i = 0; i < 502; i++) SyncOp.mealDelete('m-del-$i').toJson(),
    ]);

    final s = setup(kv: kv);
    s.server.offline = true;
    await boot(s.store);

    expect(s.store.pendingOutbox, hasLength(kOutboxMaxOps));
    expect(s.snacks.messages.where((m) => m == outboxDeleteLossHint()),
        hasLength(1),
        reason: 'zwei Deletes sind gefallen — ihre Eintraege kommen wieder');
    expect(s.snacks.messages.where((m) => m == outboxLossHint()), hasLength(1),
        reason: 'der Write ist gefallen und FEHLT damit — diese Meldung '
            'verschluckte der gemeinsame Aufruf mit deletesLost==true');
  });

  test(
      'P1-01/A6: was der Queue-Cap verwirft, macht die Entitaet zur Waise — '
      'die spaetere Korrektur erreicht den Server wirklich', () async {
    final kv = InMemoryKeyValueStore();
    final gekappt = LoggedMeal(
      id: 'm-gekappt',
      result: mealResult('Cap-Bowl'),
      loggedAt: DateTime.now(),
    );
    // Genau am Limit, und der aelteste Eintrag ist der einzige WRITE: die
    // naechste Op schiebt exakt ihn ueber die Kante.
    await seedRawOutbox(kv, [
      SyncOp.mealInsert(gekappt, trackDay: false).toJson(),
      for (var i = 0; i < kOutboxMaxOps - 1; i++)
        SyncOp.mealDelete('m-fuell-$i').toJson(),
    ]);

    final s = setup(kv: kv);
    s.server.offline = true;
    await boot(s.store);
    expect(s.store.pendingOutbox, hasLength(kOutboxMaxOps),
        reason: 'Vorbedingung: die Queue steht genau am Limit');
    expect(s.store.loggedMeals.map((m) => m.id), contains('m-gekappt'));

    // Ein weiterer Offline-Write: der Cap wirft den aeltesten Write raus.
    s.store.addResultToDailyTotal(mealResult('Neu-Bowl'));
    await pumpEventQueue(times: 200);
    expect(s.store.pendingOutbox.where((o) => o.entityKey == 'meal:m-gekappt'),
        isEmpty,
        reason: 'Vorbedingung: die Insert-Op ist am Cap gefallen');
    expect(s.snacks.messages.where((m) => m == outboxLossHint()), hasLength(1));
    expect(s.store.loggedMeals.map((m) => m.id), contains('m-gekappt'),
        reason: 'lokal steht die Mahlzeit weiter im Tagebuch');

    // Netz zurueck: der Rest der Queue laeuft durch — nur m-gekappt fehlt
    // serverseitig, weil seine Op nie zugestellt wurde.
    s.server.offline = false;
    s.store.flushPendingWrites();
    await pumpEventQueue(times: 400);
    expect(s.server.mealRows.keys, isNot(contains('m-gekappt')));
    expect(s.store.pendingOutbox.where((o) => o.entityKey == 'meal:m-gekappt'),
        isEmpty);

    // Der User korrigiert genau diese Mahlzeit.
    s.store
        .updateLoggedMealResult('m-gekappt', mealResult('Cap-Bowl', kcal: 500));
    await settle();
    expect(
      s.server.requests.where(
          (r) => r.method == 'PATCH' && r.url.path.contains('/logged_meals')),
      isEmpty,
      reason: 'ein PATCH auf 0 Zeilen ist ein 204 — die "Reparatur" meldete '
          'Erfolg und reparierte nichts',
    );

    s.store.flushPendingWrites();
    await pumpEventQueue(times: 200);
    expect(s.server.mealRows.keys, contains('m-gekappt'),
        reason: 'der Upsert-Weg legt die verworfene Zeile wirklich an');
    expect(s.server.mealRows['m-gekappt']!['calories_kcal'], 500);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test(
      'P1-01/A6: dieselbe Marke setzt der Cap der Nachhydration — dort raeumt '
      'kein Boot-Load mehr hinterher', () async {
    final kv = InMemoryKeyValueStore();
    final gekappt = LoggedMeal(
      id: 'm-nachhydriert',
      result: mealResult('Merge-Bowl'),
      loggedAt: DateTime.now(),
    );
    await seedRawOutbox(kv, [
      SyncOp.mealInsert(gekappt, trackDay: false).toJson(),
      for (var i = 0; i < kOutboxMaxOps - 1; i++)
        SyncOp.mealDelete('m-fuell-$i').toJson(),
    ]);
    // Das Tagebuch kennt die Mahlzeit aus dem Cache — die Nachhydration selbst
    // spielt sie nicht mehr ein, ihre Op faellt ja gerade dem Cap zum Opfer.
    await LocalCache(kv, 'user-outbox').writeLoggedMeals(<LoggedMeal>[gekappt]);

    // Erster Outbox-Read wirft: die Hydration adoptiert nichts, der erste
    // Schreibversuch holt den Blob nach und merged ihn (kOutboxMaxOps + 1).
    final s = setup(injizierterCache: OutboxLesefehlerCache(kv, 'user-outbox'));
    s.server.offline = true;
    await boot(s.store);
    expect(s.store.pendingOutbox, isEmpty,
        reason: 'Vorbedingung: die Hydration konnte den Blob nicht lesen');

    s.store.addResultToDailyTotal(mealResult('Neu-Bowl'));
    await pumpEventQueue(times: 200);
    expect(s.store.pendingOutbox, hasLength(kOutboxMaxOps),
        reason: 'Vorbedingung: der nachgeholte Blob ist da und gekappt');
    expect(
        s.store.pendingOutbox.where((o) => o.entityKey == 'meal:m-nachhydriert'),
        isEmpty,
        reason: 'Vorbedingung: die aelteste Insert-Op ist am Cap gefallen');

    s.server.offline = false;
    s.store.flushPendingWrites();
    await pumpEventQueue(times: 400);
    expect(s.server.mealRows.keys, isNot(contains('m-nachhydriert')));

    s.store.updateLoggedMealResult(
        'm-nachhydriert', mealResult('Merge-Bowl', kcal: 500));
    await settle();
    expect(
      s.server.requests.where(
          (r) => r.method == 'PATCH' && r.url.path.contains('/logged_meals')),
      isEmpty,
      reason: 'auch hier gilt: ein PATCH auf 0 Zeilen ist ein stiller Verlust',
    );

    s.store.flushPendingWrites();
    await pumpEventQueue(times: 200);
    expect(s.server.mealRows['m-nachhydriert']?['calories_kcal'], 500);
  }, timeout: const Timeout(Duration(minutes: 3)));

  // --- A2/L3: the logout keeps the outbox and the pending deltas ------------

  test(
      'A2: Ausloggen mit ungesyncten Ops — was der Zustellversuch nicht '
      'losgeworden ist, ueberlebt den Logout', () async {
    final s = setup();
    // Real PII before the boot: the A1 guard writes no default snapshot.
    await s.cache.writeProfile(
        const UserProfile(weightKg: 80, onboardingCompleted: true));
    await boot(s.store);
    s.server.offline = true;

    final id = s.store.addResultToDailyTotal(mealResult('Flugzeug-Bowl'));
    await settle();
    expect((await s.cache.readOutbox())!, isNotEmpty);
    expect(await s.cache.readProfile(), isNotNull);

    await s.store.signOutCleanup();

    // The six offline meals are NOT gone …
    final surviving = await s.cache.readOutbox();
    expect(surviving, isNotNull);
    expect(surviving!.map((o) => o.entityKey), contains('meal:$id'));
    // … while the rest of the PII cache is (audit M-1 still holds).
    expect(await s.cache.readProfile(), isNull);
    expect(await s.cache.readLoggedMeals(), isNull);
    expect(await s.cache.readWeightLog(), isNull);
    expect(await s.cache.readFavorites(), isNull);
  });

  test(
      'A2-Restfenster: Logout VOR der Boot-Hydration raeumt die persistierte '
      'Outbox der Vorsession nicht', () async {
    final kv = InMemoryKeyValueStore();
    final meal = LoggedMeal(
      id: 'm-vorsession',
      result: mealResult('Vorsession-Bowl'),
      loggedAt: DateTime.now(),
    );
    await seedRawOutbox(kv, [SyncOp.mealInsert(meal, trackDay: false).toJson()]);

    final s = setup(kv: kv);
    // Deliberately no boot: `_outbox` is empty, the persisted blob is not.
    await s.store.signOutCleanup();

    final surviving = await s.cache.readOutbox();
    expect(surviving, isNotNull,
        reason: 'ein leerer In-Memory-Zustand vor der Hydration ist KEINE '
            'Aussage ueber den persistierten Blob — er darf nicht als '
            '"nichts zu erhalten" gelesen werden');
    expect(surviving!.map((o) => o.entityKey), contains('meal:m-vorsession'));
  });

  test(
      'A2: Ausloggen online — der Zustellversuch raeumt die Queue leer, danach '
      'faellt auch die Outbox', () async {
    final s = setup();
    await boot(s.store);
    s.server.offline = true;
    final id = s.store.addResultToDailyTotal(mealResult('Landung-Bowl'));
    await settle();

    s.server.offline = false;
    await s.store.signOutCleanup();

    expect(s.server.mealRows.keys, contains(id),
        reason: 'Zustellversuch VOR dem Verwerfen');
    expect(await s.cache.readOutbox(), isNull);
    expect(await s.cache.readProfile(), isNull);
  });

  test(
      'L3: Ausloggen mit LEERER Outbox, aber pendenden Stats-Deltas — die '
      'Lebenszeit-Zaehler ueberleben den Logout', () async {
    final s = setup();
    await boot(s.store);
    // Only increment_lifetime_stats fails; the outbox stays EMPTY.
    s.server.statsOffline = true;
    s.store.addResultToDailyTotal(mealResult('Streak-Bowl'));
    await settle();
    s.store.flushPendingWrites();
    await settle();

    expect(s.store.pendingOutbox, isEmpty,
        reason: 'genau die Kombination, die A2 uebersehen hat');
    expect((await s.cache.readPendingStatsDeltas())!.meals, 1);

    await s.store.signOutCleanup();

    // preserveOutbox used to hang on _outbox.length alone, dropping deltas.
    final surviving = await s.cache.readPendingStatsDeltas();
    expect(surviving, isNotNull);
    expect(surviving!.meals, 1);
    // The rest of the PII cache is still dropped (audit M-1).
    expect(await s.cache.readProfile(), isNull);
    expect(await s.cache.readLoggedMeals(), isNull);
  });

  test(
      'L3: Ausloggen online mit pendenden Deltas — der Zustellversuch verbucht '
      'sie, danach faellt der ganze Cache (Audit M-1)', () async {
    final s = setup();
    await boot(s.store);
    s.server.statsOffline = true;
    s.store.addResultToDailyTotal(mealResult('Streak-Bowl'));
    await settle();
    s.store.flushPendingWrites();
    await settle();
    expect((await s.cache.readPendingStatsDeltas())!.meals, 1);

    s.server.statsOffline = false;
    await s.store.signOutCleanup();

    expect(s.server.mealsCounted, 1, reason: 'Zustellversuch VOR dem Verwerfen');
    expect(await s.cache.readPendingStatsDeltas(), isNull);
    expect(await s.cache.readOutbox(), isNull);
    expect(await s.cache.readProfile(), isNull);
  });

  // --- Question 3: is any data kind still down to ONE net? -----------------
  //
  // The inventory in ONE offline session: mutate, kill, restart offline. Every
  // collection must show BOTH nets — its cache slot and the persisted op.

  test(
      'Inventur: jede Nutzer-Sammlung haelt ihren Offline-Stand in ZWEI '
      'unabhaengigen Netzen — eigener Cache-Slot UND persistierte Outbox-Op',
      () async {
    final kv = InMemoryKeyValueStore();
    final a = setup(kv: kv);
    a.server.profileRow = serverProfileRow(testProfile(weightKg: 80));
    await boot(a.store);

    a.server.offline = true;
    final mealId = a.store.addResultToDailyTotal(mealResult('Inventur-Bowl'));
    a.store.toggleFavorite(mealResult('Inventur-Bowl'));
    a.store.logWeight(79.4);
    await a.store.createUserRecipe(userRecipe('user_inventur'));
    await a.store.applySettings(
      newProfile: a.store.profile.copyWith(dailyKcalGoal: 1750, manualEnergy: true),
      notificationsEnabled: false,
    );
    await settle();
    a.store.flushPendingWrites(); // app shutdown
    await settle();

    // Net 1, the cache slots, each checked separately.
    expect(
        (await a.cache.readLoggedMeals())!.map((m) => m.id), contains(mealId));
    expect((await a.cache.readFavorites())!.where((f) => f.pinned), isNotEmpty);
    expect((await a.cache.readWeightLog())!.latest!.weightKg, 79.4);
    expect((await a.cache.readUserRecipes())!.map((r) => r.slug),
        contains('user_inventur'));
    expect((await a.cache.readProfile())!.dailyKcalGoal, 1750);

    final blob = (await a.cache.readOutbox())!.map((o) => o.kind).toSet();
    expect(
        blob,
        containsAll(<SyncOpKind>[
          SyncOpKind.mealInsert,
          SyncOpKind.favoriteUpsert,
          SyncOpKind.weightInsert,
          SyncOpKind.recipeUpsert,
          SyncOpKind.profileUpsert,
        ]),
        reason: 'faellt eine Familie hier weg, haengt diese Sammlung wieder '
            'allein am Cache — und ein Kaltstart MIT Netz wuerde sie mit dem '
            'Server-Stand ueberschreiben');

    final b = setup(kv: kv);
    b.server.offline = true;
    await boot(b.store);
    expect(b.store.loggedMeals.map((m) => m.id), contains(mealId));
    expect(b.store.favorites.where((f) => f.pinned), isNotEmpty);
    expect(b.store.weightLog.latest!.weightKg, 79.4);
    expect(b.store.userRecipes.map((r) => r.slug), contains('user_inventur'));
    expect(b.store.profile.dailyKcalGoal, 1750);

    // Cold start WITH network, empty server: merge + overlay must hold ALL five.
    final c = setup(kv: kv);
    c.server.profileRow = serverProfileRow(testProfile(weightKg: 80));
    await boot(c.store);
    expect(c.store.loggedMeals.map((m) => m.id), contains(mealId));
    expect(c.store.favorites.where((f) => f.pinned), isNotEmpty);
    expect(c.store.weightLog.latest!.weightKg, 79.4);
    expect(c.store.userRecipes.map((r) => r.slug), contains('user_inventur'));
    expect(c.store.profile.dailyKcalGoal, 1750);
    expect(c.store.pendingOutbox, isEmpty,
        reason: 'und alles ist zugestellt, nicht nur lokal ueberlebt');
    expect(c.server.mealRows.keys, contains(mealId));
    expect(c.server.recipeRows.keys, contains('user_inventur'));
    expect(c.server.weightRows, isNotEmpty);
    expect(c.server.profileRow!['daily_kcal_goal'], 1750);
  });
}
