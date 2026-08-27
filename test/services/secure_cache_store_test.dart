import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/api.dart' show InvalidCipherTextException;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/secure_cache_store.dart';

// SEC-1: LocalCache holds GDPR Art. 9 health data, so EncryptedKeyValueStore
// puts AES-256-GCM underneath with the key in the OS keystore.
//
// Driven over an InMemoryKeyValueStore with an injected cipher, no plugin
// channel. Covers roundtrip, idempotent legacy migration, purge-and-null on
// an undecryptable slot, AAD binding against slot (= user) swaps, nonce
// freshness, a single-flight DEK bootstrap, and the REAL cipher.

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

/// Deterministic test cipher in the real wire-format frame. [salt] stands for
/// the DEK, and the slot key is bound the way AES-GCM binds AAD.
class _FakeCipher implements CacheCipher {
  _FakeCipher(this.salt);

  final String salt;

  /// Per-call delay modelling the isolate hop; consumed from the front.
  final List<Duration> encryptDelays = [];

  @override
  Future<String> encrypt(String key, String plaintext) async {
    if (encryptDelays.isNotEmpty) {
      await Future<void>.delayed(encryptDelays.removeAt(0));
    }
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

/// Counting fake keystore for the single-flight test; the delay in read()
/// opens the window in which two bootstraps would overwrite each other.
class _CountingKeyStore implements SecureKeyStore {
  final Map<String, String> data = {};
  int reads = 0;
  int writes = 0;

  @override
  Future<String?> read(String key) async {
    reads++;
    await Future<void>.delayed(const Duration(milliseconds: 5));
    return data[key];
  }

  @override
  Future<void> write(String key, String value) async {
    writes++;
    await Future<void>.delayed(const Duration(milliseconds: 5));
    data[key] = value;
  }

  @override
  Future<void> delete(String key) async => data.remove(key);
}

/// A1: flutter_secure_storage 10.x with `resetOnError = true`, where an error
/// deletes the key and the retry returns `null` — indistinguishable from a
/// first start, which is the finding.
class _ResettingKeyStore implements SecureKeyStore {
  final Map<String, String> data = {};
  int writes = 0;

  /// From now on the keystore behaves as after `handleStorageError`.
  bool keystoreResetsOnRead = false;

  @override
  Future<String?> read(String key) async {
    if (keystoreResetsOnRead) {
      data.remove(key);
      return null;
    }
    return data[key];
  }

  @override
  Future<void> write(String key, String value) async {
    writes++;
    data[key] = value;
  }

  @override
  Future<void> delete(String key) async => data.remove(key);
}

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

const String _pii = 'Rueckenschmerzen nach dem Kebab';

const String _profileJson =
    '{"weight_kg":82,"height_cm":181,"age_years":34,"sex":"male"}';

/// 32 bytes, hardcoded — the smoke test must NOT touch the OS keystore.
final Uint8List _hardCodedDek = Uint8List.fromList(
  List<int>.generate(AesGcmCacheCipher.dekLengthBytes, (i) => (i * 7 + 11) & 0xFF),
);

MealAnalysisResult _result() => const MealAnalysisResult(
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
    );

LoggedMeal _meal(String id) => LoggedMeal(
      id: id,
      result: _result(),
      loggedAt: DateTime(2026, 8, 5, 12, 30),
      forcedSlot: MealSlot.lunch,
      localDay: '2026-08-05',
    );

void main() {
  // The DEK sentinel (A1) lives in SharedPreferences, hence the prefs mock.
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    CacheKeyProvider.debugReset();
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });
  tearDown(CacheKeyProvider.debugReset);

  group('EncryptedKeyValueStore Roundtrip', () {
    test('Wert kommt intakt zurueck, roh liegt kein Klartext mehr', () async {
      final raw = InMemoryKeyValueStore();
      final store = EncryptedKeyValueStore(raw, _FakeCipher('dek-a'));

      await store.setString('eatova.v1.profile.user-1', _profileJson);

      expect(await store.getString('eatova.v1.profile.user-1'), _profileJson);

      final stored = raw.snapshot['eatova.v1.profile.user-1'];
      expect(stored, isNotNull);
      expect(stored, isNot(_profileJson));
      expect(stored, startsWith(cacheCipherMagic));
      expect(stored, isNot(contains('weight_kg')));
    });

    test('fehlender und leerer Slot liefern null', () async {
      final raw = InMemoryKeyValueStore({'leer': ''});
      final store = EncryptedKeyValueStore(raw, _FakeCipher('dek-a'));

      expect(await store.getString('gibts-nicht'), isNull);
      expect(await store.getString('leer'), isNull);
    });
  });

  group('EncryptedKeyValueStore Legacy-Migration', () {
    test(
        'erster Read liefert Klartext UND verschluesselt den Slot — ueber drei '
        'Reads idempotent', () async {
      const key = 'eatova.v1.profile.user-1';
      final raw = InMemoryKeyValueStore({key: _profileJson});
      final store = EncryptedKeyValueStore(raw, _FakeCipher('dek-a'));

      expect(await store.getString(key), _profileJson);
      final nachErstem = raw.snapshot[key];
      expect(nachErstem, startsWith(cacheCipherMagic));
      expect(nachErstem, isNot(contains('weight_kg')));

      // The second read takes the decryption branch, same result.
      expect(await store.getString(key), _profileJson);
      final nachZweitem = raw.snapshot[key];
      // The third read proves it stays there: after the first migration the
      // raw value no longer changes, so no read re-encrypts the blob.
      expect(await store.getString(key), _profileJson);

      expect(nachZweitem, nachErstem);
      expect(raw.snapshot[key], nachErstem);
    });
  });

  group('EncryptedKeyValueStore unentschluesselbarer Slot', () {
    test('falscher Key -> null, Slot geraeumt, kein Throw', () async {
      const key = 'eatova.v1.logged_meals.user-1';
      final raw = InMemoryKeyValueStore();
      final writer = EncryptedKeyValueStore(raw, _FakeCipher('dek-a'));
      await writer.setString(key, _profileJson);
      expect(raw.snapshot.containsKey(key), isTrue);

      // Another DEK, e.g. after an invalidated keystore key.
      final reader = EncryptedKeyValueStore(raw, _FakeCipher('dek-b'));

      expect(await reader.getString(key), isNull);
      expect(raw.snapshot.containsKey(key), isFalse,
          reason: 'Der kaputte Slot muss geraeumt werden (Self-Healing).');
    });

    test('wirft nicht aus LocalCache heraus und liefert ueberall null',
        () async {
      final raw = InMemoryKeyValueStore();
      final writer = EncryptedKeyValueStore(raw, _FakeCipher('dek-a'));
      final seeding = LocalCache(writer, 'user-1');
      await seeding.writeProfile(const UserProfile(weightKg: 82, heightCm: 181));
      await seeding.writeLoggedMeals([_meal('m-1')]);
      await seeding.writeOutbox(const []);

      final broken =
          LocalCache(EncryptedKeyValueStore(raw, _FakeCipher('dek-b')), 'user-1');

      expect(await broken.readProfile(), isNull);
      expect(await broken.readLoggedMeals(), isNull);
      expect(await broken.readOutbox(), isNull);
      // All slots purged; the next network load refills them.
      expect(raw.snapshot.keys.where((k) => k.startsWith('eatova.v1.')), isEmpty);
    });
  });

  group('AesGcmCacheCipher (echte Krypto)', () {
    test('AAD-Bindung: Ciphertext in anderen Slot verschoben -> null + Purge',
        () async {
      const k1 = 'eatova.v1.profile.user-1';
      const k2 = 'eatova.v1.profile.user-2';
      final raw = InMemoryKeyValueStore();
      final store = EncryptedKeyValueStore(raw, AesGcmCacheCipher(_hardCodedDek));

      await store.setString(k1, _profileJson);
      // Without AAD binding this copy into another slot would decrypt.
      await raw.setString(k2, raw.snapshot[k1]!);

      expect(await store.getString(k2), isNull);
      expect(raw.snapshot.containsKey(k2), isFalse);
      // The original slot stays intact.
      expect(await store.getString(k1), _profileJson);
    });

    test('Nonce-Frische: gleiche Eingabe zweimal -> zwei verschiedene Blobs',
        () async {
      const key = 'eatova.v1.weight_log.user-1';
      final cipher = AesGcmCacheCipher(_hardCodedDek);

      final a = await cipher.encrypt(key, _profileJson);
      final b = await cipher.encrypt(key, _profileJson);

      expect(a, isNot(b), reason: 'Feste Nonce = GCM-Katastrophe.');
      expect(await cipher.decrypt(key, a), _profileJson);
      expect(await cipher.decrypt(key, b), _profileJson);
    });

    test('manipulierter Ciphertext wirft (Auth-Tag greift)', () async {
      const key = 'eatova.v1.stats.user-1';
      final cipher = AesGcmCacheCipher(_hardCodedDek);
      final armored = await cipher.encrypt(key, _profileJson);

      // Flip one character in the base64 part.
      final body = armored.substring(cacheCipherMagic.length);
      final flipped = (body[0] == 'A' ? 'B' : 'A') + body.substring(1);

      await expectLater(
          () async => cipher.decrypt(key, '$cacheCipherMagic$flipped'),
          throwsA(anything));
    });

    test('SMOKE: voller writeLoggedMeals/readLoggedMeals-Roundtrip durch '
        'LocalCache mit echter pointycastle-Cipher', () async {
      // Catches pointycastle API misuse a fake would hide.
      final raw = InMemoryKeyValueStore();
      final cache = LocalCache(
        EncryptedKeyValueStore(raw, AesGcmCacheCipher(_hardCodedDek)),
        'user-1',
      );

      await cache.writeLoggedMeals([_meal('m-1'), _meal('m-2')]);

      final stored = raw.snapshot['eatova.v1.logged_meals.user-1'];
      expect(stored, startsWith(cacheCipherMagic));
      expect(stored, isNot(contains(_pii)));
      expect(stored, isNot(contains('Doener')));

      final back = await cache.readLoggedMeals();
      expect(back, hasLength(2));
      expect(back![0].id, 'm-1');
      expect(back[0].forcedSlot, MealSlot.lunch);
      expect(back[0].localDay, '2026-08-05');
      expect(back[0].loggedAt, DateTime(2026, 8, 5, 12, 30));
      expect(back[0].result.mealName, 'Doener Teller');
      expect(back[0].result.caloriesKcal, 820);
      expect(back[0].result.portionNotes, _pii);
      expect(back[1].id, 'm-2');
    });

    test('grosser Blob (~200 kB) roundtrippt', () async {
      const key = 'eatova.v1.logged_meals.user-1';
      final cipher = AesGcmCacheCipher(_hardCodedDek);
      final big = jsonEncode({'items': List<String>.filled(4000, _pii)});

      expect(await cipher.decrypt(key, await cipher.encrypt(key, big)), big);
    });

    test('DEK mit falscher Laenge wird abgelehnt', () {
      expect(() => AesGcmCacheCipher(Uint8List(16)), throwsArgumentError);
    });
  });

  group('CacheKeyProvider', () {
    test('SINGLE-FLIGHT: zwei nebenlaeufige Aufrufe -> genau EIN Write',
        () async {
      final keyStore = _CountingKeyStore();

      final results = await Future.wait([
        CacheKeyProvider.obtain(keyStore: keyStore),
        CacheKeyProvider.obtain(keyStore: keyStore),
      ]);

      expect(keyStore.writes, 1,
          reason: 'Zwei DEKs = alle Werte unter dem Verlierer sind lautlos weg.');
      expect(keyStore.reads, 1);
      expect(results[0], isNotNull);
      expect(results[0], results[1]);
      expect(results[0], hasLength(AesGcmCacheCipher.dekLengthBytes));
      expect(base64.decode(keyStore.data[CacheKeyProvider.dekStorageKey]!),
          results[0]);
    });

    test('EncryptedKeyValueStore.create liefert null ohne DEK', () async {
      final store = await EncryptedKeyValueStore.create(
        InMemoryKeyValueStore(),
        keyStore: _FailingKeyStore(),
      );
      // No plaintext fallback: rather no cache at all.
      expect(store, isNull);
    });
  });

  // -------------------------------------------------------------------------
  // A1: resetOnError devalues the keystore protection
  // -------------------------------------------------------------------------
  group('A1 DEK-Sentinel', () {
    test(
        'geloeschter DEK bei gesetztem Sentinel praegt KEINEN neuen '
        '(sonst sind bis zu 500 nicht quittierte Writes weg)', () async {
      // The protection depends on a fresh DEK orphaning something.
      SharedPreferences.setMockInitialValues(<String, Object>{
        'eatova.v1.outbox.user-1': '${cacheCipherMagic}bmljaHQgcXVpdHRpZXJ0',
      });
      final keyStore = _ResettingKeyStore();

      // 1. First start: DEK is created, sentinel moves to SharedPreferences.
      final first = await CacheKeyProvider.obtain(keyStore: keyStore);
      expect(first, isNotNull, reason: 'Erststart muss einen DEK praegen.');
      expect(keyStore.writes, 1);

      // 2. resetOnError=true deletes the entry and returns null.
      CacheKeyProvider.debugReset();
      keyStore.keystoreResetsOnRead = true;

      final second = await CacheKeyProvider.obtain(keyStore: keyStore);

      expect(second, isNull,
          reason: 'Der Sentinel belegt, dass es schon einen DEK GAB — ein '
              'frischer wuerde alle EATOVA1-Slots unentschluesselbar machen '
              'und ueber _onUndecryptable loeschen.');
      expect(keyStore.writes, 1,
          reason: 'Kein zweiter Write: der alte Ciphertext bleibt liegen und '
              'ist nach einem Restore/Reinstall wieder lesbar.');
    });

    test('Erststart schreibt den Sentinel nach SharedPreferences', () async {
      // Fresh device: neither DEK nor sentinel.
      final keyStore = _ResettingKeyStore();

      expect(await CacheKeyProvider.obtain(keyStore: keyStore), isNotNull,
          reason: 'ohne Sentinel bleibt der Erststart moeglich — der Schutz '
              'darf eine frische Installation nicht bricken');

      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      expect(prefs.getBool('eatova.v1.dek_provisioned'), isTrue,
          reason: 'Der Sentinel muss einen Keystore-Reset UEBERLEBEN, darf '
              'also nicht im selben Secure Storage liegen.');
    });

    test(
        'Bestandsinstallation ohne Sentinel: vorhandener DEK setzt ihn nach',
        () async {
      final keyStore = _ResettingKeyStore()
        ..data[CacheKeyProvider.dekStorageKey] = base64.encode(_hardCodedDek);

      expect(await CacheKeyProvider.obtain(keyStore: keyStore), _hardCodedDek,
          reason: 'ein vorhandener DEK wird GELESEN, nicht neu erzeugt');
      expect(keyStore.writes, 0,
          reason: 'ein zweiter Write waere ein zweiter DEK — alles darunter '
              'waere lautlos weg');

      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      expect(prefs.getBool('eatova.v1.dek_provisioned'), isTrue,
          reason: 'Sonst waere jede Installation von VOR dieser Aenderung '
              'dauerhaft ungeschuetzt.');
    });
  });

  // -------------------------------------------------------------------------
  // G9: encryption freezes the UI
  // -------------------------------------------------------------------------
  group('G9 Krypto laeuft nicht im Aufrufer-Stack', () {
    // 256 kB: 210 meals = 108 kB = 91.5 ms synchronous on desktop JIT.
    final String big = 'x' * 262144;
    const String key = 'eatova.v1.logged_meals.user-1';

    test('encrypt gibt den Stack vor der Krypto frei', () async {
      final cipher = AesGcmCacheCipher(_hardCodedDek);

      final sw = Stopwatch()..start();
      final pending = cipher.encrypt(key, big);
      final syncMicros = sw.elapsedMicroseconds;
      sw.stop();
      await pending;

      expect(syncMicros / 1000, lessThan(20),
          reason: 'Synchron im Tap-Handler verbrachte Zeit. Vor dem Fix sind '
              'das ~220 ms — eingefrorene UI bei jedem Mahlzeit-Log.');
    });

    test('decrypt gibt den Stack vor der Krypto frei', () async {
      final cipher = AesGcmCacheCipher(_hardCodedDek);
      final armored = await cipher.encrypt(key, big);

      final sw = Stopwatch()..start();
      final pending = cipher.decrypt(key, armored);
      final syncMicros = sw.elapsedMicroseconds;
      sw.stop();
      expect(await pending, big);

      expect(syncMicros / 1000, lessThan(20),
          reason: 'Der Kaltstart-Pfad (_hydrateFromCache) waehrend der '
              'Welcome-Animation.');
    });

    test('EncryptedKeyValueStore.setString gibt den Stack frei', () async {
      final raw = InMemoryKeyValueStore();
      final store =
          EncryptedKeyValueStore(raw, AesGcmCacheCipher(_hardCodedDek));

      final sw = Stopwatch()..start();
      final pending = store.setString(key, big);
      final syncMicros = sw.elapsedMicroseconds;
      sw.stop();
      await pending;

      expect(syncMicros / 1000, lessThan(20));
      expect(await store.getString(key), big);
    });

    test(
        'WIRE-FORMAT: Golden-Blob aus der SYNCHRONEN Fassung bleibt lesbar '
        '(byte-identisches Format, AAD unveraendert)', () async {
      // Produced by the version before the compute() rewrite, same DEK.
      const golden = 'EATOVA1:XVBMN7A2JEKw9nyL7fLgHj53HpbeXoMtRyx6d/Nl5ATL9Mlr'
          'wKDsaeDUxBqzt/UPSleFveICKMU0kyb2O8elPdCIDEXWtgUPLFENVkD7EyfUyPG3R+'
          'LwSA==';
      final cipher = AesGcmCacheCipher(_hardCodedDek);

      expect(await cipher.decrypt('eatova.v1.profile.user-1', golden),
          _profileJson);
      // AAD stays the slot key: the same blob in a foreign slot must throw.
      await expectLater(
          () async => cipher.decrypt('eatova.v1.profile.user-2', golden),
          throwsA(anything));
    });
  });

  group('A1 Keystore-Optionen', () {
    test('resetOnError ist auf Android abgeschaltet', () {
      expect(PluginSecureKeyStore.androidOptions.toMap()['resetOnError'],
          'false',
          reason: 'Mit true loescht die Java-Seite den DEK bei JEDEM '
              'Keystore-Fehler und meldet Dart ein blankes null.');
      // Counter-check, in case the plugin changes its default again.
      expect(const AndroidOptions().toMap()['resetOnError'], 'true',
          reason: 'flutter_secure_storage hat seinen Default geaendert — das '
              'Override oben neu bewerten (mit true loescht die Java-Seite '
              'den DEK bei jedem Keystore-Fehler: Fund A1).');
    });

    test('iOS bleibt bei first_unlock_this_device', () {
      expect(PluginSecureKeyStore.iosOptions.accessibility,
          KeychainAccessibility.first_unlock_this_device);
      expect(PluginSecureKeyStore.iosOptions.synchronizable, isFalse,
          reason: 'Der DEK darf nie in die iCloud-Keychain.');
    });
  });

  group('G9 Nebenlaeufigkeit (durch den Isolate-Hop neu)', () {
    const key = 'eatova.v1.logged_meals.user-1';

    test('ueberlappende Writes auf denselben Slot behalten die Reihenfolge',
        () async {
      final raw = InMemoryKeyValueStore();
      final cipher = _FakeCipher('dek-a')
        ..encryptDelays.addAll([
          const Duration(milliseconds: 40), // the FIRST one takes longer
          Duration.zero,
        ]);
      final store = EncryptedKeyValueStore(raw, cipher);

      // The _cacheLoggedMeals() pattern: two unawaited writes in a row.
      final first = store.setString(key, '{"items":["ALT"]}');
      final second = store.setString(key, '{"items":["NEU"]}');
      await Future.wait([first, second]);

      expect(await store.getString(key), '{"items":["NEU"]}',
          reason: 'Ohne Serialisierung ueberholt der schnellere zweite '
              'Isolate den ersten und der ALTE Stand bleibt persistiert.');
    });

    test('remove ueberholt einen laufenden Write nicht (Logout-PII)',
        () async {
      final raw = InMemoryKeyValueStore();
      final cipher = _FakeCipher('dek-a')
        ..encryptDelays.add(const Duration(milliseconds: 40));
      final store = EncryptedKeyValueStore(raw, cipher);

      final write = store.setString(key, _profileJson);
      final removal = store.remove(key); // LocalCache.clear() on logout
      await Future.wait([write, removal]);

      expect(raw.snapshot.containsKey(key), isFalse,
          reason: 'Sonst taucht der Blob NACH dem Logout wieder auf.');
    });

    test('verschiedene Slots blockieren sich nicht gegenseitig', () async {
      final raw = InMemoryKeyValueStore();
      final cipher = _FakeCipher('dek-a')
        ..encryptDelays.add(const Duration(milliseconds: 60));
      final store = EncryptedKeyValueStore(raw, cipher);

      final sw = Stopwatch()..start();
      await Future.wait([
        store.setString('eatova.v1.logged_meals.user-1', '{"items":[]}'),
        store.setString('eatova.v1.favorites.user-1', '{"items":[]}'),
      ]);
      sw.stop();

      // ~60 ms in parallel vs. >= 120 ms serialised; loose against CI jitter.
      expect(sw.elapsedMilliseconds, lessThan(200));
      expect(raw.snapshot, hasLength(2));
    });

    test(
        'InvalidCipherTextException ueberlebt den Isolate-Hop '
        '(sonst faellt die Sentry-Klassifikation auf runtimeType zurueck)',
        () async {
      final armored =
          await AesGcmCacheCipher(_hardCodedDek).encrypt(key, _profileJson);
      final fremd = AesGcmCacheCipher(
          Uint8List.fromList(List<int>.filled(AesGcmCacheCipher.dekLengthBytes, 9)));

      await expectLater(() async => fremd.decrypt(key, armored),
          throwsA(isA<InvalidCipherTextException>()));
    });
  });

  group('LocalCache.dropLegacySlots', () {
    test('entfernt eatova.v1.daily.<uid> (Mood-Freitext aus Alt-Installation)',
        () async {
      final raw = InMemoryKeyValueStore({
        'eatova.v1.daily.user-1': '{"mood_note":"$_pii"}',
        'eatova.v1.daily.user-2': '{"mood_note":"fremd"}',
      });

      await LocalCache(raw, 'user-1').dropLegacySlots();

      expect(raw.snapshot.containsKey('eatova.v1.daily.user-1'), isFalse);
      // Foreign namespace stays untouched.
      expect(raw.snapshot.containsKey('eatova.v1.daily.user-2'), isTrue);
    });
  });
}

/// Keystore whose read throws. No new DEK is minted: an existing one may be
/// temporarily unreadable, and overwriting it orphans the cache.
class _FailingKeyStore implements SecureKeyStore {
  @override
  Future<String?> read(String key) async => throw StateError('keystore kaputt');

  @override
  Future<void> write(String key, String value) async =>
      throw StateError('keystore kaputt');

  @override
  Future<void> delete(String key) async => throw StateError('keystore kaputt');
}
