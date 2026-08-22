import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:eatova/src/config/supabase_config.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/secure_cache_store.dart';

// C5: without `authOptions`, access AND refresh tokens land as plaintext JSON
// in the same `FlutterSharedPreferences.xml` whose health blobs are AES-256-GCM
// encrypted. The threat model is extraction from a device at rest, where an
// attacker simply takes the refresh token and pulls meals, weight, sleep and
// chat over the network — cache encryption buys nothing against that.
//
// Pinned: persisting goes to the keystore, the one-time migration keeps
// existing users logged in and wipes their plaintext slot, the storage key is
// byte-identical to the Supabase default (or the migration finds nothing), and
// a broken keystore means "logged out", never a boot error or a silent
// plaintext fallback.

const String _refreshToken = 'refresh-o5Xq7c9aTtZZ-nicht-im-klartext';
const String _accessToken = 'eyJhbGciOiJIUzI1NiJ9.header-payload.sig';

const String _sessionJson = '{"access_token":"$_accessToken",'
    '"refresh_token":"$_refreshToken","token_type":"bearer",'
    '"expires_in":3600,"expires_at":1793000000,'
    '"user":{"id":"11111111-2222-3333-4444-555555555555",'
    '"email":"nutzer@example.de"}}';

const String _neueSession = '{"access_token":"neu","refresh_token":"neu-r"}';

/// In-memory keystore. `throws` switches to "OS keystore broken".
class _FakeSecureKeyStore implements SecureKeyStore {
  final Map<String, String> data = {};
  bool throws = false;

  @override
  Future<String?> read(String key) async {
    if (throws) throw StateError('keystore kaputt');
    return data[key];
  }

  @override
  Future<void> write(String key, String value) async {
    if (throws) throw StateError('keystore kaputt');
    data[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    if (throws) throw StateError('keystore kaputt');
    data.remove(key);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late String key;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    key = EatovaSupabaseConfig.sessionPersistKey;
  });

  test(
      'C5: der persistierte Session-Token liegt NICHT im Klartext in '
      'SharedPreferences', () async {
    final secure = _FakeSecureKeyStore();
    final prefs = InMemoryKeyValueStore();
    final storage = EatovaSupabaseConfig.buildSessionStorage(
      secureStore: secure,
      legacyStore: prefs,
    );

    await storage.initialize();
    await storage.persistSession(_sessionJson);

    expect(prefs.snapshot.values.join(), isNot(contains(_refreshToken)),
        reason: 'Der Refresh-Token ist der Generalschluessel zum Konto — er '
            'darf nicht neben den verschluesselten Health-Blobs im Klartext '
            'liegen.');
    expect(prefs.snapshot.values.join(), isNot(contains(_accessToken)));
    expect(secure.data[key], _sessionJson);
    expect(await storage.accessToken(), _sessionJson);
    expect(await storage.hasAccessToken(), isTrue);
  });

  group('C5 Einmal-Migration der Bestandsnutzer', () {
    test('Klartext-Session wandert in den Keystore und wird geraeumt',
        () async {
      final secure = _FakeSecureKeyStore();
      final prefs = InMemoryKeyValueStore({key: _sessionJson});
      final storage = EatovaSupabaseConfig.buildSessionStorage(
        secureStore: secure,
        legacyStore: prefs,
      );

      await storage.initialize();

      expect(secure.data[key], _sessionJson,
          reason: 'Ohne Migration waere beim Update JEDER Bestandsnutzer '
              'ausgeloggt.');
      expect(prefs.snapshot.containsKey(key), isFalse,
          reason: 'Nach der Migration darf der Klartext nicht liegen bleiben.');
      expect(await storage.hasAccessToken(), isTrue);
      expect(await storage.accessToken(), _sessionJson);
    });

    test('laeuft genau einmal und ueberschreibt eine neuere Session nicht',
        () async {
      final secure = _FakeSecureKeyStore()..data[key] = _neueSession;
      final prefs = InMemoryKeyValueStore({key: _sessionJson});
      final storage = EatovaSupabaseConfig.buildSessionStorage(
        secureStore: secure,
        legacyStore: prefs,
      );

      await storage.initialize();

      expect(secure.data[key], _neueSession,
          reason: 'Der Keystore ist die Wahrheit, sobald er etwas haelt.');
      expect(prefs.snapshot.containsKey(key), isFalse,
          reason: 'Der veraltete Klartext-Rest muss trotzdem weg.');

      // Second start: the plaintext slot is gone, nothing changes.
      await storage.initialize();
      expect(secure.data[key], _neueSession);
    });

    test('frische Installation ohne Klartext-Slot: kein Fehler, keine Session',
        () async {
      final secure = _FakeSecureKeyStore();
      final prefs = InMemoryKeyValueStore();
      final storage = EatovaSupabaseConfig.buildSessionStorage(
        secureStore: secure,
        legacyStore: prefs,
      );

      await storage.initialize();

      expect(await storage.hasAccessToken(), isFalse);
      expect(await storage.accessToken(), isNull);
      expect(secure.data, isEmpty);
    });

    test('greift auch, wenn initialize() uebersprungen wurde', () async {
      final secure = _FakeSecureKeyStore();
      final prefs = InMemoryKeyValueStore({key: _sessionJson});
      final storage = EatovaSupabaseConfig.buildSessionStorage(
        secureStore: secure,
        legacyStore: prefs,
      );

      // recoverSession() calls hasAccessToken() without a prior initialize().
      expect(await storage.hasAccessToken(), isTrue);
      expect(prefs.snapshot.containsKey(key), isFalse);
    });
  });

  group('C5 Logout und Fehlerpfade', () {
    test('removePersistedSession raeumt Keystore UND Klartext-Rest', () async {
      final secure = _FakeSecureKeyStore()..data[key] = _sessionJson;
      final prefs = InMemoryKeyValueStore({key: _sessionJson});
      final storage = EatovaSupabaseConfig.buildSessionStorage(
        secureStore: secure,
        legacyStore: prefs,
      );

      await storage.removePersistedSession();

      expect(secure.data.containsKey(key), isFalse);
      expect(prefs.snapshot.containsKey(key), isFalse,
          reason: 'Ein Logout muss den Token in JEDEM Fall vom Geraet nehmen.');
    });

    test('defekter Keystore loggt aus, wirft aber nicht (sonst Boot-Fehler)',
        () async {
      final secure = _FakeSecureKeyStore()..throws = true;
      final prefs = InMemoryKeyValueStore({key: _sessionJson});
      final storage = EatovaSupabaseConfig.buildSessionStorage(
        secureStore: secure,
        legacyStore: prefs,
      );

      // SupabaseAuth.initialize calls these three without try/catch.
      await storage.initialize();
      expect(await storage.hasAccessToken(), isFalse);
      expect(await storage.accessToken(), isNull);
      await storage.persistSession(_sessionJson);

      expect(prefs.snapshot[key], _sessionJson,
          reason: 'Die Migration darf den Klartext erst NACH einem '
              'erfolgreichen Keystore-Write raeumen — sonst waere die Session '
              'endgueltig weg.');
    });
  });

  test(
      'C5: der Storage-Key ist byte-gleich mit dem Supabase-Default '
      '(sonst findet die Migration nichts)', () {
    // The formula is rebuilt independently from the supabase_flutter source,
    // not copied from our code, so changing `sessionPersistKey` fails here.
    final erwartet =
        'sb-${Uri.parse(EatovaSupabaseConfig.url).host.split('.').first}'
        '-auth-token';
    expect(EatovaSupabaseConfig.sessionPersistKey, erwartet);

    // Deliberately no literal with the project id: that is right locally and
    // wrong in CI (`--dart-define=SUPABASE_URL=https://ci.invalid`). Prefix
    // and suffix are URL-independent and still catch a format change.
    expect(EatovaSupabaseConfig.sessionPersistKey, startsWith('sb-'));
    expect(EatovaSupabaseConfig.sessionPersistKey, endsWith('-auth-token'));
  });
}
