import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/auth_gate.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/sync_outbox.dart';

import 'fixlauf_a_helpers.dart';

// Review 2026-08-27, F1-02: no lifecycle fence around the cache. A debounce
// timer, a running snapshot write or a late live-op callback kept writing PII
// after logout / session loss / account deletion — into slots the purge had
// just cleared (audit M-1).
//
// Pinned here:
//   1. `clear()` closes the instance: every later write is a no-op, the
//      debounce drain included.
//   2. `LocalCache.closeInstancesFor` lets the AuthGate's purge (a SECOND
//      instance) silence the store's own instance first.
//   3. logout during the boot snapshot leaves every PII slot empty.
//   4. `HomeStore.dispose()` discards pending debounced writes, and late
//      live-op callbacks write nothing after dispose.

/// Counts writes per key and can DELAY every setString.
class _ZaehlenderStore implements KeyValueStore {
  _ZaehlenderStore({this.writeDelay = Duration.zero});

  final Duration writeDelay;
  final Map<String, String> _data = {};
  final Map<String, int> writes = {};

  Map<String, String> get snapshot => Map.unmodifiable(_data);
  int writesFuer(String key) => writes[key] ?? 0;
  int get totalWrites => writes.values.fold(0, (a, b) => a + b);

  @override
  Future<String?> getString(String key) async => _data[key];

  @override
  Future<void> setString(String key, String value) async {
    if (writeDelay > Duration.zero) await Future<void>.delayed(writeDelay);
    writes[key] = (writes[key] ?? 0) + 1;
    _data[key] = value;
  }

  @override
  Future<void> remove(String key) async {
    _data.remove(key);
  }
}

LoggedMeal _meal(String id) => LoggedMeal(
      id: id,
      result: mealResult('Bowl'),
      loggedAt: DateTime.now(),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LocalCache: clear() schliesst die Instanz', () {
    test('nach clear() sind alle Write-Pfade No-ops', () async {
      final kv = _ZaehlenderStore();
      final cache = LocalCache(kv, 'u');
      await cache.writeProfile(const UserProfile(weightKg: 90));

      await cache.clear();
      expect(cache.isClosed, isTrue);

      await cache.writeProfile(const UserProfile(weightKg: 91));
      await cache.writeLoggedMeals([_meal('m-1')]);
      cache.writeFavoritesDebounced(const []);
      cache.writeLoggedMealsDebounced([_meal('m-2')]);
      await cache.flush();
      final durable = await cache.writeOutbox([SyncOp.mealDelete('m-1')]);
      await cache.writePendingStatsDeltas(meals: 1, weightLogs: 0);
      await Future<void>.delayed(
          LocalCache.writeDebounce + const Duration(milliseconds: 100));

      expect(kv.snapshot, isEmpty,
          reason: 'eine geschlossene Instanz darf nichts mehr zurueckschreiben');
      expect(durable, isFalse,
          reason: 'der durable Write meldet ehrlich, dass nichts auf Platte '
              'liegt');
      expect(cache.hasPendingWrites, isFalse);
    });

    test('closeInstancesFor schliesst die Store-Instanz desselben Nutzers, '
        'fremde Nutzer bleiben offen', () async {
      final kv = _ZaehlenderStore();
      final a = LocalCache(kv, 'u');
      final fremd = LocalCache(kv, 'anderer');
      a.writeLoggedMealsDebounced([_meal('m-privat')]);
      fremd.writeLoggedMealsDebounced([_meal('m-fremd')]);

      // The AuthGate purge path: a SECOND instance for the same user.
      // Awaited since P3-01 — the call also settles running writes.
      await LocalCache.closeInstancesFor('u');
      await purgePersonalCache(LocalCache(kv, 'u'));
      await Future<void>.delayed(
          LocalCache.writeDebounce + const Duration(milliseconds: 100));

      expect(a.isClosed, isTrue);
      expect(fremd.isClosed, isFalse);
      expect(kv.snapshot.keys, isNot(contains('eatova.v1.logged_meals.u')),
          reason: 'der Debounce der Store-Instanz darf nach der Purge nicht '
              'mehr feuern');
      expect(kv.snapshot.keys, contains('eatova.v1.logged_meals.anderer'));
    });

    test('purgePersonalCacheFor schliesst die Store-Instanz auch dann, wenn '
        'die zweite Instanz nicht gebaut werden kann', () async {
      final kv = _ZaehlenderStore();
      final a = LocalCache(kv, 'u');
      a.writeLoggedMealsDebounced([_meal('m-privat')]);

      // In tests `LocalCache.create` returns null (no plugin channel), so the
      // purge itself cannot run — closing the live instance must not depend
      // on it.
      await purgePersonalCacheFor('u');
      await Future<void>.delayed(
          LocalCache.writeDebounce + const Duration(milliseconds: 100));

      expect(a.isClosed, isTrue);
      expect(kv.snapshot, isEmpty);
    });
  });

  group('HomeStore: Logout waehrend Snapshot/Debounce', () {
    test('signOutCleanup direkt nach dem Boot: jeder PII-Slot bleibt leer, '
        'auch nachdem der laufende Snapshot durch ist', () async {
      // Slow store: the boot snapshot (6 sequential slot writes) is still
      // running when the logout arrives.
      final kv = _ZaehlenderStore(writeDelay: const Duration(milliseconds: 20));
      final cache = LocalCache(kv, kFixlaufUser);
      final s = fixlaufSetup(cache: cache);
      s.server.profileRow = serverProfileRow(completedProfile);
      s.server.mealRows['m1'] = serverMealRow('m1');
      s.store.start();
      await s.store.profileReady;

      await s.store.signOutCleanup();
      // Give every straggler the chance to land.
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await settle();

      for (final key in piiSlotKeys) {
        expect(kv.snapshot.containsKey(key), isFalse,
            reason: '$key darf den Logout nicht ueberleben');
      }
    });

    test('Debounce-Write in der Warteschlange: signOutCleanup laesst ihn '
        'nicht mehr landen', () async {
      final kv = _ZaehlenderStore();
      final cache = LocalCache(kv, kFixlaufUser);
      final s = fixlaufSetup(cache: cache);
      s.server.profileRow = serverProfileRow(completedProfile);
      await bootStore(s.store);

      s.store.addResultToDailyTotal(mealResult('Kurz vor Logout'));
      expect(cache.hasPendingWrites, isTrue, reason: 'Vorbedingung');
      await s.store.signOutCleanup();
      await Future<void>.delayed(
          LocalCache.writeDebounce + const Duration(milliseconds: 100));
      await settle();

      for (final key in piiSlotKeys) {
        expect(kv.snapshot.containsKey(key), isFalse, reason: key);
      }
    });

    test('deleteAccount: ebenfalls keine Nach-Writes', () async {
      final kv = _ZaehlenderStore(writeDelay: const Duration(milliseconds: 20));
      final cache = LocalCache(kv, kFixlaufUser);
      final s = fixlaufSetup(cache: cache);
      s.server.profileRow = serverProfileRow(completedProfile);
      s.store.start();
      await s.store.profileReady;

      expect(await s.store.deleteAccount(), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await settle();

      expect(kv.snapshot, isEmpty,
          reason: 'nach der Kontoloeschung darf gar nichts mehr im Store '
              'liegen — auch nicht der Outbox-Slot');
    });
  });

  group('HomeStore.dispose(): Zaun fuer spaete Writes', () {
    test('dispose verwirft den laufenden Debounce', () async {
      final kv = _ZaehlenderStore();
      final cache = LocalCache(kv, kFixlaufUser);
      final s = fixlaufSetup(cache: cache, autoDispose: false);
      s.server.profileRow = serverProfileRow(completedProfile);
      await bootStore(s.store);
      const mealsKey = 'eatova.v1.logged_meals.$kFixlaufUser';
      final vorher = kv.writesFuer(mealsKey);

      s.store.addResultToDailyTotal(mealResult('Kurz vor Dispose'));
      expect(cache.hasPendingWrites, isTrue, reason: 'Vorbedingung');
      s.store.dispose();
      await Future<void>.delayed(
          LocalCache.writeDebounce + const Duration(milliseconds: 100));
      await settle();

      expect(kv.writesFuer(mealsKey), vorher,
          reason: 'nach dispose darf der Debounce-Timer nicht mehr schreiben');
      expect(cache.hasPendingWrites, isFalse);
      expect(cache.isClosed, isFalse,
          reason: 'dispose schliesst NICHT — die Instanz gehoert der Session, '
              'nicht dem Store');
    });

    test('eine nach dispose zugestellte Live-Op schreibt weder Outbox- noch '
        'Stats-Slot neu', () async {
      final kv = _ZaehlenderStore();
      final cache = LocalCache(kv, kFixlaufUser);
      final s = fixlaufSetup(cache: cache, autoDispose: false);
      s.server.profileRow = serverProfileRow(completedProfile);
      await bootStore(s.store);

      s.server.holdWrites = true;
      s.store.addResultToDailyTotal(mealResult('Spaete Zustellung'));
      await settle();
      expect(s.server.heldWrites, greaterThanOrEqualTo(1), reason: 'Vorbedingung');
      const outboxKey = 'eatova.v1.outbox.$kFixlaufUser';
      const statsKey = 'eatova.v1.pending_stats.$kFixlaufUser';
      final outboxVorher = kv.writesFuer(outboxKey);
      final statsVorher = kv.writesFuer(statsKey);

      s.store.dispose();
      s.server.releaseWrites();
      await settle();
      await Future<void>.delayed(const Duration(milliseconds: 700));
      await settle();

      expect(kv.writesFuer(outboxKey), outboxVorher,
          reason: '_dequeueDeliveredOp/_persistOutbox nach dispose');
      expect(kv.writesFuer(statsKey), statsVorher,
          reason: '_queueStatsDelta nach dispose');
      expect(s.server.requestsTo('/rpc/increment_lifetime_stats'), isEmpty,
          reason: 'kein Stats-Timer mit abgemeldetem Client');
    });
  });

  test('Sanity: die Fixes lassen den regulaeren Boot-Snapshot in Ruhe',
      () async {
    final kv = _ZaehlenderStore();
    final cache = LocalCache(kv, kFixlaufUser);
    final s = fixlaufSetup(cache: cache);
    s.server.profileRow = serverProfileRow(completedProfile);
    await bootStore(s.store);
    expect(kv.snapshot.keys, contains('eatova.v1.profile.$kFixlaufUser'));
    expect(cache.isClosed, isFalse);
  });
}
