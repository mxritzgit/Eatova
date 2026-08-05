import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show AuthException;

import '../config/supabase_config.dart';

/// Liefert das Google-ID-Token fuer den nativen Sign-In-Flow.
///
/// null = User hat das Google-Sheet abgebrochen. Exceptions = technischer
/// Fehler (keine Play Services, Client-Propagation, ...) - der Aufrufer
/// faellt dann auf den Web-OAuth-Flow zurueck.
abstract class GoogleIdTokenProvider {
  Future<String?> getIdToken();
}

/// Produktiv-Implementierung auf google_sign_in v7. Das native Sheet zeigt
/// den Consent-Screen-App-Namen ("Eatova") statt der Supabase-Domain -
/// das ist der ganze Grund fuer diesen Flow.
class GoogleSignInIdTokenProvider implements GoogleIdTokenProvider {
  const GoogleSignInIdTokenProvider();

  // initialize() darf pro Prozess nur einmal laufen. Der Future wird
  // statisch gecacht, damit parallele/wiederholte Logins nicht doppelt
  // initialisieren (GoogleSignIn.instance ist selbst ein Singleton).
  static Future<void>? _initialization;

  @override
  Future<String?> getIdToken() async {
    final signIn = GoogleSignIn.instance;
    _initialization ??= signIn.initialize(
      // iOS braucht den eigenen iOS-Client (URL-Schema-Callback);
      // Android laeuft komplett ueber den serverClientId (Web-Client),
      // dessen Audience Supabase als erste client_id kennt.
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

/// Ablauf-Logik des nativen Google-Logins, von Supabase entkoppelt, damit
/// sie ohne SupabaseClient testbar ist (test/native_google_sign_in_test.dart).
///
/// true = eingeloggt. false = technischer Fehler, Aufrufer startet den
/// Web-OAuth-Fallback. User-Abbruch wirft AuthException mit deutscher
/// Meldung (Muster wie der bisherige Web-Flow-Abbruch).
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
