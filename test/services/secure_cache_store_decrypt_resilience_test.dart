import 'dart:convert';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/api.dart' show InvalidCipherTextException;

import 'package:eatova/src/services/crash_reporter.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/secure_cache_store.dart';

// Review 2026-08-19, Fund 2: `_onUndecryptable` raeumte den Slot bei JEDER
// Ausnahme aus `decrypt()`.
//
// `AesGcmCacheCipher.decrypt` ist aber `compute(...)`, also ein Isolate-Spawn
// pro Read. Scheitert der unter Speicherdruck (IsolateSpawnException,
// RemoteError, OutOfMemoryError), sagt das ueber den Ciphertext gar nichts —
// die Daten wurden trotzdem verworfen. Beim Outbox-Slot sind das bis zu 500
// nie zugestellte Writes, die der Server nicht rekonstruieren kann.
//
// Geraeumt werden darf nur bei NACHGEWIESENEM Ciphertext-/Formatproblem:
// InvalidCipherTextException (GCM-Tag) und FormatException (Magic, base64,
// Laenge, utf8) — beide entstehen ausschliesslich in `decryptSync`.

/// Cipher im echten Wire-Format-Rahmen, deren naechste `decrypt`-Aufrufe sich
/// scripten lassen. [salt] steht fuer „der DEK".
class _ScriptedCipher implements CacheCipher {
  _ScriptedCipher(this.salt);

  final String salt;

  /// Wird von vorne abgearbeitet: jeder Eintrag laesst GENAU einen
  /// `decrypt`-Aufruf werfen. Leer = normal entschluesseln.
  final List<Object> decryptErrors = <Object>[];

  @override
  Future<String> encrypt(String key, String plaintext) async =>
      '$cacheCipherMagic'
      '${base64.encode(utf8.encode(jsonEncode([salt, key, plaintext])))}';

  @override
  Future<String> decrypt(String key, String armored) async {
    if (decryptErrors.isNotEmpty) throw decryptErrors.removeAt(0);
    final parts = jsonDecode(
      utf8.decode(base64.decode(armored.substring(cacheCipherMagic.length))),
    ) as List<dynamic>;
    // Wie die echte Cipher: falscher Key und falsche AAD scheitern beide an
    // der Tag-Pruefung.
    if (parts[0] != salt || parts[1] != key) {
      throw InvalidCipherTextException('mac check in GCM failed');
    }
    return parts[2] as String;
  }
}

const String _key = 'eatova.v1.outbox.user-1';
const String _blob = '{"items":[{"kind":"mealInsert"}]}';

/// `capture` laeuft `unawaited` — eine Microtask abwarten.
Future<void> _settle() => Future<void>.delayed(Duration.zero);

/// Store mit einem regulaer verschluesselten Slot.
Future<(InMemoryKeyValueStore, _ScriptedCipher, EncryptedKeyValueStore)>
    _befuellt() async {
  final raw = InMemoryKeyValueStore();
  final cipher = _ScriptedCipher('dek-a');
  final store = EncryptedKeyValueStore(raw, cipher);
  await store.setString(_key, _blob);
  return (raw, cipher, store);
}

void main() {
  final kontexte = <String?>[];
  final fehler = <Object>[];

  setUp(() {
    kontexte.clear();
    fehler.clear();
    EncryptedKeyValueStore.debugResetReportGuards();
    CrashReporter.debugSentrySink = (error, stack, context) {
      kontexte.add(context);
      fehler.add(error);
    };
  });
  tearDown(() {
    CrashReporter.debugSentrySink = null;
    EncryptedKeyValueStore.debugResetReportGuards();
  });

  group('Fehler AUS DEM TRANSPORT raeumen den Slot nicht', () {
    test('Isolate-Spawn scheitert: null, Slot bleibt, naechster Read gelingt',
        () async {
      final (raw, cipher, store) = await _befuellt();
      cipher.decryptErrors.add(IsolateSpawnException('kein Speicher'));

      expect(await store.getString(_key), isNull,
          reason: 'Der Aufrufer sieht dasselbe wie bei leerem Cache.');
      expect(raw.snapshot.containsKey(_key), isTrue,
          reason: 'Ein gescheiterter Isolate-Spawn ist KEINE Aussage ueber den '
              'Ciphertext — die bis zu 500 nie zugestellten Writes sind hier '
              'unwiederbringlich.');

      expect(await store.getString(_key), _blob,
          reason: 'Der naechste Read bekommt seinen Isolate; ein geloeschter '
              'Slot kaeme nie zurueck.');
    });

    test('RemoteError und OutOfMemoryError ebenso', () async {
      final (raw, cipher, store) = await _befuellt();
      cipher.decryptErrors
        ..add(RemoteError('kaputt', ''))
        ..add(const OutOfMemoryError());

      expect(await store.getString(_key), isNull);
      expect(await store.getString(_key), isNull);
      expect(raw.snapshot.containsKey(_key), isTrue);
      expect(await store.getString(_key), _blob);
    });

    test('gemeldet wird EINMAL pro Prozess, unter eigenem Kontext', () async {
      final (_, cipher, store) = await _befuellt();
      cipher.decryptErrors
        ..add(IsolateSpawnException('kein Speicher'))
        ..add(IsolateSpawnException('kein Speicher'));

      await store.getString(_key);
      await store.getString(_key);
      await _settle();

      expect(kontexte, <String?>['cache_decrypt_unavailable'],
          reason: 'Faellt der Spawn aus, faellt er fuer alle neun Slots aus — '
              'das waeren sonst neun identische Reports pro Kaltstart. Der '
              'eigene Kontext trennt „nicht ausfuehrbar" von „kaputt".');
      expect(fehler.single.toString(), contains('IsolateSpawnException'),
          reason: 'Welcher Fehler den Read verhindert hat, ist die ganze '
              'Diagnose — er muss den Sanitizer ueberleben.');
      expect(fehler.single.toString(), isNot(contains('user-1')));
    });

    test('durch LocalCache hindurch: die Outbox bleibt lesbar', () async {
      final raw = InMemoryKeyValueStore();
      final cipher = _ScriptedCipher('dek-a');
      final store = EncryptedKeyValueStore(raw, cipher);
      await LocalCache(store, 'user-1').writeOutbox(const []);

      cipher.decryptErrors.add(IsolateSpawnException('kein Speicher'));
      final cache = LocalCache(store, 'user-1');

      expect(await cache.readOutbox(), isNull);
      expect(await cache.readOutbox(), isEmpty,
          reason: 'Der Slot war nach dem transienten Fehler noch da.');
    });
  });

  group('Nachgewiesene Ciphertext-Probleme raeumen weiterhin', () {
    test('InvalidCipherTextException (falscher DEK) raeumt den Slot', () async {
      final (raw, _, _) = await _befuellt();
      final fremd = EncryptedKeyValueStore(raw, _ScriptedCipher('dek-b'));

      expect(await fremd.getString(_key), isNull);
      expect(raw.snapshot.containsKey(_key), isFalse,
          reason: 'Derselbe Blob geht auch beim naechsten Start nicht auf — '
              'Wegwerfen IST das Self-Healing.');
      await _settle();
      expect(kontexte, <String?>['cache_decrypt']);
    });

    test('FormatException (kaputtes base64) raeumt den Slot', () async {
      final (raw, cipher, store) = await _befuellt();
      cipher.decryptErrors
          .add(const FormatException('Cache-Slot ist kein gueltiges base64'));

      expect(await store.getString(_key), isNull);
      expect(raw.snapshot.containsKey(_key), isFalse);
    });
  });
}
