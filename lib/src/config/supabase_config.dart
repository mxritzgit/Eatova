import 'dart:async';
import 'dart:developer' as dev;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart' show closeInAppWebView;

import '../services/crash_reporter.dart' show CrashReporter;
import '../services/local_cache.dart' show KeyValueStore, SharedPreferencesStore;
import '../services/secure_cache_store.dart'
    show PluginSecureKeyStore, SecureKeyStore;

class EatovaSupabaseConfig {
  const EatovaSupabaseConfig._();

  static const String oauthRedirectUrl = 'eatova://login-callback/';

  /// Scheme and host of the only legitimate callback, derived from
  /// [oauthRedirectUrl] rather than literalised again — a later scheme change
  /// would otherwise silently deafen the predicate.
  static final Uri _oauthRedirect = Uri.parse(oauthRedirectUrl);

  // The Supabase anon key is extractable from the client bundle by design
  // (JWT with role:anon), so source defaults are NOT a secret leak — they make
  // `flutter run` work without extra flags. dart-define overrides win.
  static const String url = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://ftoozzvmduptrvrrrshb.supabase.co',
  );

  static const String anonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue:
        'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImZ0b296enZtZHVwdHJ2cnJyc2hiIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzc4NDEyOTAsImV4cCI6MjA5MzQxNzI5MH0.5kx8LowjRc8q8uWqJmUGU8ZjCnplSRDC1NGhm-oG7to',
  );

  // Google OAuth client IDs (GCP project inlaid-marker-469401-v6, see
  // docs/superpowers/specs/2026-08-05-google-native-signin-design.md).
  // Client IDs are public, NOT secrets — same pattern as SUPABASE_URL above.
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

  /// Storage key of the persisted session.
  ///
  /// MUST match the `Supabase.initialize` default byte for byte
  /// (supabase_flutter-2.17.1, `lib/src/supabase.dart:132-133`). A custom name
  /// would make the one-shot migration miss existing sessions and log every
  /// user out on update.
  static final String sessionPersistKey =
      'sb-${Uri.parse(url).host.split('.').first}-auth-token';

  static Future<void> initialize() async {
    // supabase_flutter 2.14 deprecated the `anonKey` init parameter in favour
    // of `publishableKey` (legacy anon JWT still accepted); the internal
    // constant keeps the name `anonKey`.
    //
    // C5: WITHOUT `authOptions`, `SharedPreferencesLocalStorage` stores access
    // and refresh token as plaintext JSON in the same file whose health blobs
    // are AES-256-GCM encrypted — an attacker with the device at rest just
    // takes the refresh token.
    await Supabase.initialize(
      url: url,
      publishableKey: anonKey,
      authOptions: FlutterAuthClientOptions(
        localStorage: buildSessionStorage(),
        // Without this override the PKCE code verifier would be the last
        // plaintext auth item in SharedPreferences — see
        // [SecurePkceAsyncStorage].
        pkceAsyncStorage: buildPkceStorage(),
        // Without this predicate supabase_flutter's default heuristic decides
        // what counts as a login — see [isOAuthCallbackDeeplink].
        detectSessionInUriPredicate: isOAuthCallbackDeeplink,
      ),
    );
    _wireOAuthSheetDismiss();
  }

  /// Builds the session storage. The optional seams exist for tests only; in
  /// production both are null.
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

  /// Builds the PKCE verifier storage — same seam as [buildSessionStorage].
  @visibleForTesting
  static SecurePkceAsyncStorage buildPkceStorage({
    SecureKeyStore? secureStore,
  }) =>
      SecurePkceAsyncStorage(secureStore: secureStore);

  /// Decides which incoming deep link is treated as an auth callback
  /// (`detectSessionInUriPredicate`).
  ///
  /// The supabase_flutter default sends any URI carrying `access_token`,
  /// `code` or an error param (query OR fragment) to `getSessionFromUrl`,
  /// which skips the PKCE check whenever an `access_token` is present. Since
  /// the Android intent filter is BROWSABLE, any app or web page could hand us
  /// a session and log the user into an attacker account.
  ///
  /// Only the real PKCE callback passes: our scheme, our host, a `code` in the
  /// query. Implicit-flow tokens are rejected, fragment included.
  /// `error`/`error_description` are dropped too — nothing renders them, and
  /// reset/email change run over 8-digit codes, so no recovery link needs to
  /// get through here.
  @visibleForTesting
  static bool isOAuthCallbackDeeplink(Uri uri) {
    if (uri.scheme != _oauthRedirect.scheme ||
        uri.host != _oauthRedirect.host) {
      return false;
    }
    try {
      final query = uri.queryParameters;
      final fragment = Uri.splitQueryString(uri.fragment);
      bool traegt(String name) =>
          query.containsKey(name) || fragment.containsKey(name);

      if (traegt('access_token') ||
          traegt('refresh_token') ||
          traegt('token_type')) {
        return false;
      }
      return query.containsKey('code');
    } on FormatException {
      // Broken percent escapes make `queryParameters`/`splitQueryString`
      // throw. Do NOT rethrow: supabase_flutter calls the predicate BEFORE its
      // own try/catch, so it would surface as an unhandled zone error.
      return false;
    }
  }

  /// Dismisses the in-app OAuth sheet on `signedIn`: SFSafariViewController /
  /// Chrome Custom Tab do not close themselves when the flow completes.
  /// closeInAppWebView is a no-op when no in-app browser is open, so session
  /// restore and email/password login are unaffected.
  static void _wireOAuthSheetDismiss() {
    wireOAuthSheetDismiss(Supabase.instance.client.auth.onAuthStateChange);
  }

  /// The listener behind [_wireOAuthSheetDismiss]; the stream and the close
  /// call are seams for tests, production passes neither.
  ///
  /// `onError` is NOT optional: gotrue pushes refresh failures into this
  /// stream as errors (`notifyException`), typically an
  /// `AuthRetryableFetchException` when the auto-refresh timer fires while iOS
  /// has the app in the background without network. This was the last
  /// listener without a handler, so that error became an unhandled zone error
  /// and a "fatal" Sentry event (FLUTTER-8, 2026-08-23). Log only: the
  /// AuthGate subscribes to the same stream and already reports what matters.
  @visibleForTesting
  static StreamSubscription<AuthState> wireOAuthSheetDismiss(
    Stream<AuthState> authStates, {
    Future<void> Function() closeSheet = closeInAppWebView,
  }) {
    return authStates.listen((data) {
      if (data.event == AuthChangeEvent.signedIn) {
        unawaited(closeSheet());
      }
    }, onError: (Object error, StackTrace stack) {
      dev.log(
          'Auth-Stream-Fehler (OAuth-Sheet-Listener) — nur geloggt, AuthGate '
          'meldet',
          name: 'supabase_config', error: error, stackTrace: stack);
    });
  }
}

/// C5 follow-up: the PKCE code verifier in the OS keystore instead of
/// SharedPreferences, where it was the last plaintext auth item.
///
/// Deliberately no catch policy: all three methods run only during an
/// interactive OAuth flow, never at boot, so a keystore error should surface
/// as a login error rather than a later "code verifier missing".
///
/// No migration needed: only a flow open exactly across the app update is
/// affected, and a stale verifier is worthless without its auth code.
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

/// C5: session persistence in the OS keystore instead of SharedPreferences.
/// The session string carries the refresh token — the master key to all
/// server-side health data.
///
/// No envelope like the cache: ~1 kB, written only on login and token refresh,
/// so the hot-path argument in `secure_cache_store.dart` does not apply.
///
/// Keystore options (`resetOnError: false`, `first_unlock_this_device`) are
/// reused from [PluginSecureKeyStore]: `first_unlock` keeps background token
/// refresh working after a reboot, `_this_device` keeps it out of iCloud.
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

  /// One report per operation kind per process.
  ///
  /// The read path runs on EVERY start and several times per boot, so a
  /// permanently broken keystore would fill the Sentry quota with the same
  /// report. Split per operation because read and delete failures are
  /// different incidents, and a shared counter would silence the rare delete
  /// failure behind the frequent read one. Instance field, not static:
  /// [buildSessionStorage] runs once per process, and tests get fresh state.
  final Set<String> _gemeldeteVorgaenge = <String>{};

  /// Reports a keystore error exactly once per [vorgang].
  ///
  /// The RAW error goes to the facade; the allowlist in `sanitizeForReport`
  /// decides what leaves. For a `PlatformException` only type name and `code`
  /// survive. The session string is never passed along.
  ///
  /// [vorgang] is a constant from this source and becomes the `context` tag:
  /// it says WHICH access failed, not on which key or with which value.
  void _meldeEinmal(String vorgang, Object fehler, StackTrace stack) {
    if (!_gemeldeteVorgaenge.add(vorgang)) return;
    // `capture` never throws and must not be awaited here: every caller sits
    // in a path supabase_flutter invokes without try/catch.
    unawaited(CrashReporter.capture(fehler, stack, context: vorgang));
  }

  @override
  Future<void> initialize() => _migrateLegacySession();

  /// ONE-SHOT migration for existing users: their session lives in
  /// SharedPreferences, the new storage reads only the keystore. Runs in
  /// `initialize()`, before the first `hasAccessToken()`.
  ///
  /// Order matters: write to the keystore first, THEN purge the plaintext —
  /// the other way round a write failure would destroy the session.
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
      // Even if the keystore already held a newer session, the plaintext
      // leftover must go — it is exactly the leak in question.
      await legacy.remove(persistSessionKey);
    } catch (e, s) {
      // NEVER throw: `SupabaseAuth.initialize` calls `initialize()` without
      // try/catch, so an exception here would fail the whole app boot. The
      // session stays in plaintext and the next start retries; there is no
      // silent plaintext fallback on the read path.
      dev.log('SecureSessionLocalStorage: Migration fehlgeschlagen',
          error: e, stackTrace: s, name: 'supabase_config');
      // A permanently failing migration leaves the session in plaintext — the
      // only state of this class that silently breaks a compliance promise.
      _meldeEinmal('session_migrate', e, s);
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
      // A keystore error means "this session is unreadable", not "the app
      // won't start": the user lands on the login screen and the entry
      // survives. Still reported — if the keystore never recovers this is a
      // forced logout on every start that nobody else would notice.
      dev.log('SecureSessionLocalStorage: Session-Read fehlgeschlagen',
          error: e, stackTrace: s, name: 'supabase_config');
      _meldeEinmal('session_read', e, s);
      return null;
    }
  }

  @override
  Future<void> persistSession(String persistSessionString) async {
    try {
      await _secure.write(persistSessionKey, persistSessionString);
    } catch (e, s) {
      // The write is what makes the session durable. If it fails the app runs
      // on until process end and the user is logged out on the next start,
      // with nothing visible now.
      dev.log('SecureSessionLocalStorage: Session-Write fehlgeschlagen',
          error: e, stackTrace: s, name: 'supabase_config');
      _meldeEinmal('session_write', e, s);
    }
  }

  @override
  Future<void> removePersistedSession() async {
    try {
      await _secure.delete(persistSessionKey);
    } catch (e, s) {
      // The worst case of this class: the logout does NOT take effect locally
      // and the refresh token stays in the keystore, while the UI already
      // shows the login screen. Only visible here.
      dev.log('SecureSessionLocalStorage: Session-Delete fehlgeschlagen',
          error: e, stackTrace: s, name: 'supabase_config');
      _meldeEinmal('session_delete', e, s);
    }
    // Safety net: purges the plaintext slot even if the migration never ran.
    // A logout must remove the token from the device in EVERY case.
    try {
      final legacy = _legacyOverride ?? await SharedPreferencesStore.create();
      await legacy.remove(persistSessionKey);
    } catch (e, s) {
      // Own operation, not merged with `session_delete`: this is the PLAINTEXT
      // slot failing to clear, so the token stays in its unprotected form.
      dev.log('SecureSessionLocalStorage: Legacy-Purge fehlgeschlagen',
          error: e, stackTrace: s, name: 'supabase_config');
      _meldeEinmal('session_legacy_purge', e, s);
    }
  }
}
