import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:eatova/src/services/crash_reporter.dart';
import 'package:eatova/src/services/secure_cache_store.dart';

// Review 2026-08-19, Fund 3: der WERFENDE DEK-Read hatte weder Budget noch
// Telemetrie.
//
// Der Zweig setzt einen voruebergehenden Fehler voraus ("naechster Start
// versucht neu"). Ein nach einem System-Update beschaedigter
// Keystore-Wrapping-Key ist aber dauerhaft: dann liefert `obtain()` in JEDER
// Session null, `LocalCache.create` ebenso — kein Cache, keine persistierte
// Outbox, kein Offline-Tagebuch, und nirgends steht etwas davon.
//
// Diese Datei haelt den Ausweg fest: derselbe Zaehler und dasselbe Budget wie
// beim verschwundenen DEK, eine Meldung pro Vorfall, und nach
// [CacheKeyProvider.vanishStrikeBudget] Starts ein definierter Endzustand
// (frisch praegen, tote Ciphertexte raeumen, Nutzerhinweis).

/// Keystore, dessen `read` die naechsten [kaputteStarts] Male wirft und danach
/// normal antwortet. Der Write bleibt funktionsfaehig — genau das ist der
/// Zustand eines beschaedigten EINTRAGS (im Unterschied zu einem komplett
/// toten Keystore, den [_TotalTotKeyStore] modelliert).
class _WerfenderReadKeyStore implements SecureKeyStore {
  _WerfenderReadKeyStore({this.kaputteStarts = 1 << 30});

  final int kaputteStarts;
  final Map<String, String> data = <String, String>{};
  int reads = 0;
  int writes = 0;

  @override
  Future<String?> read(String key) async {
    reads++;
    if (reads <= kaputteStarts) {
      throw StateError('Keystore-Eintrag nicht entpackbar');
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

/// Keystore, bei dem AUCH der Write scheitert.
class _TotalTotKeyStore implements SecureKeyStore {
  @override
  Future<String?> read(String key) async => throw StateError('keystore kaputt');

  @override
  Future<void> write(String key, String value) async =>
      throw StateError('keystore kaputt');

  @override
  Future<void> delete(String key) async => throw StateError('keystore kaputt');
}

const String _blobKey = 'eatova.v1.outbox.user-1';
const String _deadBlob = '${cacheCipherMagic}dGhpcyBpcyB0b3Q=';

/// 32 Byte, hart kodiert — der Test darf NICHT an den OS-Keystore.
final Uint8List _hardCodedDek = Uint8List.fromList(
  List<int>.generate(
      AesGcmCacheCipher.dekLengthBytes, (i) => (i * 7 + 11) & 0xFF),
);

/// Seed + frische Instanz. `setMockInitialValues` setzt den internen Completer
/// zurueck, ein vorher gehaltenes [SharedPreferences] waere danach veraltet.
Future<SharedPreferences> _seedPrefs(Map<String, Object> values) async {
  SharedPreferences.setMockInitialValues(values);
  return SharedPreferences.getInstance();
}

/// Ein neuer App-Start: Memoisierung UND Pro-Prozess-Strike sind weg,
/// SharedPreferences (Sentinel, Strikes, Blobs) ueberlebt.
void _restartApp() => CacheKeyProvider.debugReset();

/// `capture` laeuft `unawaited` — eine Microtask abwarten.
Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final kontexte = <String?>[];

  setUp(() {
    kontexte.clear();
    CacheKeyProvider.debugReset();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    CrashReporter.debugSentrySink = (error, stack, context) {
      kontexte.add(context);
    };
  });
  tearDown(() {
    CacheKeyProvider.debugReset();
    CrashReporter.debugSentrySink = null;
  });

  group('Werfender DEK-Read: Budget und Meldung', () {
    test('erster Start gibt auf, ueberschreibt nichts — zaehlt und meldet aber',
        () async {
      await _seedPrefs(<String, Object>{
        CacheKeyProvider.dekProvisionedKey: true,
        _blobKey: _deadBlob,
      });
      final keyStore = _WerfenderReadKeyStore();

      expect(await CacheKeyProvider.obtain(keyStore: keyStore), isNull,
          reason: 'Ein Wurf ist kein "gibt es nicht" — der vorhandene Key darf '
              'nicht ueberschrieben werden.');
      expect(keyStore.writes, 0);
      await _settle();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(CacheKeyProvider.dekVanishStrikesKey), 1,
          reason: 'Ohne Zaehler hat der Zustand kein Ende.');
      expect(kontexte, <String?>['cache_dek_unreadable'],
          reason: 'Ohne Meldung merkt niemand, dass der Cache tot ist.');
      expect(prefs.getString(_blobKey), _deadBlob);
    });

    test('EIN Strike pro Prozess, nicht pro obtain()-Aufruf', () async {
      await _seedPrefs(<String, Object>{
        CacheKeyProvider.dekProvisionedKey: true,
        _blobKey: _deadBlob,
      });
      final keyStore = _WerfenderReadKeyStore();

      // `obtain` memoisiert einen gescheiterten Bootstrap nicht — Boot und
      // Logout laufen beide wirklich durch.
      expect(await CacheKeyProvider.obtain(keyStore: keyStore), isNull);
      expect(await CacheKeyProvider.obtain(keyStore: keyStore), isNull);
      await _settle();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(CacheKeyProvider.dekVanishStrikesKey), 1,
          reason: 'Sonst waere das Budget nach EINER Session aufgebraucht.');
      expect(kontexte, hasLength(1),
          reason: 'Und der Report-Feed haette zwei identische Eintraege.');
    });

    test('ein spaeter gelungener Read raeumt den Zaehler ab', () async {
      await _seedPrefs(<String, Object>{
        CacheKeyProvider.dekProvisionedKey: true,
        _blobKey: _deadBlob,
      });
      // Erster Start wirft, zweiter Start liefert den Key wieder — genau der
      // transiente Fall, gegen den das Budget gebaut ist.
      final keyStore = _WerfenderReadKeyStore(kaputteStarts: 1)
        ..data[CacheKeyProvider.dekStorageKey] = base64.encode(_hardCodedDek);

      expect(await CacheKeyProvider.obtain(keyStore: keyStore), isNull);
      _restartApp();
      expect(await CacheKeyProvider.obtain(keyStore: keyStore), _hardCodedDek);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(CacheKeyProvider.dekVanishStrikesKey) ?? 0, 0,
          reason: 'Sonst summieren sich unabhaengige Aussetzer ueber Monate '
              'und irgendwann gibt EIN einzelner sofort auf.');
    });
  });

  group('Werfender DEK-Read: definierter Endzustand', () {
    test(
        'nach ${CacheKeyProvider.vanishStrikeBudget} Starts: frischer DEK, '
        'tote Blobs weg, Nutzerhinweis', () async {
      await _seedPrefs(<String, Object>{
        CacheKeyProvider.dekProvisionedKey: true,
        _blobKey: _deadBlob,
        'eatova.v1.logged_meals.user-1': '${cacheCipherMagic}bm9jaCB0b3Rlcg==',
        // Fremder Namensraum: gehoert uns nicht, bleibt liegen.
        'sb-eatova-auth-token': '{"access_token":"xyz"}',
      });
      final keyStore = _WerfenderReadKeyStore();

      for (var start = 1;
          start < CacheKeyProvider.vanishStrikeBudget;
          start++) {
        _restartApp();
        expect(await CacheKeyProvider.obtain(keyStore: keyStore), isNull,
            reason: 'Start $start liegt noch im Budget.');
      }

      _restartApp();
      final frisch = await CacheKeyProvider.obtain(keyStore: keyStore);
      await _settle();

      expect(frisch, isNotNull,
          reason: 'Ein dauerhaft unlesbarer Keystore-Eintrag kommt nicht '
              'zurueck — ohne Endzustand bliebe die App fuer immer ohne Cache '
              'und ohne persistierte Outbox.');
      expect(frisch, hasLength(AesGcmCacheCipher.dekLengthBytes));
      expect(keyStore.writes, 1);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey(_blobKey), isFalse,
          reason: 'Unter dem frischen DEK sind die alten Blobs endgueltig '
              'unlesbare Gesundheitsdaten.');
      expect(prefs.containsKey('eatova.v1.logged_meals.user-1'), isFalse);
      expect(prefs.getString('sb-eatova-auth-token'), isNotNull);
      expect(prefs.getInt(CacheKeyProvider.dekVanishStrikesKey) ?? 0, 0);
      expect(kontexte.last, 'cache_dek_given_up');
      expect(await CacheKeyProvider.consumeCacheResetNotice(), isTrue,
          reason: 'Ein stiller Neuanfang laesst den Nutzer im Glauben, sein '
              'Offline-Tagebuch sei noch da.');
    });

    test('scheitert auch der Write, bleibt alles liegen', () async {
      await _seedPrefs(<String, Object>{
        CacheKeyProvider.dekProvisionedKey: true,
        CacheKeyProvider.dekVanishStrikesKey:
            CacheKeyProvider.vanishStrikeBudget - 1,
        _blobKey: _deadBlob,
      });

      expect(await CacheKeyProvider.obtain(keyStore: _TotalTotKeyStore()),
          isNull);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(_blobKey), _deadBlob,
          reason: 'Erst praegen, DANN raeumen: solange der alte Key nicht '
              'ersetzt ist, koennten die Blobs noch lesbar sein.');
      expect(await CacheKeyProvider.consumeCacheResetNotice(), isFalse,
          reason: 'Es ist nichts aufgegeben worden — nichts zu melden.');
      expect(prefs.getInt(CacheKeyProvider.dekVanishStrikesKey),
          CacheKeyProvider.vanishStrikeBudget,
          reason: 'Der Zaehler bleibt oben, der naechste Start versucht den '
              'Endzustand erneut.');
    });
  });
}
