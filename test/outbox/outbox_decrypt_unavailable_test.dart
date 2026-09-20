import 'dart:convert';
import 'dart:isolate';

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/api.dart' show InvalidCipherTextException;

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
    final parts =
        jsonDecode(
              utf8.decode(
                base64.decode(armored.substring(cacheCipherMagic.length)),
              ),
            )
            as List<dynamic>;
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
(InMemoryKeyValueStore, _AussetzenderCipher, EncryptedKeyValueStore) _stapel() {
  final raw = InMemoryKeyValueStore();
  final cipher = _AussetzenderCipher();
  return (raw, cipher, EncryptedKeyValueStore(raw, cipher));
}

/// One undelivered op of a previous session in the persisted outbox.
Future<void> _seedOutbox(EncryptedKeyValueStore store) => LocalCache(
  store,
  _uid,
).writeOutbox([SyncOp.mealInsert(_meal('m-alt'), trackDay: false)]);

/// Three never-booked meals in the persisted deltas slot.
Future<void> _seedDeltas(EncryptedKeyValueStore store) => LocalCache(
  store,
  _uid,
).writePendingStatsDeltas(meals: 3, weightLogs: 0, requestId: '40000000-0000-4000-8000-000000000004');

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Outbox: Entschluesselung erholt sich, alter und neuer Save bleiben', () async {
    final (raw, cipher, encrypted) = _stapel();
    await _seedOutbox(encrypted);
    cipher.blockiert = true;
    final a = setup(injizierterCache: LocalCache(encrypted, _uid));
    a.server.offline = true;
    await bootUntilIdle(a.store);
    expect(a.store.pendingOutbox, isEmpty);
    cipher.blockiert = false;
    final id = await a.store.addResultToDailyTotal(mealResult('Neu'));
    final pending = await LocalCache(encrypted, _uid).readSyncOperations();
    expect(pending.map((op) => op.entityId), containsAll(['m-alt', id]));
    expect(a.store.loggedMeals.map((meal) => meal.id), containsAll(['m-alt', id]));
    expect(raw.snapshot[_outboxKey], startsWith(cacheCipherMagic));
  });

  for (final slot in ['outbox', 'pending_stats']) {
    test('$slot: Logout bewahrt auch ungelesene verschluesselte Daten', () async {
      final (raw, cipher, encrypted) = _stapel();
      if (slot == 'outbox') {
        await _seedOutbox(encrypted);
      } else {
        await _seedDeltas(encrypted);
      }
      final key = slot == 'outbox' ? _outboxKey : _deltaKey;
      final before = raw.snapshot[key];
      cipher.blockiert = true;
      final a = setup(injizierterCache: LocalCache(encrypted, _uid));
      a.server.offline = true;
      await bootUntilIdle(a.store);
      await a.store.signOutCleanup();
      expect(raw.snapshot[key], before);
    });
  }

  test('Legacy Stats: Migration plus neuer Save sind vor HTTP dauerhaft', () async {
    final (_, cipher, encrypted) = _stapel();
    await _seedDeltas(encrypted);
    cipher.blockiert = true;
    final a = setup(injizierterCache: LocalCache(encrypted, _uid));
    a.server.offline = true;
    await bootUntilIdle(a.store);
    cipher.blockiert = false;
    final id = await a.store.addResultToDailyTotal(mealResult('Neu'));
    final reader = LocalCache(encrypted, _uid);
    final pending = await reader.readSyncOperations();
    expect(pending.singleWhere((op) => op.kind == SyncOpKind.statsIncrement).statsMeals, 3);
    expect(pending.where((op) => op.kind == SyncOpKind.mealInsert).single.entityId, id);
    expect((await reader.readPendingStatsDeltasOrThrow())!.meals, 0);
  });

  test('anhaltender Decryptfehler: kein bestaetigter Save, spaeter sichere Erholung', () async {
    final (raw, cipher, encrypted) = _stapel();
    await _seedOutbox(encrypted);
    final before = raw.snapshot[_outboxKey];
    cipher.blockiert = true;
    final a = setup(injizierterCache: LocalCache(encrypted, _uid));
    a.server.offline = true;
    await bootUntilIdle(a.store);
    await expectLater(a.store.addResultToDailyTotal(mealResult('Nicht gespeichert')), throwsStateError);
    expect(a.store.loggedMeals, isEmpty);
    expect(raw.snapshot[_outboxKey], before);
    cipher.blockiert = false;
    final id = await a.store.addResultToDailyTotal(mealResult('Jetzt gespeichert'));
    final pending = await LocalCache(encrypted, _uid).readSyncOperations();
    expect(pending.map((op) => op.entityId), containsAll(['m-alt', id]));
    expect(a.store.loggedMeals.map((m) => m.result.mealName), isNot(contains('Nicht gespeichert')));
  });

  test('Zeit und viele Fehler erlauben niemals die Uebernahme eines unbekannten Slots', () async {
    var now = DateTime(2026, 9, 20);
    await withClock(Clock(() => now), () async {
      final (raw, cipher, encrypted) = _stapel();
      await _seedOutbox(encrypted);
      final before = raw.snapshot[_outboxKey];
      cipher.blockiert = true;
      final a = setup(injizierterCache: LocalCache(encrypted, _uid));
      a.server.offline = true;
      await bootUntilIdle(a.store);
      for (var i = 0; i < 12; i++) {
        now = now.add(const Duration(days: 40));
        await expectLater(a.store.addResultToDailyTotal(mealResult('Nicht gespeichert-$i')), throwsStateError);
      }
      expect(raw.snapshot[_outboxKey], before);
      expect(a.store.loggedMeals, isEmpty);
    });
  });

  test('fremder Schluessel loescht keine bisher bestaetigte Outbox', () async {
    final (raw, _, encrypted) = _stapel();
    await _seedOutbox(encrypted);
    final before = raw.snapshot[_outboxKey];
    final wrong = EncryptedKeyValueStore(raw, _AussetzenderCipher('wrong'));
    final a = setup(injizierterCache: LocalCache(wrong, _uid));
    a.server.offline = true;
    await bootUntilIdle(a.store);
    await expectLater(a.store.addResultToDailyTotal(mealResult('Abgelehnt')), throwsStateError);
    expect(raw.snapshot[_outboxKey], before);
    expect((await LocalCache(encrypted, _uid).readSyncOperations()).single.entityId, 'm-alt');
  });

  for (final key in [_outboxKey, _deltaKey]) {
    test('kaputter JSON-Inhalt bleibt ohne destruktive Selbstheilung erhalten: $key', () async {
      final (raw, cipher, encrypted) = _stapel();
      await _seedKaputtenInhalt(raw, cipher, key);
      final before = raw.snapshot[key];
      final a = setup(injizierterCache: LocalCache(encrypted, _uid));
      a.server.offline = true;
      await bootUntilIdle(a.store);
      await expectLater(a.store.addResultToDailyTotal(mealResult('Abgelehnt')), throwsStateError);
      expect(raw.snapshot[key], before);
      expect(a.store.loggedMeals, isEmpty);
    });
  }

  test('mehrere Reparaturversuche koennen den aktuellen Bytebestand nicht ersetzen', () async {
    final (raw, cipher, encrypted) = _stapel();
    await _seedDeltas(encrypted);
    final before = raw.snapshot[_deltaKey];
    cipher.blockiert = true;
    final a = setup(injizierterCache: LocalCache(encrypted, _uid));
    a.server.offline = true;
    await bootUntilIdle(a.store);
    for (var i = 0; i < 5; i++) {
      await a.store.syncPendingWrites();
      await expectLater(a.store.logWeight(80), throwsStateError);
    }
    expect(raw.snapshot[_deltaKey], before);
  });
}