import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart' show closeInAppWebView;

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

  static Future<void> initialize() async {
    // supabase_flutter 2.14 hat den Init-Parameter `anonKey` zugunsten von
    // `publishableKey` deprecatet (akzeptiert weiterhin den Legacy-anon-JWT).
    // Unser interner Konstanten-Name bleibt `anonKey` (liest SUPABASE_ANON_KEY).
    await Supabase.initialize(url: url, publishableKey: anonKey);
    _wireOAuthSheetDismiss();
  }

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
