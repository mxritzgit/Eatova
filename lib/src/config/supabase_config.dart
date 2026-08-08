import 'dart:developer' as dev;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart' show closeInAppWebView;

import '../services/local_cache.dart' show KeyValueStore, SharedPreferencesStore;
import '../services/secure_cache_store.dart'
    show PluginSecureKeyStore, SecureKeyStore;

class EatovaSupabaseConfig {
  const EatovaSupabaseConfig._();

  static const String oauthRedirectUrl = 'eatova://login-callback/';

  // Supabase Anon-Key ist by-design im Client-Bundle extrahierbar
  // (JWT mit role:anon). Defaults im Source sind daher KEIN Secret-Leak
  // — sie machen `flutter run` ohne extra Flags reproduzierbar moeglich.
  // Override fuer CI / staging / prod via --dart-define-from-file=dart_defines.json
  // bleibt unveraendert moeglich, der dart-define hat Vorrang vor dem Default.
  static const String url = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://ftoozzvmduptrvrrrshb.supabase.co',
  );

  static const String anonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue:
        'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImZ0b296enZtZHVwdHJ2cnJyc2hiIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzc4NDEyOTAsImV4cCI6MjA5MzQxNzI5MH0.5kx8LowjRc8q8uWqJmUGU8ZjCnplSRDC1NGhm-oG7to',
  );

  // Google-OAuth-Client-IDs (GCP-Projekt inlaid-marker-469401-v6, siehe
  // docs/superpowers/specs/2026-08-05-google-native-signin-design.md).
  // Client-IDs sind oeffentlich (im Bundle extrahierbar), KEINE Secrets -
  // gleiches Muster wie SUPABASE_URL oben.
  static const String googleWebClientId = String.fromEnvironment(
    'GOOGLE_WEB_CLIENT_ID',
    defaultValue:
        '534676906581-fi1vr2d0qvhsabh6hmbcvlap5i8t5557.apps.googleusercontent.com',
  );

  static const String googleIosClientId = String.fromEnvironment(
    'GOOGLE_IOS_CLIENT_ID',
    defaultValue:
        '534676906581-h9no9hlboqtm3mfn56r95sg5c7n8no0u.apps.googleusercontent.com',
  );

  /// Storage-Key der persistierten Session.
  ///
  /// MUSS Zeichen fuer Zeichen dem Default aus `Supabase.initialize`
  /// entsprechen (supabase_flutter-2.17.1, `lib/src/supabase.dart:132-133`):
  /// `"sb-${Uri.parse(url).host.split(".").first}-auth-token"`. Waehlten wir
  /// einen eigenen Namen, faende die Einmal-Migration die Bestands-Session
  /// nicht und JEDER vorhandene Nutzer waere beim Update ausgeloggt.
  static final String sessionPersistKey =
      'sb-${Uri.parse(url).host.split('.').first}-auth-token';

  static Future<void> initialize() async {
    // supabase_flutter 2.14 hat den Init-Parameter `anonKey` zugunsten von
    // `publishableKey` deprecatet (akzeptiert weiterhin den Legacy-anon-JWT).
    // Unser interner Konstanten-Name bleibt `anonKey` (liest SUPABASE_ANON_KEY).
    //
    // C5: OHNE `authOptions` greift `SharedPreferencesLocalStorage` und legt
    // Access- UND Refresh-Token als Klartext-JSON in genau die Datei, deren
    // Health-Blobs seit 7f895f9 AES-256-GCM-verschluesselt sind. Der
    // Angreifer, gegen den die Verschluesselung gebaut wurde (Extraktion vom
    // ruhenden Geraet), nimmt dann einfach den Refresh-Token.
    await Supabase.initialize(
      url: url,
      publishableKey: anonKey,
      authOptions: FlutterAuthClientOptions(
        localStorage: buildSessionStorage(),
        // Ohne diesen Override laege der PKCE-Code-Verifier als letzter
        // Klartext-Auth-Baustein in SharedPreferences
        // (SharedPreferencesGotrueAsyncStorage) — siehe
        // [SecurePkceAsyncStorage].
        pkceAsyncStorage: buildPkceStorage(),
      ),
    );
    _wireOAuthSheetDismiss();
  }

  /// Baut den Session-Storage. Die optionalen Nahtstellen existieren nur fuer
  /// Tests — in Produktion ist beides null.
  @visibleForTesting
  static SecureSessionLocalStorage buildSessionStorage({
    SecureKeyStore? secureStore,
    KeyValueStore? legacyStore,
  }) =>
      SecureSessionLocalStorage(
        persistSessionKey: sessionPersistKey,
        secureStore: secureStore,
        legacyStore: legacyStore,
      );

  /// Baut den PKCE-Verifier-Storage — analoge Naht zu [buildSessionStorage].
  @visibleForTesting
  static SecurePkceAsyncStorage buildPkceStorage({
    SecureKeyStore? secureStore,
  }) =>
      SecurePkceAsyncStorage(secureStore: secureStore);

  /// SFSafariViewController (iOS) / Chrome Custom Tab (Android) wissen
  /// nicht von alleine dass der OAuth-Flow durch ist - die Sheet bleibt
  /// offen bis der User sie manuell schliesst. Hier hoeren wir auf den
  /// signedIn-Event und dismissen die Sheet sobald die Session da ist.
  ///
  /// closeInAppWebView ist ein No-Op wenn gar kein in-app Browser auf
  /// ist - also unbedenklich bei Session-Restore oder Email/Password-
  /// Login (wo keine Sheet aufging).
  static void _wireOAuthSheetDismiss() {
    Supabase.instance.client.auth.onAuthStateChange.listen((data) {
      if (data.event == AuthChangeEvent.signedIn) {
        closeInAppWebView();
      }
    });
  }
}

/// C5-Nachtrag: der PKCE-Code-Verifier im OS-Keystore statt in
/// SharedPreferences.
///
/// Der Verifier ist kurzlebig (lebt vom Start des OAuth-Flows bis zum
/// Code-Austausch), aber wer ihn UND den abgefangenen Callback-Link hat, kann
/// den Austausch selbst durchfuehren. Vor allem war er nach C5 der letzte
/// Auth-Baustein, der noch im Klartext in `FlutterSharedPreferences.xml` lag
/// (gotrue-Default: `SharedPreferencesGotrueAsyncStorage`).
///
/// Bewusst OHNE catch-Politik: die drei Methoden laufen nur waehrend eines
/// interaktiven OAuth-Flows (nie beim Boot). Ein Keystore-Fehler soll dort
/// als Login-Fehler sichtbar werden — ein verschluckter `setItem`-Fehler
/// wuerde denselben Flow Minuten spaeter mit einem unverstaendlicheren
/// „code verifier missing" scheitern lassen.
///
/// Keine Migration noetig: betroffen waere nur ein OAuth-Flow, der GENAU
/// waehrend des App-Updates offen war — der Nutzer tippt dann schlicht noch
/// einmal auf „Mit Google anmelden". Ein liegen gebliebener Alt-Verifier in
/// den Prefs ist ohne zugehoerigen Autorisierungs-Code wertlos und verfaellt
/// mit ihm.
class SecurePkceAsyncStorage extends GotrueAsyncStorage {
  SecurePkceAsyncStorage({SecureKeyStore? secureStore})
      : _secure = secureStore ?? const PluginSecureKeyStore();

  final SecureKeyStore _secure;

  @override
  Future<String?> getItem({required String key}) => _secure.read(key);

  @override
  Future<void> setItem({required String key, required String value}) =>
      _secure.write(key, value);

  @override
  Future<void> removeItem({required String key}) => _secure.delete(key);
}

/// C5: Session-Persistenz im OS-Keystore statt in SharedPreferences.
///
/// Der Session-String enthaelt Access- UND Refresh-Token. Der Refresh-Token
/// ist der Generalschluessel: mit ihm holt sich ein Angreifer beliebig neue
/// Access-Tokens und liest ueber das Netz Mahlzeiten, Gewicht, Schlaf und
/// Coach-Chat — ohne einen einzigen der verschluesselten Cache-Blobs
/// anzufassen.
///
/// Bewusst KEIN Envelope wie beim Cache: der Session-String ist ~1 kB und
/// wird nur beim Login und beim Token-Refresh geschrieben (nicht bei jeder
/// Mahlzeit). Die Begruendung im Header von `secure_cache_store.dart`, die den
/// Plugin-Channel aus dem heissen Pfad haelt, trifft hier also nicht zu — hier
/// ist der Keystore direkt der einfachere und staerkere Weg.
///
/// Die Keystore-Optionen (`resetOnError: false`,
/// `first_unlock_this_device`) kommen aus [PluginSecureKeyStore] und werden
/// bewusst WIEDERVERWENDET statt neu erfunden: `first_unlock` ist noetig,
/// damit der Token-Refresh im Hintergrund nach einem Reboot funktioniert, und
/// `_this_device` haelt ihn aus der iCloud-Keychain.
class SecureSessionLocalStorage extends LocalStorage {
  SecureSessionLocalStorage({
    required this.persistSessionKey,
    SecureKeyStore? secureStore,
    KeyValueStore? legacyStore,
  })  : _secure = secureStore ?? const PluginSecureKeyStore(),
        _legacyOverride = legacyStore;

  final String persistSessionKey;
  final SecureKeyStore _secure;
  final KeyValueStore? _legacyOverride;

  bool _migrationDone = false;

  @override
  Future<void> initialize() => _migrateLegacySession();

  /// EINMAL-MIGRATION der Bestandsnutzer.
  ///
  /// Ohne sie waeren beim naechsten Update ALLE eingeloggten Nutzer
  /// ausgeloggt: ihre Session liegt in SharedPreferences, der neue Storage
  /// liest aber nur den Keystore. Laeuft in `initialize()`, also VOR dem
  /// ersten `hasAccessToken()` von `SupabaseAuth.initialize`
  /// (supabase_auth.dart:105-107).
  ///
  /// Reihenfolge: erst in den Keystore schreiben, DANN den Klartext raeumen.
  /// Andersherum wuerde ein Fehler beim Schreiben die Session vernichten.
  Future<void> _migrateLegacySession() async {
    if (_migrationDone) return;
    _migrationDone = true;
    try {
      final legacy = _legacyOverride ?? await SharedPreferencesStore.create();
      final plain = await legacy.getString(persistSessionKey);
      if (plain == null || plain.isEmpty) return;

      final existing = await _secure.read(persistSessionKey);
      if (existing == null || existing.isEmpty) {
        await _secure.write(persistSessionKey, plain);
      }
      // Auch wenn der Keystore schon eine (neuere) Session hatte: der
      // Klartext-Rest muss weg. Er ist genau das Leck, um das es geht.
      await legacy.remove(persistSessionKey);
    } catch (e, s) {
      // NIEMALS werfen: `SupabaseAuth.initialize` ruft `initialize()` ohne
      // try/catch — eine Exception hier waere ein Boot-Fehler der ganzen App.
      // Die Session bleibt dann im Klartext liegen und der naechste Start
      // versucht es erneut; KEIN stiller Klartext-Fallback beim Lesen.
      dev.log('SecureSessionLocalStorage: Migration fehlgeschlagen',
          error: e, stackTrace: s, name: 'supabase_config');
    }
  }

  @override
  Future<bool> hasAccessToken() async => (await accessToken()) != null;

  @override
  Future<String?> accessToken() async {
    await _migrateLegacySession();
    try {
      final value = await _secure.read(persistSessionKey);
      return (value == null || value.isEmpty) ? null : value;
    } catch (e, s) {
      // Ein Keystore-Fehler bedeutet "diese Session ist nicht lesbar", nicht
      // "die App startet nicht". Der Nutzer landet auf dem Login-Screen; der
      // Eintrag bleibt liegen und ist nach einer Erholung wieder da.
      dev.log('SecureSessionLocalStorage: Session-Read fehlgeschlagen',
          error: e, stackTrace: s, name: 'supabase_config');
      return null;
    }
  }

  @override
  Future<void> persistSession(String persistSessionString) async {
    try {
      await _secure.write(persistSessionKey, persistSessionString);
    } catch (e, s) {
      dev.log('SecureSessionLocalStorage: Session-Write fehlgeschlagen',
          error: e, stackTrace: s, name: 'supabase_config');
    }
  }

  @override
  Future<void> removePersistedSession() async {
    try {
      await _secure.delete(persistSessionKey);
    } catch (e, s) {
      dev.log('SecureSessionLocalStorage: Session-Delete fehlgeschlagen',
          error: e, stackTrace: s, name: 'supabase_config');
    }
    // Sicherheitsnetz: raeumt den Klartext-Slot auch dann, wenn die Migration
    // nie durchlief (z. B. weil der Keystore beim Start defekt war). Ein
    // Logout muss den Token in JEDEM Fall vom Geraet nehmen.
    try {
      final legacy = _legacyOverride ?? await SharedPreferencesStore.create();
      await legacy.remove(persistSessionKey);
    } catch (e, s) {
      dev.log('SecureSessionLocalStorage: Legacy-Purge fehlgeschlagen',
          error: e, stackTrace: s, name: 'supabase_config');
    }
  }
}
