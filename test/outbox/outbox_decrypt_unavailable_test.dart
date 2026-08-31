import 'dart:convert';
import 'dart:isolate';

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/api.dart' show InvalidCipherTextException;

import 'package:eatova/src/app/home_store.dart'
    show kOutboxRepairMaxAttempts, kOutboxRepairMinSpacing;
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/secure_cache_store.dart';
import 'package:eatova/src/services/sync_outbox.dart';

import 'outbox_test_helpers.dart';

// Review 2026-08-29, P3-02: the brake against "an empty in-memory queue
// overwrites the filled persisted blob" hangs on `readOutboxOrThrow` throwing
// while the slot is UNREADABLE. Under the production stack it could not.
//
// `EncryptedKeyValueStore.getString` answers a failed EXECUTION of the
// decryption (isolate spawn, OOM, RemoteError) with `null` and LEAVES the slot
// — rightly so, that error says nothing about the ciphertext. But the
// counter-check `_assertSlotEmpty` used to read through the very same
// decorator, got the same `null`, and therefore did not throw: hydration
// counted as "slot empty", the next write overwrote up to 500 undelivered ops,
// and the logout deleted the intact slot (`preserveOutbox` hangs on
// `_syncStateHydrated`).
//
// These tests drive the REAL HomeStore over the REAL encrypting decorator with
// a cipher whose decryption is switched off for the cold start only — the
// transient case, in which `encrypt` (and thus the overwrite) keeps working.

const String _uid = 'user-outbox';
const String _outboxKey = 'eatova.v1.outbox.$_uid';
const String _deltaKey = 'eatova.v1.pending_stats.$_uid';

/// Cipher in the real wire frame whose DECRYPT can be switched off; [salt]
/// stands for the DEK.
///
/// [blockiert] models an execution failure (no isolate, no memory), not a
/// broken ciphertext: `encrypt` stays available, so a following write really
/// can overwrite the intact blob.
class _AussetzenderCipher implements CacheCipher {
  _AussetzenderCipher([this.salt = 'dek-a']);

  final String salt;
  bool blockiert = false;

  @override
  Future<String> encrypt(String key, String plaintext) async =>
      '$cacheCipherMagic'
      '${base64.encode(utf8.encode(jsonEncode([salt, key, plaintext])))}';

  @override
  Future<String> decrypt(String key, String armored) async {
    if (blockiert) throw IsolateSpawnException('kein Speicher');
    final parts = jsonDecode(
      utf8.decode(base64.decode(armored.substring(cacheCipherMagic.length))),
    ) as List<dynamic>;
    // Like the real cipher: a wrong key and a foreign AAD both fail the tag
    // check.
    if (parts[0] != salt || parts[1] != key) {
      throw InvalidCipherTextException('mac check in GCM failed');
    }
    return parts[2] as String;
  }
}

/// An undelivered meal from a previous session, as the persisted outbox holds
/// it.
LoggedMeal _meal(String id) => LoggedMeal(
      id: id,
      result: mealResult('Alt-Bowl'),
      loggedAt: DateTime(2026, 8, 13, 12, 30),
      forcedSlot: MealSlot.lunch,
      localDay: '2026-08-13',
    );

/// Raw store + encrypting decorator, the production stacking.
(InMemoryKeyValueStore, _AussetzenderCipher, EncryptedKeyValueStore)
    _stapel() {
  final raw = InMemoryKeyValueStore();
  final cipher = _AussetzenderCipher();
  return (raw, cipher, EncryptedKeyValueStore(raw, cipher));
}

/// One undelivered op of a previous session in the persisted outbox.
Future<void> _seedOutbox(EncryptedKeyValueStore store) =>
    LocalCache(store, _uid)
        .writeOutbox([SyncOp.mealInsert(_meal('m-alt'), trackDay: false)]);

/// Three never-booked meals in the persisted deltas slot.
Future<void> _seedDeltas(EncryptedKeyValueStore store) =>
    LocalCache(store, _uid).writePendingStatsDeltas(
        meals: 3, weightLogs: 0, requestId: 'rid-alt');

/// A slot in the real wire frame whose PLAINTEXT is unusable: `decrypt`
/// succeeds and hands the bytes over, and the reader still cannot parse them.
///
/// That is [RawSlotState.brokenContent], i.e. `UnreadableCacheSlot.transient ==
/// false` — the opposite of the blocked cipher above, where the bytes were
/// never handed over at all.
Future<void> _seedKaputtenInhalt(
  InMemoryKeyValueStore raw,
  _AussetzenderCipher cipher,
  String key,
) async =>
    raw.setString(key, await cipher.encrypt(key, '{"items": [ kein json'));

/// Counts the RE-READS of the two sync slots.
///
/// The real evidence for P3-02d: every protected write pays one re-read, so
/// the counter says how many attempts the brake spent. Deciding by
/// `transient` there is exactly ONE (the one that fetches the verdict); the
/// slot's takeover alone does not tell the two builds apart, because the
/// bounded brake reaches it too, just three writes later.
class _ZaehlenderCache extends LocalCache {
  _ZaehlenderCache(super.store, super.userId);

  int outboxLeseversuche = 0;
  int deltaLeseversuche = 0;

  @override
  Future<List<SyncOp>?> readOutboxOrThrow() {
    outboxLeseversuche++;
    return super.readOutboxOrThrow();
  }

  @override
  Future<({int meals, int weightLogs, String? requestId})?>
      readPendingStatsDeltasOrThrow() {
    deltaLeseversuche++;
    return super.readPendingStatsDeltasOrThrow();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Outbox-Slot', () {
    test(
        'nicht ausfuehrbare Entschluesselung beim Kaltstart: der naechste '
        'Enqueue ueberschreibt den Blob nicht', () async {
      final (raw, cipher, store) = _stapel();
      await _seedOutbox(store);
      // The whole cold start runs without a usable isolate.
      cipher.blockiert = true;

      final a = setup(injizierterCache: LocalCache(store, _uid));
      a.server.offline = true;
      await boot(a.store);
      expect(a.store.pendingOutbox, isEmpty,
          reason: 'Vorbedingung: die Hydration hat den Blob nicht gesehen');

      // The pressure is over; from here decryption works again.
      cipher.blockiert = false;
      final neu = a.store.addResultToDailyTotal(mealResult('Neu-Bowl'));
      await settle();

      final blob = await LocalCache(store, _uid).readOutbox();
      expect(blob!.map((o) => o.entityId), containsAll(<String>['m-alt', neu]),
          reason: 'ein gescheiterter Isolate-Hop ist keine Aussage ueber den '
              'Slot — er darf nicht als „leer" durchgehen und den nie '
              'zugestellten Write ueberschreiben');
      expect(raw.snapshot.containsKey(_outboxKey), isTrue);
    });

    test('der Logout loescht den ungelesenen Slot NICHT', () async {
      final (raw, cipher, store) = _stapel();
      await _seedOutbox(store);
      cipher.blockiert = true;

      final a = setup(injizierterCache: LocalCache(store, _uid));
      a.server.offline = true;
      await boot(a.store);
      cipher.blockiert = false;

      await a.store.signOutCleanup();

      expect(raw.snapshot.containsKey(_outboxKey), isTrue,
          reason: 'preserveOutbox haengt an _syncStateHydrated: gilt die '
              'ungelesene Hydration als geglueckt, raeumt der Logout bis zu '
              '500 nie zugestellte Writes weg — und remove braucht keine '
              'Chiffre, scheitert also nie');
    });
  });

  group('Pending-Stats-Slot', () {
    test(
        'nicht ausfuehrbare Entschluesselung beim Kaltstart: der naechste '
        'Flush setzt die Deltas nicht auf 0 zurueck', () async {
      final (raw, cipher, store) = _stapel();
      await _seedDeltas(store);
      cipher.blockiert = true;

      final a = setup(injizierterCache: LocalCache(store, _uid));
      await boot(a.store);

      cipher.blockiert = false;
      // The meal write lands, only increment_lifetime_stats fails — the
      // constellation that books a delta and rewrites the slot.
      a.server.statsOffline = true;
      a.store.addResultToDailyTotal(mealResult('Neu-Bowl'));
      await settle();
      a.store.flushPendingWrites();
      await settle();

      final deltas = await LocalCache(store, _uid).readPendingStatsDeltas();
      expect(deltas!.meals, 4,
          reason: 'die drei nie verbuchten Mahlzeiten der Vorsitzung plus die '
              'neue — ein verschluckter Lesefehler startete den Slot bei 0 '
              'und die Lebenszeit-Zaehler blieben dauerhaft zu kurz');
      expect(raw.snapshot.containsKey(_deltaKey), isTrue);
    });

    test('der Logout loescht den ungelesenen Slot NICHT', () async {
      final (raw, cipher, store) = _stapel();
      await _seedDeltas(store);
      cipher.blockiert = true;

      final a = setup(injizierterCache: LocalCache(store, _uid));
      a.server.offline = true;
      await boot(a.store);
      cipher.blockiert = false;

      await a.store.signOutCleanup();

      expect(raw.snapshot.containsKey(_deltaKey), isTrue,
          reason: 'sonst nimmt der Logout die Streak-Basis mit');
    });
  });

  // Review 2026-08-29, P3-02b: the residual window of the fix above. The
  // hydration brake held, but `_repairOutboxHydration` cleared
  // `_outboxHydrationFailed` in its `finally` UNCONDITIONALLY and then wrote
  // the blob. If the same transient failure also swallowed the REPAIR read,
  // the intact slot was overwritten after all — with two Sentry reports, but
  // gone. The two cases are distinguishable: a slot that still holds bytes
  // makes `readOutboxOrThrow` throw [UnreadableCacheSlot], while a provably
  // broken ciphertext is purged on read and arrives as plain `null`.
  group('P3-02b: die Stoerung haelt auch ueber die Nachhydration an', () {
    test('der Blob wird NICHT ueberschrieben und kommt spaeter zurueck',
        () async {
      final (raw, cipher, store) = _stapel();
      await _seedOutbox(store);
      final vorher = raw.snapshot[_outboxKey];
      // Blocked through the cold start AND the repair read. `encrypt` keeps
      // working, so an overwrite really is possible here.
      cipher.blockiert = true;

      final a = setup(injizierterCache: LocalCache(store, _uid));
      a.server.offline = true;
      await boot(a.store);
      expect(a.store.pendingOutbox, isEmpty,
          reason: 'Vorbedingung: die Hydration hat den Blob nicht gesehen');

      // The first write runs the repair — whose read fails again.
      final erste = a.store.addResultToDailyTotal(mealResult('Neu-Bowl'));
      await settle();

      // Read back through a SECOND, working decorator on the same raw store —
      // the blocked one would report the loss as "unreadable".
      final geschuetzt = await LocalCache(
              EncryptedKeyValueStore(raw, _AussetzenderCipher()), _uid)
          .readOutbox();
      expect(geschuetzt!.map((o) => o.entityId), <String>['m-alt'],
          reason: 'ein Slot, der nur gerade nicht LESBAR war, ist nicht '
              'nachweislich kaputt — lieber gar nicht persistieren als den '
              'nie zugestellten Write der Vorsitzung ueberschreiben');
      expect(raw.snapshot[_outboxKey], vorher, reason: 'Byte fuer Byte');

      // Pressure over: the next write merges both queues into the slot.
      cipher.blockiert = false;
      final zweite = a.store.addResultToDailyTotal(mealResult('Zweite-Bowl'));
      await settle();

      final blob = await LocalCache(store, _uid).readOutbox();
      expect(blob!.map((o) => o.entityId),
          containsAll(<String>['m-alt', erste, zweite]),
          reason: 'der geschuetzte Blob und die Ops dieser Sitzung');
    });

    test(
        'bleibt der Slot dauerhaft unlesbar, gewinnen irgendwann die Writes '
        'dieser Sitzung', () async {
      // Review 2026-08-31, B: the budget counts MOMENTS, not taps — a burst
      // in the same second is one chance. So the clock has to move, and the
      // fake one makes that deterministic.
      var jetzt = DateTime(2026, 8, 31, 9);
      await withClock(Clock(() => jetzt), () async {
        final (raw, cipher, store) = _stapel();
        await _seedOutbox(store);
        final vorher = raw.snapshot[_outboxKey];
        cipher.blockiert = true;

        final a = setup(injizierterCache: LocalCache(store, _uid));
        a.server.offline = true;
        await boot(a.store);

        // Every write retries the read; after the bounded number of attempts,
        // spread over the wall clock, the session's own durability wins.
        for (var i = 0; i < kOutboxRepairMaxAttempts + 1; i++) {
          jetzt = jetzt.add(kOutboxRepairMinSpacing);
          a.store.addResultToDailyTotal(mealResult('Bowl-$i'));
          await settle();
        }

        expect(raw.snapshot[_outboxKey], isNot(vorher),
            reason: 'ein Slot, der nach mehreren Versuchen immer noch nicht '
                'aufgeht, darf die Sitzung nicht dauerhaft ohne Persistenz '
                'lassen — sonst nimmt ein Kill ALLE neuen Writes mit');
      });
    });
  });

  group('Gegenprobe: nachgewiesen kaputter Ciphertext bleibt „leer"', () {
    test(
        'ein geraeumter Slot gilt als leer — kein Reparaturpfad, kein '
        'bewahrter Slot beim Logout', () async {
      final (raw, _, store) = _stapel();
      await _seedOutbox(store);
      // Foreign DEK: the tag check fails, the decorator PURGES the slot on
      // read. Nothing is left that an overwrite could lose.
      final fremd = EncryptedKeyValueStore(raw, _AussetzenderCipher('dek-b'));
      final a = setup(injizierterCache: LocalCache(fremd, _uid));
      a.server.offline = true;
      await boot(a.store);

      expect(raw.snapshot.containsKey(_outboxKey), isFalse,
          reason: 'Wegwerfen IST das Self-Healing — der Blob geht auch beim '
              'naechsten Start nicht auf');

      final neu = a.store.addResultToDailyTotal(mealResult('Neu-Bowl'));
      await settle();

      final blob = await LocalCache(fremd, _uid).readOutbox();
      expect(blob!.map((o) => o.entityId), contains(neu),
          reason: 'der geraeumte Slot darf die Sitzung nicht dauerhaft am '
              'Persistieren hindern');
      expect(blob.map((o) => o.entityId), isNot(contains('m-alt')),
          reason: 'was nachweislich nicht aufgeht, ist bereits verloren — es '
              'darf nicht als „unlesbar" jeden weiteren Write blockieren');
    });
  });

  // Review 2026-08-29, P3-02d: der Rest von P3-02c. Der Cache unterscheidet
  // seit dieser Nacht „gerade nicht lesbar" von „Inhalt nachweislich kaputt"
  // (RawSlotState -> UnreadableCacheSlot.transient), aber die Reparaturstelle
  // las den Wert nie: sie verzweigte nur ueber `e is UnreadableCacheSlot`.
  // Damit war ein Slot, der beweisbar nie wieder aufgeht, genauso lange
  // geschuetzt wie einer, der es gleich wieder tut — und die Sitzung stand so
  // lange ohne Persistenz da. Die Feld-Doku sagte schon immer das Richtige
  // („the caller may give up at once"), also gibt der Code nach.
  group('P3-02d: nachweislich kaputter INHALT verbraucht keinen Versuch', () {
    test('Outbox: der ERSTE Write nimmt den Slot in Besitz', () async {
      final (raw, cipher, store) = _stapel();
      await _seedKaputtenInhalt(raw, cipher, _outboxKey);
      final kaputt = raw.snapshot[_outboxKey];

      final cache = _ZaehlenderCache(store, _uid);
      final a = setup(injizierterCache: cache);
      a.server.offline = true;
      await boot(a.store);
      expect(a.store.pendingOutbox, isEmpty,
          reason: 'Vorbedingung: die Hydration konnte den Slot nicht lesen');
      final nachBoot = cache.outboxLeseversuche;

      // GENAU EIN Write — keine Schleife ueber kOutboxRepairMaxAttempts.
      final neu = a.store.addResultToDailyTotal(mealResult('Neu-Bowl'));
      await settle();

      expect(cache.outboxLeseversuche, nachBoot + 1,
          reason: 'ein einziger Nachlesevorgang, der das Urteil holt — jeder '
              'weitere waere ein geschuetzter und damit ungesicherter Write');
      expect(raw.snapshot[_outboxKey], isNot(kaputt),
          reason: 'die Bytes haben sich ausgehaendigt und waren trotzdem '
              'unbrauchbar — das ist eine Aussage ueber den INHALT und sie '
              'ist endgueltig. Jeder geschuetzte Versuch kostet einen '
              'ungesicherten Write und kann nichts gewinnen');
      final blob = await LocalCache(store, _uid).readOutbox();
      expect(blob!.map((o) => o.entityId), contains(neu),
          reason: 'die Op dieser Sitzung muss sofort kill-sicher liegen');
    });

    test('Deltas: ebenso — die naechsten Zahlen landen sofort', () async {
      final (raw, cipher, store) = _stapel();
      await _seedKaputtenInhalt(raw, cipher, _deltaKey);
      final kaputt = raw.snapshot[_deltaKey];

      final cache = _ZaehlenderCache(store, _uid);
      final a = setup(injizierterCache: cache);
      await boot(a.store);
      final nachBoot = cache.deltaLeseversuche;

      // Die Mahlzeit geht durch, nur increment_lifetime_stats scheitert: genau
      // die Lage, die ein Delta bucht und den Slot neu schreibt.
      a.server.statsOffline = true;
      a.store.addResultToDailyTotal(mealResult('Neu-Bowl'));
      await settle();
      a.store.flushPendingWrites();
      await settle();

      expect(cache.deltaLeseversuche, nachBoot + 1,
          reason: 'derselbe Nachweis wie oben: die Bremse haette pro '
              'geschuetztem Flush einen weiteren Nachlesevorgang gekostet');
      expect(raw.snapshot[_deltaKey], isNot(kaputt));
      final deltas = await LocalCache(store, _uid).readPendingStatsDeltas();
      expect(deltas!.meals, 1,
          reason: 'aus kaputten Bytes wird durch Wiederlesen keine Zahl — die '
              'Mahlzeiten dieser Sitzung fielen sonst so lange aus dem '
              'kill-sicheren Slot, wie die Bremse laeuft');
    });

    test(
        'Gegenprobe: nur gerade nicht lesbar bleibt den vollen Bremsweg lang '
        'geschuetzt', () async {
      final (raw, cipher, store) = _stapel();
      await _seedOutbox(store);
      final vorher = raw.snapshot[_outboxKey];
      cipher.blockiert = true;

      final a = setup(injizierterCache: LocalCache(store, _uid));
      a.server.offline = true;
      await boot(a.store);

      a.store.addResultToDailyTotal(mealResult('Neu-Bowl'));
      await settle();

      expect(raw.snapshot[_outboxKey], vorher,
          reason: 'derselbe erste Write, nur mit transient: true — hier ist '
              'Nichtwissen weiterhin keine Erlaubnis zum Ueberschreiben');
    });
  });
}
