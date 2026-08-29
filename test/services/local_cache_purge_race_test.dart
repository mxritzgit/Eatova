import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/auth_gate.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/secure_cache_store.dart';

// Review 2026-08-29, P3-01: the in-flight encryption survived the purge.
//
// `purgePersonalCacheFor` closes the store's own LocalCache and then purges
// through a SECOND instance. The `_closed` fence only stops writes that have
// not STARTED — a diary blob already handed to the encryption isolate (91.5 ms
// for 210 meals on desktop JIT, 2-4x on mobile AOT) is past it. And the second
// instance brings its OWN EncryptedKeyValueStore, whose write queue serialises
// per key AND per instance, so its `remove` does not queue behind that running
// `setString`. The blob landed AFTER the purge and survived the logout on the
// device.
//
// The same-instance case has been covered since G9 ("remove ueberholt einen
// laufenden Write nicht", secure_cache_store_test.dart) — the gap was the
// cross-instance path. `HomeStore._clearCache` already waits for a running
// snapshot for exactly this reason; the AuthGate path did not.
//
// Pinned here:
//   1. `closeInstancesFor` waits for the writes already inside the store.
//   2. Belt and braces: a write that finishes on a CLOSED instance takes its
//      own blob back out, so a purge that does not wait still ends clean.
//   3. Foreign users and the preserved outbox slot are untouched.

const String _uid = 'user-purge';
const String _mealsKey = 'eatova.v1.logged_meals.$_uid';
const String _outboxKey = 'eatova.v1.outbox.$_uid';
const String _pii = 'Doener Teller, 820 kcal';

/// Cipher in the real wire frame whose `encrypt` hangs on a gate — stands for
/// the isolate hop that P3-01 is about.
class _AufgehaltenerCipher implements CacheCipher {
  _AufgehaltenerCipher(this.salt);

  final String salt;

  /// Opened by [oeffnen]; every `encrypt` waits for it first.
  final Completer<void> _tor = Completer<void>();

  /// Encrypt calls that have entered the gate.
  int encryptEintritte = 0;

  void oeffnen() {
    if (!_tor.isCompleted) _tor.complete();
  }

  @override
  Future<String> encrypt(String key, String plaintext) async {
    encryptEintritte++;
    await _tor.future;
    return '$cacheCipherMagic'
        '${base64.encode(utf8.encode(jsonEncode([salt, key, plaintext])))}';
  }

  @override
  Future<String> decrypt(String key, String armored) async {
    if (!armored.startsWith(cacheCipherMagic)) {
      throw const FormatException('kein Magic');
    }
    final parts = jsonDecode(
      utf8.decode(base64.decode(armored.substring(cacheCipherMagic.length))),
    ) as List<dynamic>;
    if (parts[0] != salt) throw const FormatException('falscher Key');
    if (parts[1] != key) throw const FormatException('AAD passt nicht');
    return parts[2] as String;
  }
}

/// Same wire frame, no gate — the purge instance encrypts nothing, but it
/// needs a cipher.
class _SofortCipher extends _AufgehaltenerCipher {
  _SofortCipher(super.salt) {
    oeffnen();
  }
}

LoggedMeal _meal(String id) => LoggedMeal(
      id: id,
      result: const MealAnalysisResult(
        mealName: 'Doener Teller',
        caloriesKcal: 820,
        estimatedGrams: 480,
        kcalPer100G: 170.8,
        protein: '48 g',
        carbs: '62 g',
        fat: '38 g',
        confidence: 'Mittel',
        portionNotes: _pii,
        sourceLabel: 'Foto-KI',
      ),
      loggedAt: DateTime(2026, 8, 29, 12, 30),
      forcedSlot: MealSlot.lunch,
      localDay: '2026-08-29',
    );

/// The production shape: both instances sit on the SAME raw storage
/// (SharedPreferences is global) but each on its own encrypting decorator.
({
  InMemoryKeyValueStore roh,
  _AufgehaltenerCipher cipher,
  LocalCache store,
  LocalCache purge,
}) _zweiInstanzen() {
  final roh = InMemoryKeyValueStore();
  final cipher = _AufgehaltenerCipher('dek-a');
  return (
    roh: roh,
    cipher: cipher,
    store: LocalCache(
      EncryptedKeyValueStore(roh, cipher, acceptLegacyPlaintext: false),
      _uid,
    ),
    purge: LocalCache(
      EncryptedKeyValueStore(roh, _SofortCipher('dek-a'),
          acceptLegacyPlaintext: false),
      _uid,
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('P3-01: laufende Verschluesselung ueberlebt die Purge nicht', () {
    test(
        'ein beim Purge noch verschluesselnder Diary-Write darf den Slot '
        'danach nicht wiederbeleben', () async {
      final f = _zweiInstanzen();
      // The write passes the fence and hands the blob to the "isolate".
      final schreiben = f.store.writeLoggedMeals([_meal('m-privat')]);
      await pumpEventQueue();
      expect(f.cipher.encryptEintritte, 1, reason: 'Vorbedingung: der Write '
          'steckt in der Verschluesselung');
      expect(f.roh.snapshot.keys, isNot(contains(_mealsKey)),
          reason: 'Vorbedingung: noch nichts auf Platte');

      // The encryption finishes DURING the purge — exactly the window.
      Timer(const Duration(milliseconds: 20), f.cipher.oeffnen);
      await LocalCache.closeInstancesFor(_uid);
      await purgePersonalCache(f.purge);

      await schreiben;
      await pumpEventQueue();

      expect(f.roh.snapshot.keys, isNot(contains(_mealsKey)),
          reason: 'der Tagebuch-Blob (Mahlzeitennamen, kcal, Makros) darf den '
              'Logout auf dem Geraet nicht ueberleben');
      expect(f.roh.snapshot.values.join(), isNot(contains(_pii)));
    });

    test('closeInstancesFor wartet, statt sofort zurueckzukehren', () async {
      final f = _zweiInstanzen();
      unawaited(f.store.writeLoggedMeals([_meal('m-privat')]));
      await pumpEventQueue();

      var fertig = false;
      final warten = LocalCache.closeInstancesFor(_uid).then((_) {
        fertig = true;
      });
      await pumpEventQueue();
      expect(fertig, isFalse,
          reason: 'solange die Verschluesselung laeuft, darf die Purge nicht '
              'starten');

      f.cipher.oeffnen();
      await warten;
      expect(fertig, isTrue);
      expect(f.cipher.encryptEintritte, 1,
          reason: 'gewartet wurde auf genau diesen Write');
      expect(f.roh.snapshot.keys, isNot(contains(_mealsKey)),
          reason: 'gewartet wird, bis der Write komplett durch ist — samt '
              'seines Selbst-Aufraeumens auf der geschlossenen Instanz');
    });

    test(
        'ohne Warten raeumt der Write seinen Slot selbst wieder — eine Purge, '
        'die nicht wartet, endet trotzdem sauber', () async {
      final f = _zweiInstanzen();
      final schreiben = f.store.writeLoggedMeals([_meal('m-privat')]);
      await pumpEventQueue();

      // close() alone: the path without settle (budget spent, or any future
      // caller that only closes).
      f.store.close();
      await purgePersonalCache(f.purge);
      f.cipher.oeffnen();
      await schreiben;
      await pumpEventQueue();

      expect(f.roh.snapshot.keys, isNot(contains(_mealsKey)),
          reason: 'der Write landet nach der Purge — und nimmt sich selbst '
              'wieder zurueck');
    });

    test('fremde Nutzer und der bewahrte Outbox-Slot bleiben unberuehrt',
        () async {
      final f = _zweiInstanzen();
      final fremd = LocalCache(
        EncryptedKeyValueStore(f.roh, _SofortCipher('dek-a'),
            acceptLegacyPlaintext: false),
        'anderer',
      );
      await fremd.writeLoggedMeals([_meal('m-fremd')]);
      // The outbox rides the durable path and is preserved by A2.
      f.cipher.oeffnen();
      expect(await f.purge.writeOutbox(const []), isTrue);

      final schreiben = f.store.writeLoggedMeals([_meal('m-privat')]);
      await LocalCache.closeInstancesFor(_uid);
      await purgePersonalCache(f.purge);
      await schreiben;
      await pumpEventQueue();

      expect(f.roh.snapshot.keys, isNot(contains(_mealsKey)));
      expect(f.roh.snapshot.keys, contains(_outboxKey),
          reason: 'A2: unsynchronisierte Writes spielen beim naechsten Login '
              'nach');
      expect(f.roh.snapshot.keys,
          contains('eatova.v1.logged_meals.anderer'));
      expect(fremd.isClosed, isFalse);
    });

    test('closeInstancesFor kehrt sofort zurueck, wenn nichts laeuft',
        () async {
      final f = _zweiInstanzen();
      f.cipher.oeffnen();
      await f.store.writeLoggedMeals([_meal('m-privat')]);
      expect(f.roh.snapshot.keys, contains(_mealsKey), reason: 'Vorbedingung');

      await LocalCache.closeInstancesFor(_uid).timeout(
          const Duration(seconds: 1),
          onTimeout: () => fail('closeInstancesFor haengt ohne laufenden '
              'Write'));

      expect(f.store.isClosed, isTrue);
    });
  });
}
