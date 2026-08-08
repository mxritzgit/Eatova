import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:eatova/src/config/supabase_config.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/secure_cache_store.dart';

// C5: Access- UND Refresh-Token landen ohne `authOptions` als Klartext-JSON in
// derselben `FlutterSharedPreferences.xml`, deren Health-Blobs seit 7f895f9
// AES-256-GCM-verschluesselt sind. Das erklaerte Bedrohungsmodell ist
// Extraktion vom RUHENDEN Geraet — genau dort nimmt der Angreifer einfach den
// Refresh-Token und zieht sich Mahlzeiten, Gewicht, Schlaf und Chat ueber das
// Netz. Die Cache-Verschluesselung kauft gegen ihn dann nichts.
//
// Gesichert wird:
//   1. Persistieren geht in den Keystore, nicht in SharedPreferences.
//   2. EINMAL-MIGRATION: Bestandsnutzer bleiben eingeloggt, ihr Klartext-Slot
//      wird geraeumt (ohne diesen Pfad waeren beim Update ALLE ausgeloggt).
//   3. Der Storage-Key ist byte-gleich mit dem Supabase-Default — sonst
//      findet die Migration nichts.
//   4. Ein defekter Keystore fuehrt zu "ausgeloggt", NIE zu einem Boot-Fehler
//      und nie zu einem stillen Klartext-Fallback.

const String _refreshToken = 'refresh-o5Xq7c9aTtZZ-nicht-im-klartext';
const String _accessToken = 'eyJhbGciOiJIUzI1NiJ9.header-payload.sig';

const String _sessionJson = '{"access_token":"$_accessToken",'
    '"refresh_token":"$_refreshToken","token_type":"bearer",'
    '"expires_in":3600,"expires_at":1793000000,'
    '"user":{"id":"11111111-2222-3333-4444-555555555555",'
    '"email":"nutzer@example.de"}}';

const String _neueSession = '{"access_token":"neu","refresh_token":"neu-r"}';

/// In-Memory-Keystore. `throws` schaltet auf "OS-Keystore kaputt".
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

      // Zweiter Start: der Klartext-Slot ist weg, nichts aendert sich mehr.
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

      // recoverSession() ruft hasAccessToken() ohne vorheriges initialize().
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

      // SupabaseAuth.initialize ruft diese drei ohne try/catch.
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
    // supabase_flutter-2.17.1/lib/src/supabase.dart:132-133 — die Formel ist
    // hier unabhaengig aus der Paketquelle nachgebaut, nicht aus unserem Code
    // abgeschrieben. Aendert jemand `sessionPersistKey` (etwa auf den vollen
    // Host), faellt diese Zusicherung.
    final erwartet =
        'sb-${Uri.parse(EatovaSupabaseConfig.url).host.split('.').first}'
        '-auth-token';
    expect(EatovaSupabaseConfig.sessionPersistKey, erwartet);

    // Bewusst KEIN Literal mit der Projekt-Kennung mehr. Hier stand
    // 'sb-ftoozzvmduptrvrrrshb-auth-token' — das ist lokal richtig (dort
    // greift der Default aus supabase_config.dart:23) und in der CI falsch,
    // weil dort `--dart-define=SUPABASE_URL=https://ci.invalid` gesetzt wird.
    // Der Test war damit umgebungsabhaengig und ist genau daran zuerst in der
    // CI gescheitert. Rahmen und Endung sind dagegen unabhaengig von der URL
    // und fangen eine Praefix-/Suffix-Aenderung trotzdem.
    expect(EatovaSupabaseConfig.sessionPersistKey, startsWith('sb-'));
    expect(EatovaSupabaseConfig.sessionPersistKey, endsWith('-auth-token'));
  });
}
