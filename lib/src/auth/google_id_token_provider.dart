import 'dart:developer' as dev;

import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../config/supabase_config.dart';
import 'auth_exceptions.dart';

/// Supplies the Google ID token for the native sign-in flow. null = user
/// cancelled; an exception means the caller falls back to web OAuth.
abstract class GoogleIdTokenProvider {
  Future<String?> getIdToken();
}

/// Optional capability of a [GoogleIdTokenProvider]: ends the device's
/// Google sign-in. Both calls are best effort and never throw.
abstract interface class GoogleSessionRevoker {
  /// After the app's sign-out: the next Google sign-in offers the account
  /// chooser again instead of silently reusing the last account.
  Future<void> signOut();

  /// After the account was deleted: also revokes the app's Google grant
  /// where the platform can (iOS); Android clears the credential state.
  Future<void> disconnect();
}

/// Remembers a one-shot initialization — but only a SUCCESSFUL one.
///
/// `google_sign_in` allows `initialize()` exactly once per process, so its
/// future has to be cached. Caching it with `??=` cached FAILURES too: after
/// one bad moment (Play Services mid-update, a freshly flashed device, a work
/// profile) every later login re-awaited the same rejected future and dropped
/// to the web OAuth sheet — the very sheet showing the Supabase domain this
/// flow exists to avoid — until the app was restarted (P4-04).
///
/// Concurrent callers still share ONE run; only a run that threw is forgotten.
class RetryableInitialization {
  Future<void>? _laufend;

  /// True while a run is remembered: pending, or finished successfully.
  @visibleForTesting
  bool get isRemembered => _laufend != null;

  /// Starts [start] once and awaits the remembered run on every later call.
  Future<void> run(Future<void> Function() start) async {
    final laufend = _laufend;
    if (laufend != null) return laufend;
    final frisch = start();
    _laufend = frisch;
    try {
      await frisch;
    } catch (_) {
      // Drop only OUR run: a newer one started meanwhile must survive.
      if (identical(_laufend, frisch)) _laufend = null;
      rethrow;
    }
  }
}

/// Production implementation on google_sign_in v7. The native sheet shows
/// the consent-screen app name instead of the Supabase domain, which is the
/// whole point of this flow.
///
/// No `nonce` is passed: `initialize()` runs exactly ONCE per process and
/// `authenticate()` takes none, so any nonce would be a per-process constant
/// and could not bind a single sign-in — see
/// docs/superpowers/specs/2026-08-05-google-native-signin-design.md.
class GoogleSignInIdTokenProvider
    implements GoogleIdTokenProvider, GoogleSessionRevoker {
  const GoogleSignInIdTokenProvider();

  // initialize() may run only once per process — a FAILED attempt is not a run.
  static final RetryableInitialization _initialization =
      RetryableInitialization();

  /// Sign-out and disconnect run one after another, so a deletion's
  /// disconnect keeps its user until the sign-out that follows it.
  static Future<void> _revocations = Future<void>.value();

  /// Upper bound per revocation; a hung platform call must not block the
  /// next one. Settable only so a test need not wait ten seconds.
  @visibleForTesting
  static Duration revokeTimeout = const Duration(seconds: 10);

  static Future<GoogleSignIn> _initialized() async {
    final signIn = GoogleSignIn.instance;
    await _initialization.run(
      () => signIn.initialize(
        // iOS needs its own client for the URL-scheme callback; Android runs
        // through serverClientId, whose audience Supabase knows.
        clientId: defaultTargetPlatform == TargetPlatform.iOS
            ? EatovaSupabaseConfig.googleIosClientId
            : null,
        serverClientId: EatovaSupabaseConfig.googleWebClientId,
      ),
    );
    return signIn;
  }

  @override
  Future<void> signOut() => _revoke('sign-out', (signIn) => signIn.signOut());

  @override
  Future<void> disconnect() => _revoke('disconnect', (signIn) async {
    // iOS keeps the account in the keychain, not in memory, across launches:
    // restore it silently first, or there is no grant to revoke. Android
    // would show UI for this, and its disconnect revokes nothing more.
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      await signIn.attemptLightweightAuthentication();
    }
    await signIn.disconnect();
  });

  Future<void> _revoke(
    String action,
    Future<void> Function(GoogleSignIn signIn) call,
  ) {
    final next = _revocations.then((_) async {
      try {
        await _initialized().then(call).timeout(revokeTimeout);
      } catch (error) {
        // Best effort. Only the type: an exception text may name the account.
        dev.log('Google $action skipped (${error.runtimeType})',
            name: 'eatova_auth');
      }
    });
    _revocations = next;
    return next;
  }

  @override
  Future<String?> getIdToken() async {
    final signIn = await _initialized();
    try {
      final account = await signIn.authenticate();
      return account.authentication.idToken;
    } on GoogleSignInException catch (error) {
      if (error.code == GoogleSignInExceptionCode.canceled) {
        return null;
      }
      rethrow;
    }
  }
}

/// Native Google login flow, decoupled from Supabase so it is testable
/// without a SupabaseClient. true = signed in, false = caller starts the web
/// OAuth fallback; user cancellation throws [AuthCancelledException].
Future<bool> runNativeGoogleSignIn({
  required GoogleIdTokenProvider tokenProvider,
  required Future<void> Function(String idToken) exchangeIdToken,
}) async {
  final String? idToken;
  try {
    idToken = await tokenProvider.getIdToken();
  } on Object {
    return false;
  }
  if (idToken == null) {
    throw const AuthCancelledException('Google');
  }
  await exchangeIdToken(idToken);
  return true;
}
