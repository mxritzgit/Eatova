import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:eatova/src/services/crash_reporter.dart';
import 'package:eatova/src/services/secure_cache_store.dart';

// A1/iOS: the sentinel abort is a DEAD END on iOS. ThisDeviceOnly keychain
// items are excluded from backups, NSUserDefaults is not, so a restore leaves
// sentinel + EATOVA1 blobs but no DEK and `obtain()` returns null forever.
//
// The way out held here: with no EATOVA1 slot minting is harmless; with blobs
// present abort but count it, and after [CacheKeyProvider.vanishStrikeBudget]
// starts treat the DEK as lost (purge, mint fresh, notify).

/// Keystore reporting "no entry" WITHOUT throwing — both platforms' signal
/// for a lost DEK. A REAL error lands in `_bootstrap`'s catch branch instead,
/// so this branch sees only a definitive absence.
class _AbsentDekKeyStore implements SecureKeyStore {
  final Map<String, String> data = <String, String>{};
  int writes = 0;

  @override
  Future<String?> read(String key) async => data[key];

  @override
  Future<void> write(String key, String value) async {
    writes++;
    data[key] = value;
  }

  @override
  Future<void> delete(String key) async => data.remove(key);
}

/// Probe whose look at SharedPreferences fails (plugin error).
class _FailingProbe implements CacheCiphertextProbe {
  @override
  Future<List<String>> encryptedKeys() async =>
      throw StateError('prefs kaputt');

  @override
  Future<void> purge(Iterable<String> keys) async =>
      throw StateError('prefs kaputt');
}

const String _blobKey = 'eatova.v1.outbox.user-1';
const String _deadBlob = '${cacheCipherMagic}dGhpcyBpcyB0b3Q=';

final Uint8List _hardCodedDek = Uint8List.fromList(
  List<int>.generate(AesGcmCacheCipher.dekLengthBytes, (i) => (i * 7 + 11) & 0xFF),
);

/// Seed plus fresh instance: `setMockInitialValues` resets the internal
/// completer, staling any previously held [SharedPreferences].
Future<SharedPreferences> _seedPrefs(Map<String, Object> values) async {
  SharedPreferences.setMockInitialValues(values);
  return SharedPreferences.getInstance();
}

/// A new app start: memoisation and the per-process strike are gone,
/// SharedPreferences survives.
void _restartApp() => CacheKeyProvider.debugReset();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    CacheKeyProvider.debugReset();
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });
  tearDown(() {
    CacheKeyProvider.debugReset();
    CrashReporter.debugSentrySink = null;
  });

  group('A1/iOS Sentinel gesetzt, aber NICHTS zu verwaisen', () {
    test(
        'kein einziger EATOVA1-Slot: der Bootstrap praegt sofort neu '
        '(der Abbruchgrund existiert nicht)', () async {
      await _seedPrefs(<String, Object>{
        CacheKeyProvider.dekProvisionedKey: true,
        // Plaintext from an old install migrates cleanly under ANY DEK.
        'eatova.v1.profile.user-1': '{"weight_kg":82}',
      });
      final keyStore = _AbsentDekKeyStore();

      final dek = await CacheKeyProvider.obtain(keyStore: keyStore);

      expect(dek, isNotNull,
          reason: 'Ohne EATOVA1-Slot gibt es nichts, was ein frischer DEK '
              'unlesbar machen koennte.');
      expect(keyStore.writes, 1);
      expect(await CacheKeyProvider.consumeCacheResetNotice(), isFalse,
          reason: 'Es ging nichts verloren — kein Nutzerhinweis.');
    });

    test('gefahrloses Praegen setzt den Strike-Zaehler zurueck', () async {
      await _seedPrefs(<String, Object>{
        CacheKeyProvider.dekProvisionedKey: true,
        CacheKeyProvider.dekVanishStrikesKey: 2,
      });

      expect(await CacheKeyProvider.obtain(keyStore: _AbsentDekKeyStore()),
          isNotNull);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(CacheKeyProvider.dekVanishStrikesKey) ?? 0, 0);
    });
  });

  group('A1/iOS Sentinel gesetzt UND Blobs da', () {
    test('erster Start bricht weiterhin ab und laesst die Blobs liegen',
        () async {
      await _seedPrefs(<String, Object>{
        CacheKeyProvider.dekProvisionedKey: true,
        _blobKey: _deadBlob,
      });
      final keyStore = _AbsentDekKeyStore();

      expect(await CacheKeyProvider.obtain(keyStore: keyStore), isNull,
          reason: 'Solange das Budget laeuft, bleibt der Schutz aus Welle 1.');
      expect(keyStore.writes, 0);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(_blobKey), _deadBlob);
      expect(prefs.getInt(CacheKeyProvider.dekVanishStrikesKey), 1);
    });

    test(
        'EIN Strike pro Prozess, nicht pro obtain()-Aufruf '
        '(Boot + Logout rufen beide auf)', () async {
      await _seedPrefs(<String, Object>{
        CacheKeyProvider.dekProvisionedKey: true,
        _blobKey: _deadBlob,
      });
      final keyStore = _AbsentDekKeyStore();

      // `obtain` does not memoise a failed bootstrap, so this really reruns.
      expect(await CacheKeyProvider.obtain(keyStore: keyStore), isNull);
      expect(await CacheKeyProvider.obtain(keyStore: keyStore), isNull);
      expect(await CacheKeyProvider.obtain(keyStore: keyStore), isNull);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(CacheKeyProvider.dekVanishStrikesKey), 1,
          reason: 'Sonst waere das Budget nach EINER Session aufgebraucht und '
              'der Zaehler zaehlte obtain()-Aufrufe statt App-Starts.');
    });

    test(
        'nach ${CacheKeyProvider.vanishStrikeBudget} Starts gibt der Bootstrap '
        'auf: tote Blobs weg, frischer DEK, App laeuft wieder mit Cache',
        () async {
      await _seedPrefs(<String, Object>{
        CacheKeyProvider.dekProvisionedKey: true,
        _blobKey: _deadBlob,
        'eatova.v1.logged_meals.user-1': '${cacheCipherMagic}bm9jaCB0b3Rlcg==',
      });
      final keyStore = _AbsentDekKeyStore();

      for (var start = 1;
          start < CacheKeyProvider.vanishStrikeBudget;
          start++) {
        _restartApp();
        expect(await CacheKeyProvider.obtain(keyStore: keyStore), isNull,
            reason: 'Start $start liegt noch im Budget.');
      }

      _restartApp();
      final recovered = await CacheKeyProvider.obtain(keyStore: keyStore);

      expect(recovered, isNotNull,
          reason: 'Der DEK kann nach einem iOS-Restore NICHT zurueckkommen '
              '(ThisDeviceOnly ist in keinem Backup). Die Blobs festzuhalten '
              'schuetzt nichts und blockiert jede kuenftige Outbox.');
      expect(recovered, hasLength(AesGcmCacheCipher.dekLengthBytes));
      expect(keyStore.writes, 1);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey(_blobKey), isFalse,
          reason: 'Tote Ciphertexte sind unentschluesselbare PII — raeumen '
              'statt neun _onUndecryptable-Reports pro Kaltstart zu erzeugen.');
      expect(prefs.containsKey('eatova.v1.logged_meals.user-1'), isFalse);
      expect(prefs.getInt(CacheKeyProvider.dekVanishStrikesKey) ?? 0, 0,
          reason: 'Der Zaehler startet fuer den naechsten Vorfall bei null.');
    });

    test('Aufgeben laesst Klartext-Slots einer Alt-Installation stehen',
        () async {
      const legacyKey = 'eatova.v1.profile.user-1';
      await _seedPrefs(<String, Object>{
        CacheKeyProvider.dekProvisionedKey: true,
        CacheKeyProvider.dekVanishStrikesKey:
            CacheKeyProvider.vanishStrikeBudget - 1,
        _blobKey: _deadBlob,
        legacyKey: '{"weight_kg":82}',
        'sb-eatova-auth-token': '{"access_token":"xyz"}',
      });

      expect(await CacheKeyProvider.obtain(keyStore: _AbsentDekKeyStore()),
          isNotNull);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(legacyKey), '{"weight_kg":82}',
          reason: 'Klartext ist unter dem frischen DEK weiter lesbar und wird '
              'beim naechsten Read migriert — er darf nicht mitgeraeumt werden.');
      expect(prefs.getString('sb-eatova-auth-token'), isNotNull,
          reason: 'Nur EATOVA1-Werte gehoeren uns. Die gotrue-Session liegt im '
              'selben SharedPreferences-Namensraum.');
      expect(prefs.containsKey(_blobKey), isFalse);
    });

    test('erfolgreicher DEK-Read setzt den Strike-Zaehler zurueck', () async {
      await _seedPrefs(<String, Object>{
        CacheKeyProvider.dekProvisionedKey: true,
        CacheKeyProvider.dekVanishStrikesKey: 2,
        _blobKey: _deadBlob,
      });
      final keyStore = _AbsentDekKeyStore()
        ..data[CacheKeyProvider.dekStorageKey] = base64.encode(_hardCodedDek);

      expect(await CacheKeyProvider.obtain(keyStore: keyStore), _hardCodedDek);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(CacheKeyProvider.dekVanishStrikesKey) ?? 0, 0,
          reason: 'Sonst summieren sich unabhaengige Vorfaelle ueber Monate '
              'und irgendwann gibt EIN Aussetzer sofort auf.');
    });

    test('Probe faellt aus -> fail closed (Abbruch), Budget laeuft trotzdem',
        () async {
      await _seedPrefs(<String, Object>{
        CacheKeyProvider.dekProvisionedKey: true,
      });
      final keyStore = _AbsentDekKeyStore();

      expect(
        await CacheKeyProvider.obtain(
            keyStore: keyStore, probe: _FailingProbe()),
        isNull,
        reason: 'Wer nicht sagen kann, ob Blobs da sind, darf nicht praegen.',
      );
      expect(keyStore.writes, 0);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(CacheKeyProvider.dekVanishStrikesKey), 1,
          reason: 'Auch der Blindflug muss enden — sonst ist der fail-closed '
              'Zweig selbst wieder die dauerhafte Sackgasse.');
    });
  });

  group('A1/iOS Nutzerhinweis', () {
    test('Aufgeben hinterlegt genau EINEN konsumierbaren Hinweis', () async {
      await _seedPrefs(<String, Object>{
        CacheKeyProvider.dekProvisionedKey: true,
        CacheKeyProvider.dekVanishStrikesKey:
            CacheKeyProvider.vanishStrikeBudget - 1,
        _blobKey: _deadBlob,
      });

      expect(await CacheKeyProvider.obtain(keyStore: _AbsentDekKeyStore()),
          isNotNull);

      expect(await CacheKeyProvider.consumeCacheResetNotice(), isTrue,
          reason: 'Ein stiller Neuanfang laesst den Nutzer im Glauben, sein '
              'Offline-Tagebuch sei noch da.');
      expect(await CacheKeyProvider.consumeCacheResetNotice(), isFalse,
          reason: 'Der Hinweis wird beim Lesen geloescht — einmal zeigen.');
    });

    test('ein Abbruch im Budget hinterlegt KEINEN Hinweis', () async {
      await _seedPrefs(<String, Object>{
        CacheKeyProvider.dekProvisionedKey: true,
        _blobKey: _deadBlob,
      });

      expect(
          await CacheKeyProvider.obtain(keyStore: _AbsentDekKeyStore()), isNull);

      expect(await CacheKeyProvider.consumeCacheResetNotice(), isFalse,
          reason: 'Noch ist nichts aufgegeben, der naechste Start versucht es '
              'wieder — nichts zu melden.');
    });
  });

  group('A1/iOS Crash-Report', () {
    test('Abbruch meldet cache_dek_vanished, Aufgeben cache_dek_given_up',
        () async {
      final contexts = <String?>[];
      final errors = <Object>[];
      CrashReporter.debugSentrySink = (error, stack, context) {
        contexts.add(context);
        errors.add(error);
      };

      await _seedPrefs(<String, Object>{
        CacheKeyProvider.dekProvisionedKey: true,
        _blobKey: _deadBlob,
      });
      final keyStore = _AbsentDekKeyStore();

      for (var start = 1;
          start < CacheKeyProvider.vanishStrikeBudget;
          start++) {
        _restartApp();
        await CacheKeyProvider.obtain(keyStore: keyStore);
      }
      _restartApp();
      await CacheKeyProvider.obtain(keyStore: keyStore);
      // capture() runs unawaited.
      await Future<void>.delayed(Duration.zero);

      expect(contexts.where((c) => c == 'cache_dek_vanished'),
          hasLength(CacheKeyProvider.vanishStrikeBudget - 1));
      expect(contexts.where((c) => c == 'cache_dek_given_up'), hasLength(1));
      // No ciphertext, no slot value in the report.
      for (final e in errors) {
        expect(e.toString(), isNot(contains(_deadBlob)));
      }
    });
  });
}
