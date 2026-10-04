import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/services/crash_reporter.dart';
import 'package:eatova/src/services/durable_cache_store.dart';
import 'package:eatova/src/services/secure_cache_store.dart';
import 'package:eatova/src/services/sqlite_key_value_store.dart';

// SEC/W7a: plaintext never enters the encrypted cache through a read.
//
// Legacy prefs plaintext is adopted exactly once: the SQLite import in
// `migrateDurableCache` encrypts it while
// `CacheKeyProvider.plaintextMigrationClosedKey` is unset and writes the
// marker in the same batch (import cases: durable_cache_migration_test.dart).
// The store it returns — the one `LocalCache.create` hands out — treats every
// magic-less slot as untrusted: dropped, purged and reported, never adopted.
//
// Every test here boots through `migrateDurableCache` on a real SQLite file;
// only the keystore and the old prefs are fakes.
//
// Limit of the promise (hence the last test): whoever can write the database
// file can also delete it. The rejection does not stop an attacker with write
// access, it makes them visible — and that visibility must hold even after a
// broken ciphertext was already reported in the same process.

/// Keystore that keeps the DEK across a simulated restart — the normal case
/// on a healthy device.
class _MemoryKeyStore implements SecureKeyStore {
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

/// The SharedPreferences of a pre-SQLite install.
class _OldPrefs implements LegacyCacheSource {
  final Map<String, String> slots = <String, String>{};

  @override
  Future<Map<String, String>> readSlots() async => Map.of(slots);

  @override
  Future<Map<String, String>> readKeyMetadata() async => <String, String>{};

  @override
  Future<void> removeSlots(Map<String, String> expectedValues) async {
    for (final key in expectedValues.keys) {
      slots.remove(key);
    }
  }
}

const String _slot = 'eatova.v1.outbox.user-1';

/// The payload at stake: an outbox of unacknowledged writes — planted in the
/// attack case, real user data in the legacy case.
const String _plaintext =
    '{"items":[{"op":"add_meal","kcal":820,"note":"Kebab"}]}';

/// Slots WITH magic whose tag does not match — the everyday case after a
/// keystore reset. Long enough for nonce+tag so the check fails at GCM
/// authentication, not already at the frame.
final String _toterCiphertext =
    '$cacheCipherMagic${base64.encode(List<int>.filled(48, 7))}';

const String _toterSlot = 'eatova.v1.profile.user-1';
const String _zweiterToterSlot = 'eatova.v1.weight_log.user-1';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  late SqliteKeyValueStore database;
  late _MemoryKeyStore keyStore;
  late _OldPrefs oldPrefs;

  /// A production boot: what `LocalCache.create` runs via `DurableCacheStore`.
  Future<EncryptedKeyValueStore> boot() async {
    final store = await migrateDurableCache(
      database: database,
      legacySource: oldPrefs,
      keyStore: keyStore,
    );
    expect(store, isNotNull,
        reason: 'Der Fake-Keystore liefert immer einen DEK.');
    return store!;
  }

  /// A fresh app start: memoization is gone, the database and the OS
  /// keystore (DEK) survive.
  Future<EncryptedKeyValueStore> restartApp() {
    CacheKeyProvider.debugReset();
    return boot();
  }

  setUp(() async {
    CacheKeyProvider.debugReset();
    // The one-shot report counters are per process; a test run simulates many
    // processes in one.
    EncryptedKeyValueStore.debugResetReportGuards();
    directory = await Directory.systemTemp.createTemp('eatova_plaintext_');
    database = await SqliteKeyValueStore.open('${directory.path}/cache.sqlite');
    keyStore = _MemoryKeyStore();
    oldPrefs = _OldPrefs();
  });
  tearDown(() async {
    CacheKeyProvider.debugReset();
    EncryptedKeyValueStore.debugResetReportGuards();
    CrashReporter.debugSentrySink = null;
    await database.close();
    await directory.delete(recursive: true);
  });

  test(
      'der verworfene Klartext-Slot wird als ExpiredPlaintextCacheSlot '
      'gemeldet — ohne Key und ohne Wert', () async {
    final reported = <Object>[];
    final contexts = <String?>[];
    CrashReporter.debugSentrySink = (error, stack, context) {
      reported.add(error);
      contexts.add(context);
    };

    await boot();
    await database.setString(_slot, _plaintext);
    await (await restartApp()).getString(_slot);
    // capture() runs unawaited.
    await Future<void>.delayed(Duration.zero);

    expect(contexts, ['cache_decrypt'],
        reason: 'Kein eigener Pfad — dieselbe Meldung wie fuer jeden anderen '
            'unentschluesselbaren Slot.');
    expect(reported.single.toString(), contains('ExpiredPlaintextCacheSlot'),
        reason: 'Der einzige Fall hier, der auf einen fremden SCHREIBZUGRIFF '
            'hindeuten kann, muss sich in Sentry von einem kaputten '
            'Ciphertext unterscheiden lassen.');
    expect(reported.single.toString(), isNot(contains('Kebab')));
    expect(reported.single.toString(), isNot(contains('user-1')),
        reason: 'Das User-Segment wird redigiert.');
  });

  test('der Import schliesst den Klartext-Pfad fuer spaetere Starts', () async {
    oldPrefs.slots[_slot] = _plaintext;

    final first = await boot();

    expect(CacheKeyProvider.legacyPlaintextAccepted, isTrue,
        reason: 'Massgeblich ist der Marker-Stand VOR dem Import, sonst '
            'verlieren Bestandsnutzer beim Update ihre nicht quittierten '
            'Writes.');
    expect(await first.getString(_slot), _plaintext);
    expect(await database.getString(_slot), startsWith(cacheCipherMagic));
    expect(await database.getString(_slot), isNot(contains('Kebab')));

    await restartApp();
    expect(CacheKeyProvider.legacyPlaintextAccepted, isFalse,
        reason: 'Der Import setzt den Marker im selben Batch — danach darf '
            'kein Start mehr Klartext uebernehmen.');
  });

  test(
      'nach dem Import wird ein untergeschobener Klartext-Slot verworfen '
      'statt uebernommen', () async {
    const regulaer = 'eatova.v1.logged_meals.user-1';
    final first = await boot();
    await first.setString(regulaer, '{"items":[]}');

    // Same DEK, but the plaintext is planted, not inherited.
    await database.setString(_slot, _plaintext);
    final store = await restartApp();

    expect(await store.getString(_slot), isNull,
        reason: 'Ohne Magic gibt es weder GCM-Tag noch AAD — der Wert darf '
            'nicht als Outbox in die Sync-Schleife gelangen.');
    expect(await database.getString(_slot), isNull,
        reason: 'Behandlung wie ein unentschluesselbarer Slot: raeumen.');
    expect(keyStore.writes, 1, reason: 'Kein zweiter DEK.');

    // A migration would run through the write chain, so wait for it or the
    // check merely proves it has not finished yet.
    await Future<void>.delayed(Duration.zero);
    expect(await database.getString(_slot), isNull,
        reason: 'Ein untergeschobener Wert darf auch nicht nachtraeglich '
            'zu einem gueltig signierten Ciphertext aufgewertet werden.');

    expect(await store.getString(regulaer), '{"items":[]}',
        reason: 'Die Ablehnung betrifft ausschliesslich magic-lose Slots — '
            'verschluesselte bleiben ueber den Neustart lesbar.');
  });

  group('Sichtbarkeit statt Garantie', () {
    test(
        'der verworfene Klartext-Slot wird auch gemeldet, wenn vorher schon '
        'ein toter Ciphertext gemeldet wurde', () async {
      final reported = <String>[];
      CrashReporter.debugSentrySink = (error, stack, context) {
        reported.add(error.toString());
      };
      await boot();

      // The cache holds two dead ciphertexts (the keystore-reset case) AND
      // the planted plaintext.
      await database.setString(_toterSlot, _toterCiphertext);
      await database.setString(_zweiterToterSlot, _toterCiphertext);
      await database.setString(_slot, _plaintext);
      final store = await restartApp();

      expect(await store.getString(_toterSlot), isNull);
      expect(await store.getString(_zweiterToterSlot), isNull);
      expect(await store.getString(_slot), isNull);
      // capture() runs unawaited.
      await Future<void>.delayed(Duration.zero);

      expect(reported.where((e) => e.contains('ExpiredPlaintextCacheSlot')),
          hasLength(1),
          reason: 'Die Ablehnung haelt einen Angreifer mit Schreibzugriff '
              'nicht auf — sie macht ihn sichtbar. Ein gemeinsamer '
              'Ein-Schuss-Zaehler wuerde genau dieses Signal verschlucken, '
              'sobald irgendein Slot vorher am Tag gescheitert ist.');
      expect(reported, hasLength(2),
          reason: 'Ein Schuss je ART, nicht je Slot: der zweite tote '
              'Ciphertext bleibt still, sonst waeren es nach einem '
              'Keystore-Reset neun identische Reports pro Kaltstart.');
    });
  });
}
