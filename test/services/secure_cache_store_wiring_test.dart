import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/secure_cache_store.dart';

// WIRING GUARD.
//
// The option CONSTANTS and the bootstrap behaviour are tested elsewhere;
// between them sits a gap through which the whole A1 fix could vanish without
// a test going red: `FlutterSecureStorage()` without `aOptions:`/`iOptions:`
// (production on the 10.x defaults), or a no-op default for `sentinelStore`
// or `probe`. This file checks only that the production paths use them.

/// Platform fake recording which options map reaches it. `extends`, not
/// `implements`: the setter checks a token only its own constructor sets.
class _RecordingPlatform extends FlutterSecureStoragePlatform {
  Map<String, String>? lastOptions;
  String? lastKey;
  final Map<String, String> data = <String, String>{};

  @override
  Future<String?> read({
    required String key,
    required Map<String, String> options,
  }) async {
    lastKey = key;
    lastOptions = options;
    return data[key];
  }

  @override
  Future<void> write({
    required String key,
    required String value,
    required Map<String, String> options,
  }) async {
    lastKey = key;
    lastOptions = options;
    data[key] = value;
  }

  @override
  Future<void> delete({
    required String key,
    required Map<String, String> options,
  }) async {
    lastKey = key;
    lastOptions = options;
    data.remove(key);
  }

  @override
  Future<bool> containsKey({
    required String key,
    required Map<String, String> options,
  }) async {
    lastOptions = options;
    return data.containsKey(key);
  }

  @override
  Future<Map<String, String>> readAll({
    required Map<String, String> options,
  }) async {
    lastOptions = options;
    return data;
  }

  @override
  Future<void> deleteAll({required Map<String, String> options}) async {
    lastOptions = options;
    data.clear();
  }
}

/// Keystore without entry and without error — the "there is no DEK" signal.
class _AbsentDekKeyStore implements SecureKeyStore {
  int writes = 0;

  @override
  Future<String?> read(String key) async => null;

  @override
  Future<void> write(String key, String value) async => writes++;

  @override
  Future<void> delete(String key) async {}
}

const String _blobKey = 'eatova.v1.outbox.user-1';
const String _deadBlob = '${cacheCipherMagic}dGhpcyBpcyB0b3Q=';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    CacheKeyProvider.debugReset();
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });
  tearDown(CacheKeyProvider.debugReset);

  group('PluginSecureKeyStore reicht die Options bis zur Plattform durch', () {
    late _RecordingPlatform platform;
    late FlutterSecureStoragePlatform previous;

    setUp(() {
      platform = _RecordingPlatform();
      previous = FlutterSecureStoragePlatform.instance;
      FlutterSecureStoragePlatform.instance = platform;
    });

    tearDown(() {
      FlutterSecureStoragePlatform.instance = previous;
      debugDefaultTargetPlatformOverride = null;
    });

    test('Android-READ traegt resetOnError=false', () async {
      // `_selectOptions` picks by `defaultTargetPlatform`; without the
      // override the test would see the host's options.
      debugDefaultTargetPlatformOverride = TargetPlatform.android;

      await const PluginSecureKeyStore().read(CacheKeyProvider.dekStorageKey);

      expect(platform.lastKey, CacheKeyProvider.dekStorageKey);
      expect(platform.lastOptions?['resetOnError'], 'false',
          reason: 'Kommt hier "true" (oder gar nichts) an, loescht die '
              'Java-Seite den DEK bei JEDEM Keystore-Fehler und meldet Dart '
              'ein blankes null — der komplette A1-Fix waere wirkungslos, '
              'obwohl PluginSecureKeyStore.androidOptions korrekt aussieht.');
    });

    test('Android-WRITE traegt resetOnError=false', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;

      await const PluginSecureKeyStore()
          .write(CacheKeyProvider.dekStorageKey, 'x');

      expect(platform.lastOptions?['resetOnError'], 'false',
          reason: 'Der Write-Pfad legt den DEK an — mit den Default-Options '
              'liefe schon das Anlegen unter der falschen Haltung.');
    });

    test('iOS-READ traegt first_unlock_this_device', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;

      await const PluginSecureKeyStore().read(CacheKeyProvider.dekStorageKey);

      expect(platform.lastOptions?['accessibility'], 'first_unlock_this_device',
          reason: 'Der Plugin-Default ist "unlocked": der DEK waere dann in '
              'Lifecycle- und Notification-Pfaden vor der ersten Entsperrung '
              'unlesbar.');
    });

    test('iOS-WRITE traegt first_unlock_this_device', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;

      await const PluginSecureKeyStore()
          .write(CacheKeyProvider.dekStorageKey, 'x');

      expect(platform.lastOptions?['accessibility'], 'first_unlock_this_device',
          reason: 'Die Accessibility wird beim ANLEGEN festgeschrieben — ein '
              'korrekter Read auf einem falsch angelegten Item hilft nicht.');
    });

    test('iOS-WRITE ist nicht synchronizable (kein iCloud-Keychain-Sync)',
        () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;

      await const PluginSecureKeyStore()
          .write(CacheKeyProvider.dekStorageKey, 'x');

      expect(platform.lastOptions?['synchronizable'], isNot('true'),
          reason: 'Ein synchronisierter DEK laege auf fremden Geraeten — und '
              'der Ciphertext dort ohne Bezug.');
    });
  });

  group('CacheKeyProvider.obtain benutzt produktiv die echten Nahtstellen', () {
    test('DEFAULT-SENTINEL schreibt nach SharedPreferences', () async {
      expect(await CacheKeyProvider.obtain(keyStore: _AbsentDekKeyStore()),
          isNotNull);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(CacheKeyProvider.dekProvisionedKey), isTrue,
          reason: 'Ohne injizierten sentinelStore MUSS der Prefs-Sentinel '
              'greifen — ein No-Op-Default waere von keinem Verhaltenstest '
              'zu unterscheiden.');
    });

    test('DEFAULT-SENTINEL wird auch GELESEN (Abbruch statt Neu-Praegen)',
        () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        CacheKeyProvider.dekProvisionedKey: true,
        _blobKey: _deadBlob,
      });
      final keyStore = _AbsentDekKeyStore();

      expect(await CacheKeyProvider.obtain(keyStore: keyStore), isNull,
          reason: 'Ein Default-Sentinel, dessen isProvisioned() immer false '
              'liefert, wuerde hier praegen und den Blob verwaisen lassen.');
      expect(keyStore.writes, 0);
    });

    test('DEFAULT-PROBE sieht einen echten EATOVA1-Slot in SharedPreferences',
        () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        CacheKeyProvider.dekProvisionedKey: true,
        _blobKey: _deadBlob,
      });

      expect(await CacheKeyProvider.obtain(keyStore: _AbsentDekKeyStore()),
          isNull,
          reason: 'Eine Probe, die immer eine leere Liste liefert, wuerde den '
              'Blob uebersehen und sofort neu praegen.');
    });

    test('DEFAULT-PROBE meldet Abwesenheit korrekt (kein blindes Fail-Closed)',
        () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        CacheKeyProvider.dekProvisionedKey: true,
        // Plaintext, no EATOVA1 — must not block the bootstrap.
        'eatova.v1.profile.user-1': '{"weight_kg":82}',
      });

      expect(await CacheKeyProvider.obtain(keyStore: _AbsentDekKeyStore()),
          isNotNull,
          reason: 'Zusammen mit dem Test darueber schliesst das die Luecke von '
              'beiden Seiten: eine Probe, die immer wirft oder immer etwas '
              'meldet, faellt hier durch.');
    });

    test('EncryptedKeyValueStore.create reicht die Probe durch', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        CacheKeyProvider.dekProvisionedKey: true,
        _blobKey: _deadBlob,
      });

      final store = await EncryptedKeyValueStore.create(
        InMemoryKeyValueStore(),
        keyStore: _AbsentDekKeyStore(),
      );

      expect(store, isNull,
          reason: 'LocalCache.create ruft genau diese Signatur ohne Argumente '
              'auf — die Defaults muessen also hier ankommen.');
    });
  });
}
