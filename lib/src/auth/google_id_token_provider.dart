import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show AuthException;

import '../config/supabase_config.dart';

/// Supplies the Google ID token for the native sign-in flow. null = user
/// cancelled; an exception means the caller falls back to web OAuth.
abstract class GoogleIdTokenProvider {
  Future<String?> getIdToken();
}

/// Production implementation on google_sign_in v7. The native sheet shows
/// the consent-screen app name instead of the Supabase domain, which is the
/// whole point of this flow.
class GoogleSignInIdTokenProvider implements GoogleIdTokenProvider {
  const GoogleSignInIdTokenProvider();

  // initialize() may run only once per process.
  static Future<void>? _initialization;

  @override
  Future<String?> getIdToken() async {
    final signIn = GoogleSignIn.instance;
    _initialization ??= signIn.initialize(
      // iOS needs its own client for the URL-scheme callback; Android runs
      // through serverClientId, whose audience Supabase knows.
      clientId: defaultTargetPlatform == TargetPlatform.iOS
          ? EatovaSupabaseConfig.googleIosClientId
          : null,
      serverClientId: EatovaSupabaseConfig.googleWebClientId,
    );
    await _initialization;
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
/// OAuth fallback; user cancellation throws AuthException.
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
    throw const AuthException('Google Login wurde abgebrochen.');
  }
  await exchangeIdToken(idToken);
  return true;
}
