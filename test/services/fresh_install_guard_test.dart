import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:eatova/src/config/install_marker.dart';
import 'package:eatova/src/config/supabase_config.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/secure_cache_store.dart';

// P3-01: the iOS Keychain keeps the persisted session across an uninstall,
// while SharedPreferences (including the logout journal) is wiped. Without the
// install marker a reinstall silently signed into the previous account.
// Pinned: a fresh install discards the leftover, an update of a build without
// the marker keeps its session, an existing marker changes nothing, and every
// failure ends on the login screen instead of in the old account or a boot
// error.

const String _userId = '11111111-2222-3333-4444-555555555555';
const String _altSession = '{"access_token":"alt","refresh_token":"alt-r",'
    '"user":{"id":"$_userId"}}';
const String _neueSession = '{"access_token":"neu","refresh_token":"neu-r",'
    '"user":{"id":"99999999-2222-3333-4444-555555555555"}}';

class _FakeSecureKeyStore implements SecureKeyStore {
  final Map<String, String> data = {};
  bool readThrows = false;
  bool deleteThrows = false;

  @override
  Future<String?> read(String key) async {
    if (readThrows) throw StateError('keychain gesperrt');
    return data[key];
  }

  @override
  Future<void> write(String key, String value) async => data[key] = value;

  @override
  Future<void> delete(String key) async {
    if (deleteThrows) throw StateError('keychain gesperrt');
    data.remove(key);
  }
}

/// Journal store whose writes fail, as when the app container is unwritable.
class _BrokenJournalStore extends InMemoryKeyValueStore {
  @override
  Future<void> setString(String key, String value) async =>
      throw StateError('prefs voll');
}

class _ThrowingInstallState implements InstallStateStore {
  _ThrowingInstallState({this.markerThrows = false});
  final bool markerThrows;
  bool written = false;

  @override
  Future<bool> hasMarker() async {
    if (markerThrows) throw StateError('prefs kaputt');
    return false;
  }

  @override
  Future<bool> hasPriorLaunchEvidence() async =>
      throw StateError('path_provider fehlt');

  @override
  Future<void> writeMarker() async => written = true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late String key;
  late Directory tmp;
  late String dbPath;

  setUp(() async {
    key = EatovaSupabaseConfig.sessionPersistKey;
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tmp = await Directory.systemTemp.createTemp('install_marker_test');
    dbPath = '${tmp.path}/eatova-cache.sqlite';
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  PrefsInstallStateStore installState() =>
      PrefsInstallStateStore(cacheDatabasePath: () async => dbPath);

  Future<bool> markerSet() async =>
      (await SharedPreferences.getInstance())
          .getBool(FreshInstallGuard.markerKey) ??
      false;

  test(
      'Neuinstallation mit Keychain-Rest: Session geraeumt, abgemeldet, '
      'Marker gesetzt', () async {
    final secure = _FakeSecureKeyStore()..data[key] = _altSession;
    final storage = EatovaSupabaseConfig.buildSessionStorage(
        secureStore: secure, legacyStore: InMemoryKeyValueStore());

    final check = await FreshInstallGuard.run(
      discardLeftoverSession: storage.discardLeftoverSession,
      store: installState(),
    );

    expect(check, InstallCheck.freshInstall);
    expect(secure.data.containsKey(key), isFalse,
        reason: 'Der Keychain-Rest des Vorbesitzers muss weg sein.');
    expect(await storage.accessToken(), isNull,
        reason: 'Sonst stellt das SDK das alte Konto wieder her.');
    expect(await markerSet(), isTrue);
  });

  test('Neuinstallation ohne Rest: nur der Marker wird gesetzt', () async {
    final secure = _FakeSecureKeyStore();
    final journal = InMemoryKeyValueStore();
    final storage = EatovaSupabaseConfig.buildSessionStorage(
        secureStore: secure, legacyStore: journal);

    final check = await FreshInstallGuard.run(
      discardLeftoverSession: storage.discardLeftoverSession,
      store: installState(),
    );

    expect(check, InstallCheck.freshInstall);
    expect(journal.snapshot, isEmpty,
        reason: 'Ohne Rest gibt es nichts zu journalisieren.');
    expect(await markerSet(), isTrue);
  });

  group('Update von einem Build ohne Marker behaelt die Session', () {
    test('Beleg: Eintraege in SharedPreferences (Builds vor SQLite)',
        () async {
      SharedPreferences.setMockInitialValues(
          <String, Object>{CacheKeyProvider.dekProvisionedKey: true});
      final secure = _FakeSecureKeyStore()..data[key] = _altSession;
      final storage = EatovaSupabaseConfig.buildSessionStorage(
          secureStore: secure, legacyStore: InMemoryKeyValueStore());

      final check = await FreshInstallGuard.run(
        discardLeftoverSession: storage.discardLeftoverSession,
        store: installState(),
      );

      expect(check, InstallCheck.upgraded);
      expect(secure.data[key], _altSession);
      expect(await storage.accessToken(), _altSession,
          reason: 'Ein Update darf niemanden abmelden.');
      expect(await markerSet(), isTrue);
    });

    test('Beleg: die SQLite-Cache-Datei (Prefs leer seit der Migration)',
        () async {
      await File(dbPath).writeAsString('');
      final secure = _FakeSecureKeyStore()..data[key] = _altSession;
      final storage = EatovaSupabaseConfig.buildSessionStorage(
          secureStore: secure, legacyStore: InMemoryKeyValueStore());

      final check = await FreshInstallGuard.run(
        discardLeftoverSession: storage.discardLeftoverSession,
        store: installState(),
      );

      expect(check, InstallCheck.upgraded);
      expect(await storage.accessToken(), _altSession);
      expect(await markerSet(), isTrue);
    });
  });

  test('Marker vorhanden: nichts wird angefasst', () async {
    SharedPreferences.setMockInitialValues(
        <String, Object>{FreshInstallGuard.markerKey: true});
    var discardCalls = 0;

    final check = await FreshInstallGuard.run(
      discardLeftoverSession: () async {
        discardCalls++;
        return true;
      },
      store: installState(),
    );

    expect(check, InstallCheck.marked);
    expect(discardCalls, 0);
  });

  test('der Marker selbst zaehlt nicht als Beleg fuer einen frueheren Start',
      () async {
    SharedPreferences.setMockInitialValues(
        <String, Object>{FreshInstallGuard.markerKey: false});
    expect(await installState().hasPriorLaunchEvidence(), isFalse);
  });

  group('Fehler enden auf dem Login-Screen, nie im alten Konto', () {
    test(
        'Loeschen UND Journal scheitern: in diesem Prozess nichts '
        'wiederhergestellt, Marker offen, naechster Start raeumt', () async {
      final secure = _FakeSecureKeyStore()
        ..data[key] = _altSession
        ..deleteThrows = true;
      final storage = EatovaSupabaseConfig.buildSessionStorage(
          secureStore: secure, legacyStore: _BrokenJournalStore());

      final check = await FreshInstallGuard.run(
        discardLeftoverSession: storage.discardLeftoverSession,
        store: installState(),
      );

      expect(check, InstallCheck.purgeIncomplete);
      expect(await storage.accessToken(), isNull,
          reason: 'Fail closed: der Rest darf in diesem Prozess nicht '
              'wiederhergestellt werden.');
      expect(await markerSet(), isFalse,
          reason: 'Ohne Marker wiederholt der naechste Start die Pruefung.');

      // Next start: the keychain works again.
      secure.deleteThrows = false;
      final next = EatovaSupabaseConfig.buildSessionStorage(
          secureStore: secure, legacyStore: InMemoryKeyValueStore());
      expect(
        await FreshInstallGuard.run(
          discardLeftoverSession: next.discardLeftoverSession,
          store: installState(),
        ),
        InstallCheck.freshInstall,
      );
      expect(secure.data.containsKey(key), isFalse);
      expect(await markerSet(), isTrue);
    });

    test('nur das Loeschen scheitert: das Journal verweigert die Session',
        () async {
      final secure = _FakeSecureKeyStore()
        ..data[key] = _altSession
        ..deleteThrows = true;
      final journal = InMemoryKeyValueStore();
      final storage = EatovaSupabaseConfig.buildSessionStorage(
          secureStore: secure, legacyStore: journal);

      final check = await FreshInstallGuard.run(
        discardLeftoverSession: storage.discardLeftoverSession,
        store: installState(),
      );

      expect(check, InstallCheck.freshInstall);
      // A later process (fresh storage, same journal) still refuses it.
      final later = EatovaSupabaseConfig.buildSessionStorage(
          secureStore: secure, legacyStore: journal);
      expect(await later.accessToken(), isNull);
    });

    test('Keychain nicht lesbar: kein Boot-Fehler, nichts wiederhergestellt',
        () async {
      final secure = _FakeSecureKeyStore()
        ..data[key] = _altSession
        ..readThrows = true;
      final storage = EatovaSupabaseConfig.buildSessionStorage(
          secureStore: secure, legacyStore: InMemoryKeyValueStore());

      final check = await FreshInstallGuard.run(
        discardLeftoverSession: storage.discardLeftoverSession,
        store: installState(),
      );

      expect(check, InstallCheck.purgeIncomplete);
      secure.readThrows = false;
      expect(await storage.accessToken(), isNull);
      expect(await markerSet(), isFalse);
    });

    test('Beleg-Pruefung wirft: gilt als Neuinstallation', () async {
      var discardCalls = 0;
      final state = _ThrowingInstallState(markerThrows: true);

      final check = await FreshInstallGuard.run(
        discardLeftoverSession: () async {
          discardCalls++;
          return true;
        },
        store: state,
      );

      expect(check, InstallCheck.freshInstall);
      expect(discardCalls, 1);
      expect(state.written, isTrue);
    });

    test('Raeumen wirft: kein Boot-Fehler, Marker offen', () async {
      final state = _ThrowingInstallState();

      final check = await FreshInstallGuard.run(
        discardLeftoverSession: () async => throw StateError('unerwartet'),
        store: state,
      );

      expect(check, InstallCheck.purgeIncomplete);
      expect(state.written, isFalse);
    });
  });

  test('nach dem Raeumen kann sich ein neues Konto anmelden', () async {
    final secure = _FakeSecureKeyStore()..data[key] = _altSession;
    final storage = EatovaSupabaseConfig.buildSessionStorage(
        secureStore: secure, legacyStore: InMemoryKeyValueStore());
    await FreshInstallGuard.run(
      discardLeftoverSession: storage.discardLeftoverSession,
      store: installState(),
    );

    await storage.persistSession(_neueSession);

    expect(await storage.accessToken(), _neueSession,
        reason: 'Die Sperre gilt nur dem Rest, nicht dem naechsten Login.');
  });
}
