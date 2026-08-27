import 'dart:convert';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/api.dart' show InvalidCipherTextException;

import 'package:eatova/src/services/crash_reporter.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/secure_cache_store.dart';

// Review 2026-08-19, finding 2: `_onUndecryptable` cleared the slot on EVERY
// exception from `decrypt()`. But that is `compute(...)`, an isolate spawn per
// read, and a spawn failure says nothing about the ciphertext — it dropped up
// to 500 never-delivered outbox writes.
//
// Clearing is allowed only on a PROVEN ciphertext/format problem:
// InvalidCipherTextException and FormatException, which arise in
// `decryptSync` alone.

/// Cipher in the real wire-format frame with scriptable `decrypt` failures;
/// [salt] stands for the DEK.
class _ScriptedCipher implements CacheCipher {
  _ScriptedCipher(this.salt);

  final String salt;

  /// Each entry makes exactly one `decrypt` call throw; empty = decrypt.
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
    // Like the real cipher: wrong key and wrong AAD both fail the tag check.
    if (parts[0] != salt || parts[1] != key) {
      throw InvalidCipherTextException('mac check in GCM failed');
    }
    return parts[2] as String;
  }
}

const String _key = 'eatova.v1.outbox.user-1';
const String _blob = '{"items":[{"kind":"mealInsert"}]}';

/// `capture` runs `unawaited`, so wait one microtask.
Future<void> _settle() => Future<void>.delayed(Duration.zero);

/// Store with one regularly encrypted slot.
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
    // The rule is one and the same for every transport error; only the
    // exception type differs, so each type runs as its own named case.
    for (final (name, baue) in <(String, Object Function())>[
      ('Isolate-Spawn scheitert', () => IsolateSpawnException('kein Speicher')),
      ('RemoteError', () => RemoteError('kaputt', '')),
      ('OutOfMemoryError', () => const OutOfMemoryError()),
    ]) {
      test('$name: null, Slot bleibt, naechster Read gelingt', () async {
        final (raw, cipher, store) = await _befuellt();
        cipher.decryptErrors.add(baue());

        expect(await store.getString(_key), isNull,
            reason: 'Der Aufrufer sieht dasselbe wie bei leerem Cache.');
        expect(raw.snapshot.containsKey(_key), isTrue,
            reason: 'Ein gescheiterter Isolate-Hop ist KEINE Aussage ueber den '
                'Ciphertext — die bis zu 500 nie zugestellten Writes sind hier '
                'unwiederbringlich.');

        expect(await store.getString(_key), _blob,
            reason: 'Der naechste Read bekommt seinen Isolate; ein geloeschter '
                'Slot kaeme nie zurueck.');
      });
    }

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
    // Both exception types arise in `decryptSync` alone, so both are a proven
    // statement about the ciphertext — and both must clear AND report.
    for (final (name, baue) in <(String, Object Function())>[
      ('InvalidCipherTextException (GCM-Tag)',
          () => InvalidCipherTextException('mac check in GCM failed')),
      ('FormatException (kaputtes base64)',
          () => const FormatException('Cache-Slot ist kein gueltiges base64')),
    ]) {
      test('$name raeumt den Slot und meldet unter cache_decrypt', () async {
        final (raw, cipher, store) = await _befuellt();
        cipher.decryptErrors.add(baue());

        expect(await store.getString(_key), isNull);
        expect(raw.snapshot.containsKey(_key), isFalse,
            reason: 'Derselbe Blob geht auch beim naechsten Start nicht auf — '
                'Wegwerfen IST das Self-Healing.');
        await _settle();
        expect(kontexte, <String?>['cache_decrypt']);
      });
    }

    test('falscher DEK: derselbe Weg ueber den echten Tag-Vergleich', () async {
      // Not scripted: the cipher itself rejects the foreign salt/AAD, exactly
      // as AES-GCM rejects a wrong key.
      final (raw, _, _) = await _befuellt();
      final fremd = EncryptedKeyValueStore(raw, _ScriptedCipher('dek-b'));

      expect(await fremd.getString(_key), isNull);
      expect(raw.snapshot.containsKey(_key), isFalse);
      await _settle();
      expect(kontexte, <String?>['cache_decrypt']);
    });
  });
}
