import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/sync_outbox.dart';
import 'outbox_test_helpers.dart';

const _uid = 'user-outbox';
String _key(String slot) => 'eatova.v1.$slot.$_uid';

class _FaultStore extends InMemoryKeyValueStore {
  String? unreadable;
  bool failWrite = false;
  final queueLengths = <int>[];
  @override
  Future<KeyValueSnapshot> readSnapshot(Iterable<String> keys) async {
    if (keys.contains(unreadable)) throw StateError('Injected snapshot failure');
    return super.readSnapshot(keys);
  }
  @override
  Future<KeyValueCommit> writeBatch(Map<String, String?> changes,
      {Map<String, int> expectedVersions = const {}}) async {
    if (failWrite && changes.isNotEmpty) throw StateError('Injected commit failure');
    final commit = await super.writeBatch(changes, expectedVersions: expectedVersions);
    final queue = changes[_key('outbox')];
    if (queue != null) queueLengths.add(((jsonDecode(queue) as Map)['items'] as List).length);
    return commit;
  }
}

List<SyncOp> _fullQueue(int count) => List.generate(count, (_) => SyncOp.mealDelete('retained'));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Kaltstart ohne Netz sieht bestaetigte Mahlzeit ohne separaten Flush', () async {
    final kv = _FaultStore();
    final a = setup(kv: kv);
    await bootUntilIdle(a.store);
    final id = await a.store.addResultToDailyTotal(mealResult('Gespeichert'));
    final b = setup(kv: kv)..server.offline = true;
    await bootUntilIdle(b.store);
    expect(b.store.loggedMeals.single.id, id);
    expect(b.store.dailyConsumedKcal, 300);
  });

  test('Boot replay und Serverrefresh erhalten alte und neue Mahlzeit', () async {
    final kv = _FaultStore();
    final a = setup(kv: kv);
    await bootUntilIdle(a.store);
    a.server.offline = true;
    final id = await a.store.addResultToDailyTotal(mealResult('Offline'));
    final b = setup(kv: kv);
    b.server.mealRows['remote'] = serverMealRow('remote');
    await bootUntilIdle(b.store);
    expect(b.store.loggedMeals.map((m) => m.id), containsAll([id, 'remote']));
    expect(b.server.mealRows.keys, containsAll([id, 'remote']));
    expect(b.store.pendingOutbox, isEmpty);
  });

  test('Profil-Snapshotfehler verbirgt weder Outbox noch unabhaengige Saves', () async {
    final kv = _FaultStore();
    final seed = LocalCache(kv, _uid);
    await seed.commitSyncOperations([SyncOp.mealInsert(LoggedMeal(id: 'old',
      result: mealResult('Alt'), loggedAt: clock.now()), trackDay: false)]);
    kv.unreadable = _key('profile');
    final a = setup(kv: kv)..server.offline = true;
    await bootUntilIdle(a.store);
    final id = await a.store.addResultToDailyTotal(mealResult('Neu'));
    expect((await seed.readSyncOperations()).map((op) => op.entityId), containsAll(['old', id]));
  });

  test('Outbox-Snapshotfehler bleibt lesegeschuetzt bis sichere Erholung', () async {
    final kv = _FaultStore();
    final seed = LocalCache(kv, _uid);
    await seed.commitSyncOperations([SyncOp.mealInsert(LoggedMeal(id: 'old',
      result: mealResult('Alt'), loggedAt: clock.now()), trackDay: false)]);
    final before = kv.snapshot[_key('outbox')];
    kv.unreadable = _key('outbox');
    final a = setup(kv: kv)..server.offline = true;
    await bootUntilIdle(a.store);
    await expectLater(a.store.addResultToDailyTotal(mealResult('Abgelehnt')), throwsStateError);
    expect(kv.snapshot[_key('outbox')], before);
    kv.unreadable = null;
    final id = await a.store.addResultToDailyTotal(mealResult('Neu'));
    expect((await seed.readSyncOperations()).map((op) => op.entityId), containsAll(['old', id]));
  });

  test('jede einzelne Zustellung bestaetigt ihren eigenen atomaren Queue-Ack', () async {
    final kv = _FaultStore();
    await LocalCache(kv, _uid).commitSyncOperations([
      SyncOp.mealDelete('one'), SyncOp.mealDelete('two'), SyncOp.mealDelete('three'),
    ]);
    kv.queueLengths.clear();
    final a = setup(kv: kv);
    await bootUntilIdle(a.store);
    expect(a.store.pendingOutbox, isEmpty);
    expect(kv.queueLengths, containsAllInOrder([2, 1, 0]));
  });

  test('aktive Ablehnungen behalten Versuchszahl und UUID ueber Neustart', () async {
    final kv = _FaultStore();
    final a = setup(kv: kv);
    await bootUntilIdle(a.store);
    a.server.rejectMealWrites = true;
    final id = await a.store.addResultToDailyTotal(mealResult('Ablehnung'));
    await a.store.syncPendingWrites();
    final old = a.store.pendingOutbox.singleWhere((op) => op.entityId == id);
    final b = setup(kv: kv)..server.rejectMealWrites = true;
    await bootUntilIdle(b.store);
    final next = b.store.pendingOutbox.singleWhere((op) => op.entityId == id);
    expect(next.operationId, old.operationId);
    expect(next.attempts, greaterThan(old.attempts));
  });

  test('volle Queue verweigert gesamten neuen Save und behaelt den aeltesten', () async {
    final kv = _FaultStore();
    final original = _fullQueue(kOutboxMaxOps);
    await LocalCache(kv, _uid).commitSyncOperations(original);
    final a = setup(kv: kv)..server.offline = true;
    await bootUntilIdle(a.store);
    await expectLater(a.store.addResultToDailyTotal(mealResult('Nicht gespeichert')), throwsStateError);
    expect(a.store.loggedMeals, isEmpty);
    expect((await a.cache.readSyncOperations()).map((op) => op.operationId),
        original.map((op) => op.operationId));
  });

  test('legacy Queue oberhalb des Limits wird beim Boot niemals gekappt', () async {
    final kv = _FaultStore();
    final original = _fullQueue(kOutboxMaxOps + 100);
    await LocalCache(kv, _uid).writeOutbox(original);
    final a = setup(kv: kv)..server.offline = true;
    await bootUntilIdle(a.store);
    expect(a.store.pendingOutbox.map((op) => op.operationId), original.map((op) => op.operationId));
  });

  test('gemischte uebergrosse Queue behaelt Saves und Deletes vollstaendig', () async {
    final kv = _FaultStore();
    final first = SyncOp.mealInsert(LoggedMeal(id: 'first', result: mealResult('Alt'),
        loggedAt: clock.now()), trackDay: false);
    final original = [first, ..._fullQueue(kOutboxMaxOps + 2)];
    await LocalCache(kv, _uid).writeOutbox(original);
    final a = setup(kv: kv)..server.offline = true;
    await bootUntilIdle(a.store);
    expect(a.store.pendingOutbox.map((op) => op.operationId), original.map((op) => op.operationId));
    expect(a.store.loggedMeals.map((m) => m.id), contains('first'));
  });

  test('voller Cache kann auch eine Korrektur nicht faelschlich bestaetigen', () async {
    final kv = _FaultStore();
    final meal = LoggedMeal(id: 'retained', result: mealResult('Alt'), loggedAt: clock.now());
    final cache = LocalCache(kv, _uid);
    await cache.writeLoggedMeals([meal]);
    await cache.writeOutbox(List.generate(kOutboxMaxOps, (_) => SyncOp.mealUpsert(meal)));
    final a = setup(kv: kv)..server.offline = true;
    await bootUntilIdle(a.store);
    await expectLater(a.store.updateLoggedMealResult('retained', mealResult('Neu', kcal: 600)), throwsStateError);
    expect(a.store.loggedMeals.single.result.caloriesKcal, 300);
    expect((await cache.readLoggedMeals())!.single.result.caloriesKcal, 300);
  });

  test('Nachhydration einer vollen Queue behaelt jeden alten Intent', () async {
    final kv = _FaultStore();
    final original = _fullQueue(kOutboxMaxOps);
    await LocalCache(kv, _uid).writeOutbox(original);
    kv.unreadable = _key('outbox');
    final a = setup(kv: kv)..server.offline = true;
    await bootUntilIdle(a.store);
    kv.unreadable = null;
    await expectLater(a.store.addResultToDailyTotal(mealResult('Zu viel')), throwsStateError);
    expect((await a.cache.readSyncOperations()).map((op) => op.operationId), original.map((op) => op.operationId));
  });

  test('Logout bewahrt bestaetigte Queue und entfernt persoenliche Mirrors', () async {
    final a = setup();
    await a.cache.writeProfile(const UserProfile(weightKg: 80, onboardingCompleted: true));
    await bootUntilIdle(a.store);
    a.server.offline = true;
    final id = await a.store.addResultToDailyTotal(mealResult('Offline'));
    await a.store.signOutCleanup();
    expect((await a.cache.readOutbox())!.map((op) => op.entityId), contains(id));
    expect(await a.cache.readProfile(), isNull);
    expect(await a.cache.readLoggedMeals(), isNull);
    expect(await a.cache.readFavorites(), isNull);
    expect(await a.cache.readWeightLog(), isNull);
  });

  test('Logout vor Hydration bewahrt die unbekannte Vorsessionqueue', () async {
    final kv = _FaultStore();
    final original = SyncOp.mealDelete('old');
    await LocalCache(kv, _uid).writeOutbox([original]);
    final a = setup(kv: kv);
    await a.store.signOutCleanup();
    expect((await a.cache.readOutbox())!.single.operationId, original.operationId);
  });

  test('Logout startet keine neue Uebertragung nach dem Sessionende', () async {
    final a = setup();
    await bootUntilIdle(a.store);
    a.server.offline = true;
    final id = await a.store.addResultToDailyTotal(mealResult('Offline'));
    a.server.offline = false;
    final before = a.server.operations('mealInsert').length;
    await a.store.signOutCleanup();
    expect(a.server.operations('mealInsert'), hasLength(before));
    expect((await a.cache.readOutbox())!.map((op) => op.entityId), contains(id));
  });

  test('Legacy Stats bleiben bei Logout vor der Migration erhalten', () async {
    final a = setup();
    await a.cache.writePendingStatsDeltas(meals: 3, weightLogs: 1,
      requestId: '40000000-0000-4000-8000-000000000004');
    await a.store.signOutCleanup();
    expect((await a.cache.readPendingStatsDeltasOrThrow())!.meals, 3);
    expect((await a.cache.readPendingStatsDeltasOrThrow())!.weightLogs, 1);
  });

  test('migrierte Stats ueberleben Logout und werden beim naechsten Login einmal geliefert', () async {
    final kv = _FaultStore();
    final a = setup(kv: kv);
    await a.cache.writePendingStatsDeltas(meals: 3, weightLogs: 1,
      requestId: '40000000-0000-4000-8000-000000000004');
    a.server.offline = true;
    await bootUntilIdle(a.store);
    final id = a.store.pendingOutbox.single.operationId;
    await a.store.signOutCleanup();
    final b = setup(kv: kv);
    await bootUntilIdle(b.store);
    expect(b.server.mealsCounted, 3);
    expect(b.server.weightLogsCounted, 1);
    expect(b.server.operations('statsIncrement').single.body, contains(id));
    expect(b.store.pendingOutbox, isEmpty);
  });
  test(
    'Inventur: jede Nutzer-Sammlung haelt ihren Offline-Stand in ZWEI '
    'unabhaengigen Netzen — eigener Cache-Slot UND persistierte Outbox-Op',
    () async {
      final kv = InMemoryKeyValueStore();
      final a = setup(kv: kv);
      a.server.profileRow = serverProfileRow(testProfile(weightKg: 80));
      await boot(a.store);

      a.server.offline = true;
      final mealId = await a.store.addResultToDailyTotal(
        mealResult('Inventur-Bowl'),
      );
      await a.store.toggleFavorite(mealResult('Inventur-Bowl'));
      await a.store.logWeight(79.4);
      await a.store.createUserRecipe(userRecipe('user_inventur'));
      await a.store.applySettings(
        newProfile: a.store.profile.copyWith(
          dailyKcalGoal: 1750,
          manualEnergy: true,
        ),
        notificationsEnabled: false,
      );
      await settle();
      a.store.flushPendingWrites(); // app shutdown
      await settle();

      // Net 1, the cache slots, each checked separately.
      expect(
        (await a.cache.readLoggedMeals())!.map((m) => m.id),
        contains(mealId),
      );
      expect(
        (await a.cache.readFavorites())!.where((f) => f.pinned),
        isNotEmpty,
      );
      expect((await a.cache.readWeightLog())!.latest!.weightKg, 79.4);
      expect(
        (await a.cache.readUserRecipes())!.map((r) => r.slug),
        contains('user_inventur'),
      );
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
        reason:
            'faellt eine Familie hier weg, haengt diese Sammlung wieder '
            'allein am Cache — und ein Kaltstart MIT Netz wuerde sie mit dem '
            'Server-Stand ueberschreiben',
      );

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
      expect(
        c.store.pendingOutbox,
        isEmpty,
        reason: 'und alles ist zugestellt, nicht nur lokal ueberlebt',
      );
      expect(c.server.mealRows.keys, contains(mealId));
      expect(c.server.recipeRows.keys, contains('user_inventur'));
      expect(c.server.weightRows, isNotEmpty);
      expect(c.server.profileRow!['daily_kcal_goal'], 1750);
    },
  );
}
