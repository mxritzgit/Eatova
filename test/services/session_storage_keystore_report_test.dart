import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:eatova/src/config/supabase_config.dart';
import 'package:eatova/src/services/crash_reporter.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/secure_cache_store.dart';

// Komplettreview 2026-08-19: `SecureSessionLocalStorage` verschluckte jeden
// Keystore-Fehler in einem reinen `dev.log`, das das Geraet nie verlaesst.
//
// Fall A (Lesen scheitert): auf einem Geraet mit beschaedigtem Keystore wird
// der Nutzer bei JEDEM Start stumm ausgeloggt.
// Fall B (Loeschen scheitert): das Abmelden wirkt lokal nicht — die UI zeigt
// den Login-Screen, der Refresh-Token liegt weiter im Keystore.
//
// Beides ist ohne Report unsichtbar. Gesichert wird hier:
//   1. jeder der fuenf Fehlerpfade meldet ueberhaupt,
//   2. mit einem eigenen `context`-Tag (Lesefehler darf den seltenen
//      Loeschfehler nicht stillstellen),
//   3. HOECHSTENS EINMAL je Vorgang und Prozess (der Lesepfad laeuft bei jedem
//      Start und mehrfach je Start),
//   4. und ohne Token, Session-Inhalt oder Plugin-Freitext — nur Fehlertyp
//      plus das eine technische Detail, das `sanitizeForReport` durchlaesst.

// Beide Werte stehen als eigene Konstanten und werden unten NUR interpoliert.
// Ein Literal, das den Feldnamen und einen JWT-foermigen Wert in DERSELBEN
// Zeile traegt, laesst den Secret-Scan der CI anschlagen (gitleaks,
// generic-api-key) — obwohl hier nichts Echtes steht. Gleiches Muster wie in
// session_storage_test.dart, das aus demselben Grund so gebaut ist.
const String _accessToken = 'eyJhbGciOiJIUzI1NiJ9.header-payload.sig';
const String _refreshToken = 'refresh-o5Xq7c9aTtZZ-nicht-im-report';
const String _sessionJson = '{"access_token":"$_accessToken",'
    '"refresh_token":"$_refreshToken","user":{"email":"nutzer@example.de"}}';

/// Der Fehler, den flutter_secure_storage auf Android real liefert: eine
/// `PlatformException` mit einem konstanten `code` und beliebigem Fremdtext in
/// `message`/`details`. Genau diese Form trennt die Allowlist im
/// `CrashReporter` auf — sie ist deshalb der richtige Testfall und nicht ein
/// nackter `StateError`.
PlatformException _keystoreFehler() => PlatformException(
      code: 'keystore_defekt',
      message: 'konnte $_refreshToken nicht entschluesseln',
      details: _sessionJson,
    );

/// Keystore, der je Vorgang gezielt scheitert.
class _KaputterKeyStore implements SecureKeyStore {
  _KaputterKeyStore({
    this.leseFehler = false,
    this.schreibFehler = false,
    this.loeschFehler = false,
  });

  final bool leseFehler;
  final bool schreibFehler;
  final bool loeschFehler;

  final Map<String, String> data = {};
  int leseAufrufe = 0;

  @override
  Future<String?> read(String key) async {
    leseAufrufe++;
    if (leseFehler) throw _keystoreFehler();
    return data[key];
  }

  @override
  Future<void> write(String key, String value) async {
    if (schreibFehler) throw _keystoreFehler();
    data[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    if (loeschFehler) throw _keystoreFehler();
    data.remove(key);
  }
}

/// Klartext-Slot, der je Vorgang gezielt scheitert.
class _KaputterLegacyStore implements KeyValueStore {
  _KaputterLegacyStore({
    this.leseFehler = false,
    this.loeschFehler = false,
    Map<String, String>? initial,
  }) : _data = {...?initial};

  final bool leseFehler;
  final bool loeschFehler;
  final Map<String, String> _data;

  @override
  Future<String?> getString(String key) async {
    if (leseFehler) throw _keystoreFehler();
    return _data[key];
  }

  @override
  Future<void> setString(String key, String value) async {
    _data[key] = value;
  }

  @override
  Future<void> remove(String key) async {
    if (loeschFehler) throw _keystoreFehler();
    _data.remove(key);
  }
}

/// Ein gemeldeter Vorfall, so wie ihn Sentry saehe.
class _Report {
  const _Report(this.error, this.context);

  final Object error;
  final String? context;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late String key;
  late List<_Report> reports;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    key = EatovaSupabaseConfig.sessionPersistKey;
    reports = <_Report>[];
    // Die Senke sitzt VOR der isActive-Schranke und bekommt exakt das Objekt,
    // das sonst an `Sentry.captureException` ginge — inklusive Sanitisierung.
    CrashReporter.debugSentrySink = (error, stack, context) {
      reports.add(_Report(error, context));
    };
  });

  tearDown(() {
    CrashReporter.debugSentrySink = null;
  });

  List<String?> kontexte() => reports.map((r) => r.context).toList();

  group('Fall A: der Lesepfad', () {
    test('ein Keystore-Lesefehler wird gemeldet — vorher war er unsichtbar',
        () async {
      final secure = _KaputterKeyStore(leseFehler: true);
      final storage = EatovaSupabaseConfig.buildSessionStorage(
        secureStore: secure,
        legacyStore: InMemoryKeyValueStore(),
      );

      expect(await storage.accessToken(), isNull,
          reason: 'Der Fehler bleibt behandelt — gemeldet heisst nicht '
              'geworfen: SupabaseAuth ruft das ohne try/catch.');
      expect(kontexte(), <String>['session_read']);
    });

    test(
        'aber HOECHSTENS EINMAL je Prozess — der Pfad laeuft bei jedem Start '
        'und mehrfach je Start', () async {
      final secure = _KaputterKeyStore(leseFehler: true);
      final storage = EatovaSupabaseConfig.buildSessionStorage(
        secureStore: secure,
        legacyStore: InMemoryKeyValueStore(),
      );

      // recoverSession() -> hasAccessToken() -> accessToken(), danach jeder
      // weitere Zugriff der laufenden Session.
      await storage.initialize();
      await storage.hasAccessToken();
      await storage.accessToken();
      await storage.accessToken();

      expect(secure.leseAufrufe, greaterThan(2),
          reason: 'Der Testaufbau muss den Pfad wirklich mehrfach treffen, '
              'sonst belegt der Zaehler unten nichts.');
      expect(reports, hasLength(1),
          reason: 'Ein dauerhaft defekter Keystore darf das Sentry-Kontingent '
              'nicht mit immer demselben Report fuellen.');
    });

    test('ein gesunder Keystore meldet gar nichts', () async {
      final secure = _KaputterKeyStore()..data[key] = _sessionJson;
      final storage = EatovaSupabaseConfig.buildSessionStorage(
        secureStore: secure,
        legacyStore: InMemoryKeyValueStore(),
      );

      await storage.initialize();
      await storage.hasAccessToken();
      await storage.persistSession(_sessionJson);
      await storage.removePersistedSession();

      expect(reports, isEmpty);
    });
  });

  group('Fall B: Abmelden, das lokal nicht wirkt', () {
    test('ein gescheiterter Session-Delete wird gemeldet', () async {
      final secure = _KaputterKeyStore(loeschFehler: true)
        ..data[key] = _sessionJson;
      final storage = EatovaSupabaseConfig.buildSessionStorage(
        secureStore: secure,
        legacyStore: InMemoryKeyValueStore(),
      );

      await storage.removePersistedSession();

      expect(kontexte(), <String>['session_delete']);
      expect(secure.data[key], _sessionJson,
          reason: 'Der Token liegt noch da — genau das ist der Vorfall.');
    });

    test(
        'der haeufige Lesefehler stellt den seltenen Loeschfehler NICHT still '
        '(getrennte Zaehler)', () async {
      final secure = _KaputterKeyStore(leseFehler: true, loeschFehler: true);
      final storage = EatovaSupabaseConfig.buildSessionStorage(
        secureStore: secure,
        legacyStore: InMemoryKeyValueStore(),
      );

      await storage.accessToken();
      await storage.removePersistedSession();

      expect(kontexte(), containsAll(<String>['session_read', 'session_delete']),
          reason: 'Mit EINEM gemeinsamen Zaehler haette der Lesefehler den '
              'Schuss verbraucht und der Logout-Fehler waere still geblieben.');
    });

    test('scheitert das Raeumen des Klartext-Slots, ist das ein eigener Fall',
        () async {
      final storage = EatovaSupabaseConfig.buildSessionStorage(
        secureStore: _KaputterKeyStore(),
        legacyStore: _KaputterLegacyStore(loeschFehler: true),
      );

      await storage.removePersistedSession();

      expect(kontexte(), <String>['session_legacy_purge']);
    });
  });

  group('die uebrigen Schreibpfade', () {
    test('ein gescheiterter Session-Write wird gemeldet', () async {
      final storage = EatovaSupabaseConfig.buildSessionStorage(
        secureStore: _KaputterKeyStore(schreibFehler: true),
        legacyStore: InMemoryKeyValueStore(),
      );

      await storage.persistSession(_sessionJson);

      expect(kontexte(), <String>['session_write']);
    });

    test('eine gescheiterte Einmal-Migration wird gemeldet', () async {
      final storage = EatovaSupabaseConfig.buildSessionStorage(
        secureStore: _KaputterKeyStore(),
        legacyStore: _KaputterLegacyStore(leseFehler: true),
      );

      await storage.initialize();

      expect(kontexte(), <String>['session_migrate'],
          reason: 'Scheitert die Migration, bleibt die Session im Klartext '
              'liegen — die C5-Zusage waere still unterlaufen.');
    });
  });

  test(
      'der Report traegt Fehlertyp und EIN technisches Detail — nie Token, '
      'Session oder Plugin-Freitext', () async {
    final storage = EatovaSupabaseConfig.buildSessionStorage(
      secureStore: _KaputterKeyStore(leseFehler: true),
      legacyStore: InMemoryKeyValueStore(),
    );

    await storage.accessToken();

    expect(reports, hasLength(1));
    final gemeldet = reports.single.error;
    expect(gemeldet, isA<SanitizedError>(),
        reason: 'Das ROHE Fehlerobjekt darf die Facade nie verlassen.');

    final text = gemeldet.toString();
    expect(text, 'PlatformException code=keystore_defekt',
        reason: 'Nur der Typ und der konstante Plugin-Code — `message` und '
            '`details` sind beliebiger Fremdtext.');
    expect(text, isNot(contains(_refreshToken)));
    expect(text, isNot(contains('nutzer@example.de')));
    expect(text, isNot(contains('access_token')));
  });
}
