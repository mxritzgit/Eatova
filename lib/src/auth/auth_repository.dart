import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/supabase_config.dart';
import '../services/crash_reporter.dart';
import 'google_id_token_provider.dart';

class EatovaUser {
  const EatovaUser({required this.id, this.email, this.displayName});

  final String id;
  final String? email;
  final String? displayName;

  String get firstName {
    final name = displayName?.trim();
    if (name != null && name.isNotEmpty) {
      return name.split(RegExp(r'\s+')).first;
    }
    final mail = email?.trim();
    if (mail != null && mail.isNotEmpty) {
      return mail.split('@').first;
    }
    return 'Pilot';
  }
}

enum EatovaOAuthProvider { apple, google }

extension EatovaOAuthProviderLabel on EatovaOAuthProvider {
  OAuthProvider get supabaseProvider => switch (this) {
    EatovaOAuthProvider.apple => OAuthProvider.apple,
    EatovaOAuthProvider.google => OAuthProvider.google,
  };

  String get displayName => switch (this) {
    EatovaOAuthProvider.apple => 'Apple',
    EatovaOAuthProvider.google => 'Google',
  };
}

abstract class AuthRepository {
  EatovaUser? get currentUser;
  Stream<EatovaUser?> get authStateChanges;

  /// Stoesst die Passwort-Reset-Mail an. Die UI bestaetigt IMMER neutral —
  /// ob zur E-Mail ein Konto existiert (oder ein reines Google-Konto ohne
  /// Passwort), verraet weder Server noch App: alles andere waere ein
  /// Konto-Enumerations-Leck.
  Future<void> sendPasswordReset(String email);

  /// Feuert, wenn der Nutzer ueber den Reset-Mail-Link zurueckkommt
  /// (AuthChangeEvent.passwordRecovery): die Session ist dann bereits
  /// gueltig, und der AuthGate zeigt den Neues-Passwort-Dialog.
  Stream<void> get passwordRecoveryEvents;

  /// Setzt das Passwort des angemeldeten Nutzers (Recovery-Abschluss).
  Future<void> updatePassword(String newPassword);
  Future<void> signIn({required String email, required String password});
  Future<void> signUp({
    required String email,
    required String password,
    required String displayName,
  });
  Future<void> signInWithOAuth(EatovaOAuthProvider provider);
  Future<void> signOut();
}

class SupabaseAuthRepository implements AuthRepository {
  const SupabaseAuthRepository(
    this._client, {
    GoogleIdTokenProvider? googleIdTokenProvider,
  }) : _googleIdTokenProvider =
           googleIdTokenProvider ?? const GoogleSignInIdTokenProvider();

  final SupabaseClient _client;
  final GoogleIdTokenProvider _googleIdTokenProvider;

  @override
  EatovaUser? get currentUser => _mapUser(_client.auth.currentUser);

  @override
  Stream<EatovaUser?> get authStateChanges async* {
    yield currentUser;
    yield* _client.auth.onAuthStateChange.map(
      (event) => _mapUser(event.session?.user),
    );
  }

  @override
  Future<void> sendPasswordReset(String email) async {
    // redirect_to = App-Deep-Link: der Mail-Link fuehrt zurueck in die App,
    // supabase_flutter tauscht den Code gegen eine Session und feuert das
    // passwordRecovery-Event — dort haengt die Neues-Passwort-UI.
    await _client.auth.resetPasswordForEmail(
      email.trim(),
      redirectTo: EatovaSupabaseConfig.oauthRedirectUrl,
    );
  }

  @override
  Stream<void> get passwordRecoveryEvents => _client.auth.onAuthStateChange
      .where((e) => e.event == AuthChangeEvent.passwordRecovery)
      .map((_) {});

  @override
  Future<void> updatePassword(String newPassword) async {
    await _client.auth.updateUser(UserAttributes(password: newPassword));
  }

  @override
  Future<void> signIn({required String email, required String password}) async {
    await _client.auth.signInWithPassword(
      email: email.trim(),
      password: password,
    );
  }

  @override
  Future<void> signUp({
    required String email,
    required String password,
    required String displayName,
  }) async {
    // emailRedirectTo landet im Confirmation-Mail-Link. Sobald der User
    // den Confirm-Button drueckt, kehrt Supabase ueber das eatova://
    // Deep-Link-Scheme in die App zurueck - dann ist die Session sofort
    // gueltig und der AuthGate-Stream feuert wasLoggedOut->loggedIn.
    await _client.auth.signUp(
      email: email.trim(),
      password: password,
      emailRedirectTo: EatovaSupabaseConfig.oauthRedirectUrl,
      data: {'display_name': displayName.trim()},
    );
  }

  @override
  Future<void> signInWithOAuth(EatovaOAuthProvider provider) async {
    if (provider == EatovaOAuthProvider.google) {
      final nativeOk = await runNativeGoogleSignIn(
        tokenProvider: _googleIdTokenProvider,
        exchangeIdToken: (idToken) async {
          await _client.auth.signInWithIdToken(
            provider: OAuthProvider.google,
            idToken: idToken,
          );
        },
      );
      if (nativeOk) return;
      // Technischer Fehler im nativen Flow (keine Play Services, Client
      // noch nicht propagiert, ...) - Login soll nie kaputter sein als
      // frueher, also runter in den bewaehrten Web-Flow.
    }
    await _signInWithWebOAuth(provider);
  }

  /// Web-OAuth via Browser-Sheet - Standardweg fuer Apple, Fallback fuer
  /// Google (dort zeigt Google zwangsweise die Supabase-Domain an).
  ///
  /// inAppBrowserView oeffnet SFSafariViewController (iOS) bzw. Chrome
  /// Custom Tabs (Android) - ein Sheet das ueber der App liegt und sich
  /// automatisch schliesst sobald das eatova://login-callback/ Scheme
  /// greift. Fuehlt sich an wie "in der App geblieben", waehrend die
  /// Cookie- und Auth-Logik des echten System-Browsers benutzt wird.
  ///
  /// Wichtig: kein inAppWebView - das waere ein embedded WKWebView,
  /// den Google explizit fuer OAuth blockt (Account-Hijacking-Policy
  /// seit 2017).
  Future<void> _signInWithWebOAuth(EatovaOAuthProvider provider) async {
    final launched = await _client.auth.signInWithOAuth(
      provider.supabaseProvider,
      redirectTo: EatovaSupabaseConfig.oauthRedirectUrl,
      authScreenLaunchMode: LaunchMode.inAppBrowserView,
    );
    if (!launched) {
      throw AuthException('${provider.displayName} Login wurde abgebrochen.');
    }
  }

  @override
  Future<void> signOut() => _client.auth.signOut();

  EatovaUser? _mapUser(User? user) {
    if (user == null) return null;
    final metadata = user.userMetadata ?? <String, dynamic>{};
    final rawName = metadata['display_name'] ??
        metadata['full_name'] ??
        metadata['name'] ??
        metadata['user_name'];
    return EatovaUser(
      id: user.id,
      email: user.email,
      displayName: rawName is String ? rawName : null,
    );
  }
}

class PreviewAuthRepository implements AuthRepository {
  const PreviewAuthRepository();

  static const _previewUser = EatovaUser(
    id: 'preview-user',
    email: 'moritz@example.com',
    displayName: 'Moritz',
  );

  @override
  EatovaUser? get currentUser => _previewUser;

  @override
  Stream<EatovaUser?> get authStateChanges async* {
    yield _previewUser;
  }

  @override
  Future<void> sendPasswordReset(String email) async {}

  @override
  Stream<void> get passwordRecoveryEvents => const Stream.empty();

  @override
  Future<void> updatePassword(String newPassword) async {}

  @override
  Future<void> signIn({required String email, required String password}) async {}

  @override
  Future<void> signUp({
    required String email,
    required String password,
    required String displayName,
  }) async {}

  @override
  Future<void> signInWithOAuth(EatovaOAuthProvider provider) async {}

  @override
  Future<void> signOut() async {}
}

class InMemoryAuthRepository implements AuthRepository {
  InMemoryAuthRepository({EatovaUser? initialUser}) : _user = initialUser;

  EatovaUser? _user;
  final StreamController<EatovaUser?> _controller =
      StreamController<EatovaUser?>.broadcast();

  /// Fuer Tests: an welche Adressen ein Reset angestossen wurde.
  final List<String> passwordResets = <String>[];

  /// Fuer Tests: welche neuen Passwoerter gesetzt wurden.
  final List<String> passwordUpdates = <String>[];

  final StreamController<void> _recoveryController =
      StreamController<void>.broadcast();

  @override
  Future<void> sendPasswordReset(String email) async {
    passwordResets.add(email.trim());
  }

  @override
  Stream<void> get passwordRecoveryEvents => _recoveryController.stream;

  /// Simuliert den Klick auf den Reset-Mail-Link (Deep-Link zurueck in die
  /// App): supabase_flutter wuerde hier das passwordRecovery-Event feuern.
  void emitPasswordRecovery() => _recoveryController.add(null);

  @override
  Future<void> updatePassword(String newPassword) async {
    passwordUpdates.add(newPassword);
  }

  @override
  EatovaUser? get currentUser => _user;

  @override
  Stream<EatovaUser?> get authStateChanges async* {
    yield _user;
    yield* _controller.stream;
  }

  @override
  Future<void> signIn({required String email, required String password}) async {
    _user = EatovaUser(id: 'test-user', email: email, displayName: 'Test Pilot');
    _controller.add(_user);
  }

  @override
  Future<void> signUp({
    required String email,
    required String password,
    required String displayName,
  }) async {
    _user = EatovaUser(id: 'test-user', email: email, displayName: displayName);
    _controller.add(_user);
  }

  @override
  Future<void> signInWithOAuth(EatovaOAuthProvider provider) async {
    _user = EatovaUser(
      id: 'oauth-test-user',
      email: '${provider.displayName.toLowerCase()}@example.com',
      displayName: '${provider.displayName} Pilot',
    );
    _controller.add(_user);
  }

  @override
  Future<void> signOut() async {
    _user = null;
    _controller.add(null);
  }

  void dispose() {
    _controller.close();
    _recoveryController.close();
  }
}

/// Auth-Schicht nicht verfuegbar (`Supabase.instance` warf beim App-Build).
///
/// Der ehrliche Gegenpol zu [PreviewAuthRepository]: KEIN Nutzer statt eines
/// erfundenen. AuthGate zeigt damit den Login statt der Home-Page, und ein
/// Anmeldeversuch scheitert laut statt still ins Leere zu laufen.
class UnavailableAuthRepository implements AuthRepository {
  const UnavailableAuthRepository(this.cause);

  /// Woran der Aufbau des echten Repositories gescheitert ist. Steht im
  /// Crash-Report (Capture passiert beim Aufbau); die Nutzer-Meldung unten
  /// bleibt bewusst generisch — '$cause' kann interne URLs oder
  /// Assertion-Texte enthalten, das gehoert nicht auf Nutzer-Screens.
  final Object cause;

  static Future<Never> _fail() => Future.error(const AuthException(
      'Anmeldung derzeit nicht möglich. Bitte starte die App neu.'));

  @override
  EatovaUser? get currentUser => null;

  @override
  Stream<EatovaUser?> get authStateChanges async* {
    yield null;
  }

  @override
  Future<void> sendPasswordReset(String email) => _fail();

  @override
  Stream<void> get passwordRecoveryEvents => const Stream.empty();

  @override
  Future<void> updatePassword(String newPassword) => _fail();

  @override
  Future<void> signIn({required String email, required String password}) =>
      _fail();

  @override
  Future<void> signUp({
    required String email,
    required String password,
    required String displayName,
  }) =>
      _fail();

  @override
  Future<void> signInWithOAuth(EatovaOAuthProvider provider) => _fail();

  /// Bewusst gefahrlos: der Profil-Screen ruft signOut auch in Fehlerpfaden.
  @override
  Future<void> signOut() async {}
}

AuthRepository defaultAuthRepository() => buildDefaultAuthRepository();

/// Sentinel-Fund 1 (Nachverifikation 2026-08-08): vorher fing der Fallback
/// JEDEN Fehler und antwortete mit [PreviewAuthRepository] — deren
/// `currentUser` nie null ist. Aus „ich weiss nicht, ob jemand angemeldet
/// ist" wurde damit die positive Behauptung „angemeldet als preview-user",
/// gerendert als eingeloggte Ansicht ohne Anmeldung.
///
/// [allowPreview] haelt den gewollten Teil am Leben: In Debug/Test (Default
/// kDebugMode) bleibt der Preview-Komfort erhalten — die Flow-Tests pumpen
/// `EatovaApp()` ohne Repository und ohne Supabase und landen direkt auf der
/// Home-Page. Im Release-/Profile-Build gibt es stattdessen
/// [UnavailableAuthRepository] (Login-Screen, laute Fehler) und der wahre
/// Grund geht an den CrashReporter.
@visibleForTesting
AuthRepository buildDefaultAuthRepository({bool allowPreview = kDebugMode}) {
  try {
    return SupabaseAuthRepository(Supabase.instance.client);
  } catch (error, stack) {
    if (allowPreview) return const PreviewAuthRepository();
    unawaited(
        CrashReporter.capture(error, stack, context: 'auth-default-repository'));
    return UnavailableAuthRepository(error);
  }
}
