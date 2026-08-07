import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/secure_cache_store.dart';

// SEC-1: der LocalCache haelt DSGVO-Art.-9-Gesundheitsdaten (35 Tage Tagebuch
// inkl. Freitext, Gewichtsreihe, Koerpermasse). EncryptedKeyValueStore legt
// AES-256-GCM darunter, der Key liegt im OS-Keystore.
//
// Diese Tests treiben den Dekorator ueber einen InMemoryKeyValueStore mit
// injizierter Cipher — KEIN Plugin-Channel, weder shared_preferences noch
// flutter_secure_storage. Gesichert wird:
//   1. Roundtrip + der rohe Slot enthaelt keinen Klartext mehr.
//   2. Legacy-Klartext wird beim ERSTEN Read migriert, ohne den Read zu
//      verlieren; die Migration ist idempotent.
//   3. Ein unentschluesselbarer Slot liefert null, wird geraeumt und wirft
//      nicht — auch nicht durch LocalCache hindurch.
//   4. AAD-Bindung: ein Ciphertext laesst sich nicht in einen anderen Slot
//      (= anderen User) verschieben.
//   5. Nonce-Frische: zweimal dasselbe verschluesseln ergibt zwei Blobs.
//   6. Der DEK-Bootstrap ist single-flight (sonst zwei DEKs, zweiter gewinnt,
//      alle Daten des Verlierers lautlos verloren).
//   7. Ein Smoke-Test mit der ECHTEN pointycastle-Cipher durch LocalCache,
//      damit eine API-Fehlbenutzung nicht hinter dem Fake verschwindet.

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

/// Deterministische Test-Cipher im echten Wire-Format-Rahmen.
/// [salt] steht fuer "der DEK": eine andere Instanz = ein anderer Key.
/// Die Cipher bindet den Slot-Key genauso wie AES-GCM ihn als AAD bindet.
class _FakeCipher implements CacheCipher {
  _FakeCipher(this.salt);

  final String salt;

  @override
  String encrypt(String key, String plaintext) => '$cacheCipherMagic'
      '${base64.encode(utf8.encode(jsonEncode([salt, key, plaintext])))}';

  @override
  String decrypt(String key, String armored) {
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

/// Zaehlender Fake-Keystore fuer den Single-Flight-Test. Der kuenstliche
/// Delay im read() oeffnet genau das Fenster, in dem zwei nebenlaeufige
/// Bootstraps sich gegenseitig ueberschreiben wuerden.
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
}

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

const String _pii = 'Rueckenschmerzen nach dem Kebab';

const String _profileJson =
    '{"weight_kg":82,"height_cm":181,"age_years":34,"sex":"male"}';

/// 32 Byte, hart kodiert — der Smoke-Test darf NICHT an den OS-Keystore.
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
  setUp(CacheKeyProvider.debugReset);
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
    test('erster Read liefert Klartext UND verschluesselt den Slot', () async {
      const key = 'eatova.v1.profile.user-1';
      final raw = InMemoryKeyValueStore({key: _profileJson});
      final store = EncryptedKeyValueStore(raw, _FakeCipher('dek-a'));

      expect(await store.getString(key), _profileJson);
      expect(raw.snapshot[key], startsWith(cacheCipherMagic));
      expect(raw.snapshot[key], isNot(contains('weight_kg')));

      // Zweiter Read geht ueber den Entschluesselungs-Zweig, gleiches Ergebnis.
      expect(await store.getString(key), _profileJson);
    });

    test('Migration ist ueber drei Reads idempotent', () async {
      const key = 'eatova.v1.outbox.user-1';
      final raw = InMemoryKeyValueStore({key: '{"items":[]}'});
      final store = EncryptedKeyValueStore(raw, _FakeCipher('dek-a'));

      final first = await store.getString(key);
      final afterFirst = raw.snapshot[key];
      final second = await store.getString(key);
      final afterSecond = raw.snapshot[key];
      final third = await store.getString(key);

      expect(first, '{"items":[]}');
      expect(second, '{"items":[]}');
      expect(third, '{"items":[]}');
      // Nach der ersten Migration aendert sich der rohe Wert nicht mehr.
      expect(afterFirst, startsWith(cacheCipherMagic));
      expect(afterSecond, afterFirst);
      expect(raw.snapshot[key], afterFirst);
    });
  });

  group('EncryptedKeyValueStore unentschluesselbarer Slot', () {
    test('falscher Key -> null, Slot geraeumt, kein Throw', () async {
      const key = 'eatova.v1.logged_meals.user-1';
      final raw = InMemoryKeyValueStore();
      final writer = EncryptedKeyValueStore(raw, _FakeCipher('dek-a'));
      await writer.setString(key, _profileJson);
      expect(raw.snapshot.containsKey(key), isTrue);

      // Anderer DEK — z.B. nach einem invalidierten Keystore-Key.
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
      // Alle Slots sind geraeumt — der naechste Netz-Load fuellt sie neu.
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
      // Angreifer mit Schreibzugriff kopiert den Blob in den Slot des anderen
      // Users. Ohne AAD-Bindung wuerde der sich sauber entschluesseln lassen.
      await raw.setString(k2, raw.snapshot[k1]!);

      expect(await store.getString(k2), isNull);
      expect(raw.snapshot.containsKey(k2), isFalse);
      // Der Original-Slot bleibt intakt.
      expect(await store.getString(k1), _profileJson);
    });

    test('Nonce-Frische: gleiche Eingabe zweimal -> zwei verschiedene Blobs',
        () {
      const key = 'eatova.v1.weight_log.user-1';
      final cipher = AesGcmCacheCipher(_hardCodedDek);

      final a = cipher.encrypt(key, _profileJson);
      final b = cipher.encrypt(key, _profileJson);

      expect(a, isNot(b), reason: 'Feste Nonce = GCM-Katastrophe.');
      expect(cipher.decrypt(key, a), _profileJson);
      expect(cipher.decrypt(key, b), _profileJson);
    });

    test('manipulierter Ciphertext wirft (Auth-Tag greift)', () {
      const key = 'eatova.v1.stats.user-1';
      final cipher = AesGcmCacheCipher(_hardCodedDek);
      final armored = cipher.encrypt(key, _profileJson);

      // Ein Zeichen im base64-Teil kippen.
      final body = armored.substring(cacheCipherMagic.length);
      final flipped = (body[0] == 'A' ? 'B' : 'A') + body.substring(1);

      expect(() => cipher.decrypt(key, '$cacheCipherMagic$flipped'), throwsA(anything));
    });

    test('SMOKE: voller writeLoggedMeals/readLoggedMeals-Roundtrip durch '
        'LocalCache mit echter pointycastle-Cipher', () async {
      // Kein Keystore, kein Channel — nur der hart kodierte 32-Byte-DEK.
      // Faengt pointycastle-API-Fehlbenutzung, die ein Fake verstecken wuerde.
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

    test('grosser Blob (~200 kB) roundtrippt', () {
      const key = 'eatova.v1.logged_meals.user-1';
      final cipher = AesGcmCacheCipher(_hardCodedDek);
      final big = jsonEncode({'items': List<String>.filled(4000, _pii)});

      expect(cipher.decrypt(key, cipher.encrypt(key, big)), big);
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

    test('vorhandener DEK wird gelesen statt neu erzeugt', () async {
      final keyStore = _CountingKeyStore()
        ..data[CacheKeyProvider.dekStorageKey] = base64.encode(_hardCodedDek);

      expect(await CacheKeyProvider.obtain(keyStore: keyStore), _hardCodedDek);
      expect(keyStore.writes, 0);
    });

    test('EncryptedKeyValueStore.create liefert null ohne DEK', () async {
      final store = await EncryptedKeyValueStore.create(
        InMemoryKeyValueStore(),
        keyStore: _FailingKeyStore(),
      );
      // Kein Klartext-Fallback: lieber gar kein Cache.
      expect(store, isNull);
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
      // Fremder Namensraum bleibt unangetastet.
      expect(raw.snapshot.containsKey('eatova.v1.daily.user-2'), isTrue);
    });
  });
}

/// Keystore, dessen Read wirft — simuliert einen kaputten OS-Keystore. In dem
/// Fall wird BEWUSST kein neuer DEK erzeugt (ein vorhandener koennte nur
/// gerade unlesbar sein; ihn zu ueberschreiben wuerde den Cache endgueltig
/// verwaisen lassen).
class _FailingKeyStore implements SecureKeyStore {
  @override
  Future<String?> read(String key) async => throw StateError('keystore kaputt');

  @override
  Future<void> write(String key, String value) async =>
      throw StateError('keystore kaputt');
}
