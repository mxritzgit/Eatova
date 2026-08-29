import 'dart:convert';
import 'dart:io' show FileSystemException;
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

  // Review 2026-08-29, P3-02: the group above is the store's half — the slot
  // survives. This one is the CACHE's half: the reader must not read that
  // survival as "slot empty", or the brake in `_persistOutbox` /
  // `signOutCleanup` never engages and the surviving slot is overwritten or
  // deleted anyway. `getString` alone cannot tell the two apart (both `null`),
  // so the counter-check asks the RAW storage.
  group('…OrThrow: „nicht ausfuehrbar" ist nicht „leer"', () {
    // TWO scripted failures throughout: memory pressure lasts longer than one
    // read, and the old counter-check went through the decorator a second time
    // — one failure would have been caught by that second, then successful
    // read. The dangerous window is exactly the one that covers both.
    test('readOutboxOrThrow meldet den belegten, unlesbaren Slot', () async {
      final (raw, cipher, store) = await _befuellt();
      cipher.decryptErrors
        ..add(IsolateSpawnException('kein Speicher'))
        ..add(IsolateSpawnException('kein Speicher'));
      final cache = LocalCache(store, 'user-1');

      await expectLater(
          cache.readOutboxOrThrow(), throwsA(isA<UnreadableCacheSlot>()),
          reason: 'nur ein Throw setzt _outboxHydrationFailed — ohne ihn '
              'ueberschreibt der naechste Enqueue den Blob');
      expect(raw.snapshot.containsKey(_key), isTrue);
    });

    test('readPendingStatsDeltasOrThrow ebenso', () async {
      final raw = InMemoryKeyValueStore();
      final cipher = _ScriptedCipher('dek-a');
      final store = EncryptedKeyValueStore(raw, cipher);
      await LocalCache(store, 'user-1')
          .writePendingStatsDeltas(meals: 3, weightLogs: 0);
      cipher.decryptErrors
        ..add(const OutOfMemoryError())
        ..add(const OutOfMemoryError());

      final lesen = LocalCache(store, 'user-1').readPendingStatsDeltasOrThrow();
      await expectLater(lesen, throwsA(isA<UnreadableCacheSlot>()));
      expect(raw.snapshot.containsKey('eatova.v1.pending_stats.user-1'), isTrue,
          reason: 'an dem Slot haengen Lebenszeit-Zaehler und Streak-Basis');
    });

    test('gemeldet werden nur Slot-Name und Grund, nie Schluessel oder Inhalt',
        () async {
      final (_, cipher, store) = await _befuellt();
      cipher.decryptErrors
        ..add(RemoteError('kaputt', ''))
        ..add(RemoteError('kaputt', ''));

      final fehler = await LocalCache(store, 'user-1')
          .readOutboxOrThrow()
          .then<Object?>((_) => null, onError: (Object e) => e);

      expect(fehler.toString(), contains('outbox'));
      expect(fehler.toString(), isNot(contains('user-1')));
      expect(fehler.toString(), isNot(contains('mealInsert')));
    });

    test('Gegenprobe: der geraeumte Slot gilt weiter als leer', () async {
      // A proven ciphertext problem clears the slot on read, so nothing is
      // left an overwrite could lose — this must NOT become a read error.
      final (raw, cipher, store) = await _befuellt();
      cipher.decryptErrors
          .add(InvalidCipherTextException('mac check in GCM failed'));

      expect(await LocalCache(store, 'user-1').readOutboxOrThrow(), isNull);
      expect(raw.snapshot.containsKey(_key), isFalse);
    });

    test('Gegenprobe: ein nie beschriebener Slot ist leer, kein Fehler',
        () async {
      final store = EncryptedKeyValueStore(
          InMemoryKeyValueStore(), _ScriptedCipher('dek-a'));

      final cache = LocalCache(store, 'user-1');
      expect(await cache.readOutboxOrThrow(), isNull);
      expect(await cache.readPendingStatsDeltasOrThrow(), isNull);
    });
  });

  // Review 2026-08-29, P3-02c: the group above proves the slot is REPORTED.
  // What it could not say is WHY — `getString` knew whether it had hit
  // `_onCipherUnavailable` (transient, bytes intact) or had handed over a
  // plaintext the caller could not parse (provably broken), and threw the
  // information away. The repair path therefore needed an attempt cap, and
  // attempts are cheap: three logged meals and the protection was gone.
  group('P3-02c: der Fund traegt jetzt seine Fehlerart', () {
    /// Runs [lesen] and returns the [UnreadableCacheSlot] it threw.
    Future<UnreadableCacheSlot> fange(Future<Object?> Function() lesen) async {
      final fehler = await lesen()
          .then<Object?>((_) => null, onError: (Object e) => e);
      expect(fehler, isA<UnreadableCacheSlot>(),
          reason: 'Vorbedingung: der Slot muss ueberhaupt als belegt gemeldet '
              'werden.');
      return fehler! as UnreadableCacheSlot;
    }

    test('nicht ausfuehrbare Entschluesselung ist transient', () async {
      final (raw, cipher, store) = await _befuellt();
      cipher.decryptErrors
        ..add(IsolateSpawnException('kein Speicher'))
        ..add(IsolateSpawnException('kein Speicher'));

      final fund =
          await fange(LocalCache(store, 'user-1').readOutboxOrThrow);

      expect(fund.transient, isTrue,
          reason: 'Die Bytes sind unversehrt, nur der Isolate-Hop fiel aus — '
              'ein spaeterer Read gelingt, also darf der Reparaturpfad den '
              'Slot unbegrenzt schuetzen.');
      expect(raw.snapshot.containsKey(_key), isTrue);
    });

    test('erfolgreicher Decrypt mit unparsebarem Klartext ist NICHT transient',
        () async {
      final raw = InMemoryKeyValueStore();
      final store = EncryptedKeyValueStore(raw, _ScriptedCipher('dek-a'));
      // Decrypts cleanly, but is no JSON object: the CONTENT is broken, and no
      // retry in the world changes that.
      await store.setString(_key, 'kein json');

      final fund =
          await fange(LocalCache(store, 'user-1').readOutboxOrThrow);

      expect(fund.transient, isFalse,
          reason: 'Nachweislich kaputt — der Reparaturpfad darf sofort '
              'aufgeben statt drei Versuche zu verbrennen.');
      expect(raw.snapshot.containsKey(_key), isTrue,
          reason: 'Gemeldet, nicht geraeumt: das Wegwerfen entscheidet der '
              'Aufrufer.');
    });

    test('dasselbe fuer die pending-stats-Deltas', () async {
      final store = EncryptedKeyValueStore(
          InMemoryKeyValueStore(), _ScriptedCipher('dek-a'));
      await store.setString('eatova.v1.pending_stats.user-1', '[1,2]');

      final fund = await fange(
          LocalCache(store, 'user-1').readPendingStatsDeltasOrThrow);

      expect(fund.transient, isFalse);
      expect(fund.slot, 'pending_stats');
    });

    test('ein Store-Fehler beim Nachsehen gilt als transient (fail-closed)',
        () async {
      final store = _WerfenderRohSpeicher();
      await store.setString(_key, 'egal');
      store.wirftBeimLesen = true;

      final fund =
          await fange(LocalCache(store, 'user-1').readOutboxOrThrow);

      expect(fund.transient, isTrue,
          reason: 'Wer nicht weiss, ob der Slot kaputt ist, darf ihn nicht '
              'aufgeben — sonst ueberschreibt eine klemmende Platte die '
              'Outbox.');
    });

    test('ohne Verschluesselungs-Dekorator ist unlesbarer Inhalt endgueltig',
        () async {
      // No cipher, hence no transient decryption failure: what is there is
      // exactly what the reader could not parse.
      final cache = LocalCache(
        InMemoryKeyValueStore(<String, String>{_key: 'kein json'}),
        'user-1',
      );

      final fund = await fange(cache.readOutboxOrThrow);

      expect(fund.transient, isFalse);
    });

    test('der Grund bleibt frei von Schluessel und Inhalt', () async {
      final store = EncryptedKeyValueStore(
          InMemoryKeyValueStore(), _ScriptedCipher('dek-a'));
      await store.setString(_key, '{"items":"mealInsert-geheim"}');

      final fund =
          await fange(LocalCache(store, 'user-1').readOutboxOrThrow);

      expect(fund.toString(), contains('outbox'));
      expect(fund.toString(), isNot(contains('user-1')));
      expect(fund.toString(), isNot(contains('mealInsert')));
    });
  });
}

/// Raw store whose READ throws on demand — the "storage cannot answer" case
/// the counter-check has to treat as transient.
class _WerfenderRohSpeicher implements KeyValueStore {
  final Map<String, String> _daten = <String, String>{};
  bool wirftBeimLesen = false;

  @override
  Future<String?> getString(String key) async {
    if (wirftBeimLesen) throw const FileSystemException('Platte klemmt');
    return _daten[key];
  }

  @override
  Future<void> setString(String key, String value) async => _daten[key] = value;

  @override
  Future<void> remove(String key) async => _daten.remove(key);
}
