import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:eatova/src/services/crash_reporter.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/secure_cache_store.dart';

// SEC/W7a: the plaintext migration path is time-limited — but only closes once
// there is nothing left to inherit.
//
// `EncryptedKeyValueStore.getString` accepts a slot WITHOUT the EATOVA1 magic
// as a migratable legacy value; the marker
// (`CacheKeyProvider.plaintextMigrationClosedKey`) ends that window.
//
// The finding this file guards: the marker is GLOBAL, the slots are PER UID.
// Setting it alongside the DEK sentinel closed the path for every other
// account, so a second user's undelivered writes hit
// `ExpiredPlaintextCacheSlot` without ever getting a chance to migrate. The
// migrating start now actively migrates all inherited slots
// (`EncryptedKeyValueStore.migrateAllLegacySlots`) and sets the marker after.
//
// Both states run through `EncryptedKeyValueStore.create`, the same path as
// `LocalCache.create` in production; only the keystore is a fake.
//
// Limit of the promise (hence the last test): the marker lives in the same
// prefs file as the plaintext slots, so anyone who can write one can delete
// the other. The expiry does not stop an attacker with write access, it makes
// them visible — and that visibility must hold even after a broken ciphertext
// was already reported in the same process.

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

/// Probe whose look at SharedPreferences fails (plugin error).
class _FailingLegacyProbe implements LegacyPlaintextProbe {
  @override
  Future<List<String>> plaintextCacheKeys() async =>
      throw StateError('prefs kaputt');
}

const String _slot = 'eatova.v1.outbox.user-1';

/// Two accounts on the same device — the core of W7a.
const String _slotA = 'eatova.v1.outbox.user-a';
const String _slotB = 'eatova.v1.outbox.user-b';

const String _plaintextA =
    '{"items":[{"op":"add_meal","kcal":410,"note":"Porridge"}]}';

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
const String _zweiterToterSlot = 'eatova.v1.weights.user-1';

/// A fresh app start: memoization is gone, SharedPreferences (sentinel,
/// marker) and the OS keystore (DEK) survive.
void _restartApp() => CacheKeyProvider.debugReset();

Future<EncryptedKeyValueStore> _boot(
  KeyValueStore inner,
  SecureKeyStore keyStore, {
  LegacyPlaintextProbe? legacyProbe,
}) async {
  final store = await EncryptedKeyValueStore.create(inner,
      keyStore: keyStore, legacyProbe: legacyProbe);
  expect(store, isNotNull,
      reason: 'Der Fake-Keystore liefert immer einen DEK.');
  return store!;
}

/// The production store. The sweep enumerates there, so in the sweep tests the
/// decorator must sit on the SAME storage, or the test checks wiring that does
/// not exist.
Future<KeyValueStore> _prefsStore() async =>
    SharedPreferencesStore(await SharedPreferences.getInstance());

void main() {
  // Marker and sentinel live in SharedPreferences, so binding and prefs mock
  // are mandatory.
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    CacheKeyProvider.debugReset();
    // The one-shot report counters are per process; a test run simulates many
    // processes in one.
    EncryptedKeyValueStore.debugResetReportGuards();
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });
  tearDown(() {
    CacheKeyProvider.debugReset();
    EncryptedKeyValueStore.debugResetReportGuards();
    CrashReporter.debugSentrySink = null;
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
    final keyStore = _MemoryKeyStore();

    await _boot(InMemoryKeyValueStore(), keyStore);
    _restartApp();
    final raw = InMemoryKeyValueStore({_slot: _plaintext});
    await (await _boot(raw, keyStore)).getString(_slot);
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

  group('Bestandsschutz: erster Start nach dem Update', () {
    test('uebernimmt den Klartext-Slot und verschluesselt ihn', () async {
      final raw = InMemoryKeyValueStore({_slot: _plaintext});

      final store = await _boot(raw, _MemoryKeyStore());

      expect(await store.getString(_slot), _plaintext,
          reason: 'Der Marker wird in DIESEM Bootstrap gesetzt — massgeblich '
              'ist sein Stand von davor, sonst verlieren Bestandsnutzer beim '
              'Update ihre nicht quittierten Writes.');
      expect(raw.snapshot[_slot], startsWith(cacheCipherMagic));
      expect(raw.snapshot[_slot], isNot(contains('Kebab')));
    });

    test('setzt dabei den Marker in SharedPreferences', () async {
      await _boot(InMemoryKeyValueStore(), _MemoryKeyStore());

      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      expect(prefs.getBool(CacheKeyProvider.plaintextMigrationClosedKey),
          isTrue,
          reason: 'Der Marker muss neben dem Sentinel liegen: beide gehen nur '
              'gemeinsam mit den Blobs verloren.');
    });
  });

  group('W7a: der migrierende Start zieht ALLE uids ein', () {
    test(
        'Nutzer B behaelt seinen Klartext-Slot, obwohl nur Nutzer A den ersten '
        'Start nach dem Update gemacht hat', () async {
      // Disk of a legacy install with two accounts, both carrying
      // unacknowledged writes from before encryption.
      SharedPreferences.setMockInitialValues(<String, Object>{
        _slotA: _plaintextA,
        _slotB: _plaintext,
      });
      final keyStore = _MemoryKeyStore();

      // Start 1: A is logged in. On its own this start never reads a slot of
      // B — exactly where the marker used to fail.
      final storeA = await _boot(await _prefsStore(), keyStore);
      expect(await storeA.getString(_slotA), _plaintextA);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(_slotB), startsWith(cacheCipherMagic),
          reason: 'Der Marker schliesst fuer ALLE uids gleichzeitig — dann '
              'muss dieser Start auch fuer alle uids migriert haben.');
      expect(prefs.getString(_slotB), isNot(contains('Kebab')));
      await prefs.reload();
      expect(prefs.getBool(CacheKeyProvider.plaintextMigrationClosedKey),
          isTrue);

      // Start 2: B logs in; the marker was set long ago.
      _restartApp();
      final storeB = await _boot(await _prefsStore(), keyStore);

      expect(await storeB.getString(_slotB), _plaintext,
          reason: 'Der eigentliche Beweis: B hatte nie die Gelegenheit zu '
              'einer eigenen Migration. Faellt seine Outbox trotzdem in '
              'ExpiredPlaintextCacheSlot, sind bis zu 500 nicht quittierte '
              'Writes weg — und zwar endgueltig.');
      expect(keyStore.writes, 1, reason: 'Kein zweiter DEK.');
    });

    test('fremde eatova.v1.-Keys fasst der Sweep nicht an', () async {
      // These share the namespace but are read WITHOUT the decorator. A sweep
      // over the whole prefix would encrypt and permanently destroy them — the
      // costlier bug, because it hits every install, not just multi-account
      // devices.
      SharedPreferences.setMockInitialValues(<String, Object>{
        'eatova.v1.locale': 'de',
        'eatova.v1.theme_mode': 'dark',
        'eatova.v1.search_credentials': '{"host":"suche.example"}',
        'eatova.v1.otp_guard.mail@example.com': '3',
        'sb-eatova-auth-token': '{"access_token":"xyz"}',
        _slotB: _plaintext,
      });

      await _boot(await _prefsStore(), _MemoryKeyStore());

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('eatova.v1.locale'), 'de');
      expect(prefs.getString('eatova.v1.theme_mode'), 'dark');
      expect(prefs.getString('eatova.v1.search_credentials'),
          '{"host":"suche.example"}');
      expect(prefs.getString('eatova.v1.otp_guard.mail@example.com'), '3');
      expect(prefs.getString('sb-eatova-auth-token'),
          '{"access_token":"xyz"}');
      expect(prefs.getString(_slotB), startsWith(cacheCipherMagic),
          reason: 'Und der echte Cache-Slot muss trotzdem migriert werden — '
              'sonst prueft der Test nur einen Sweep, der gar nichts tut.');
    });

    test('nur die Slot-Namen von LocalCache gelten als Cache-Slot', () {
      for (final slot in legacyCacheSlotNames) {
        expect(isLegacyCacheSlotKey('eatova.v1.$slot.user-1'), isTrue,
            reason: '$slot fehlt in der Erlaubnisliste.');
      }
      expect(isLegacyCacheSlotKey('eatova.v1.locale'), isFalse);
      expect(isLegacyCacheSlotKey('eatova.v1.theme_mode'), isFalse);
      expect(isLegacyCacheSlotKey('eatova.v1.search_credentials'), isFalse);
      expect(isLegacyCacheSlotKey('eatova.v1.otp_guard.mail@example.com'),
          isFalse);
      expect(isLegacyCacheSlotKey(CacheKeyProvider.dekProvisionedKey), isFalse);
      expect(isLegacyCacheSlotKey(CacheKeyProvider.plaintextMigrationClosedKey),
          isFalse);
      expect(isLegacyCacheSlotKey('sb-eatova-auth-token'), isFalse);
    });

    test('scheitert der Sweep, bleibt der Marker OFFEN', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        _slotB: _plaintext,
      });
      final keyStore = _MemoryKeyStore();

      // Start 1: enumeration throws. Not knowing whether anything was left to
      // inherit, the path must stay open.
      await _boot(await _prefsStore(), keyStore,
          legacyProbe: _FailingLegacyProbe());

      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      expect(prefs.getBool(CacheKeyProvider.plaintextMigrationClosedKey),
          isNot(isTrue),
          reason: 'Der Marker ist einweg — ein Prefs-Aussetzer darf ihn nicht '
              'setzen, sonst kostet ein einzelner Fehlstart die Outbox.');

      // Start 2: with a working probe the sweep catches up.
      _restartApp();
      await _boot(await _prefsStore(), keyStore);

      expect(prefs.getString(_slotB), startsWith(cacheCipherMagic));
      await prefs.reload();
      expect(prefs.getBool(CacheKeyProvider.plaintextMigrationClosedKey),
          isTrue);
    });
  });

  group('nach gesetztem Marker', () {
    test('wird DERSELBE Klartext-Slot verworfen statt uebernommen', () async {
      final keyStore = _MemoryKeyStore();
      // Start 1: empty cache, the bootstrap sets the marker.
      await _boot(InMemoryKeyValueStore(), keyStore);

      // Start 2: same DEK, slot and plaintext, but now planted, not inherited.
      _restartApp();
      final raw = InMemoryKeyValueStore({_slot: _plaintext});
      final store = await _boot(raw, keyStore);

      expect(await store.getString(_slot), isNull,
          reason: 'Ohne Magic gibt es weder GCM-Tag noch AAD — der Wert darf '
              'nicht als Outbox in die Sync-Schleife gelangen.');
      expect(raw.snapshot.containsKey(_slot), isFalse,
          reason: 'Behandlung wie ein unentschluesselbarer Slot: raeumen.');
      expect(keyStore.writes, 1, reason: 'Kein zweiter DEK.');

      // A migration would run through the write chain, so wait for it or the
      // snapshot merely proves it has not finished yet.
      await Future<void>.delayed(Duration.zero);
      expect(raw.snapshot, isEmpty,
          reason: 'Ein untergeschobener Wert darf auch nicht nachtraeglich '
              'durch die Migration zu einem gueltig signierten Ciphertext '
              'aufgewertet werden.');
    });
  });

  group('regulaerer Ciphertext', () {
    test('funktioniert vor und nach dem Marker', () async {
      final keyStore = _MemoryKeyStore();
      final raw = InMemoryKeyValueStore();

      // Start 1 (marker still open): write and read.
      final first = await _boot(raw, keyStore);
      await first.setString(_slot, _plaintext);
      expect(await first.getString(_slot), _plaintext);
      expect(raw.snapshot[_slot], startsWith(cacheCipherMagic));

      // Start 2 (marker set): same DEK, same blob.
      _restartApp();
      final second = await _boot(raw, keyStore);

      expect(await second.getString(_slot), _plaintext,
          reason: 'Die Befristung betrifft ausschliesslich den magic-losen '
              'Zweig — verschluesselte Slots bleiben unberuehrt.');
      await second.setString(_slot, '{"items":[]}');
      expect(await second.getString(_slot), '{"items":[]}');
      expect(raw.snapshot[_slot], startsWith(cacheCipherMagic));
    });
  });

  group('Sichtbarkeit statt Garantie', () {
    test(
        'der verworfene Klartext-Slot wird auch gemeldet, wenn vorher schon '
        'ein toter Ciphertext gemeldet wurde', () async {
      final reported = <String>[];
      CrashReporter.debugSentrySink = (error, stack, context) {
        reported.add(error.toString());
      };
      final keyStore = _MemoryKeyStore();
      await _boot(InMemoryKeyValueStore(), keyStore);

      // Start 2: marker set. The cache holds two dead ciphertexts (the
      // keystore-reset case) AND the planted plaintext.
      _restartApp();
      final raw = InMemoryKeyValueStore({
        _toterSlot: _toterCiphertext,
        _zweiterToterSlot: _toterCiphertext,
        _slot: _plaintext,
      });
      final store = await _boot(raw, keyStore);

      expect(await store.getString(_toterSlot), isNull);
      expect(await store.getString(_zweiterToterSlot), isNull);
      expect(await store.getString(_slot), isNull);
      // capture() runs unawaited.
      await Future<void>.delayed(Duration.zero);

      expect(reported.where((e) => e.contains('ExpiredPlaintextCacheSlot')),
          hasLength(1),
          reason: 'Die Befristung haelt einen Angreifer mit Schreibzugriff '
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
