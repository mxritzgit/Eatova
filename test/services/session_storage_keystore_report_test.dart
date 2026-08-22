import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:eatova/src/config/supabase_config.dart';
import 'package:eatova/src/services/crash_reporter.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/secure_cache_store.dart';

// Full review 2026-08-19: `SecureSessionLocalStorage` swallowed every keystore
// error in a `dev.log` that never leaves the device.
//
// Case A (read fails): a device with a damaged keystore logs the user out
// silently on every start. Case B (delete fails): signing out has no local
// effect — the UI shows the login screen while the refresh token stays.
//
// Pinned here: each of the five error paths reports at all, with its own
// `context` tag (a read error must not silence the rare delete error), at most
// ONCE per operation and process, and without token, session content or plugin
// free text — only the error type plus the one detail `sanitizeForReport`
// lets through.

// Both values are separate constants and only interpolated below: a literal
// carrying the field name and a JWT-shaped value on the SAME line trips the CI
// secret scan (gitleaks, generic-api-key), even though nothing here is real.
const String _accessToken = 'eyJhbGciOiJIUzI1NiJ9.header-payload.sig';
const String _refreshToken = 'refresh-o5Xq7c9aTtZZ-nicht-im-report';
const String _sessionJson = '{"access_token":"$_accessToken",'
    '"refresh_token":"$_refreshToken","user":{"email":"nutzer@example.de"}}';

/// The error flutter_secure_storage really produces on Android: a
/// `PlatformException` with a constant `code` and arbitrary foreign text in
/// `message`/`details` — the shape the CrashReporter allowlist splits on.
PlatformException _keystoreFehler() => PlatformException(
      code: 'keystore_defekt',
      message: 'konnte $_refreshToken nicht entschluesseln',
      details: _sessionJson,
    );

/// Keystore that fails per operation on demand.
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

/// Plaintext slot that fails per operation on demand.
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

/// A reported incident as Sentry would see it.
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
    // The sink sits before the isActive gate and gets exactly the object that
    // would go to `Sentry.captureException`, sanitization included.
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

      // recoverSession() -> hasAccessToken() -> accessToken(), then every
      // further access of the running session.
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
