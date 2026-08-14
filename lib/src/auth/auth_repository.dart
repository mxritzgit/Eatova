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

/// Ergebnis von [AuthRepository.signUp].
///
/// GoTrue verschleiert eine schon vergebene Adresse bei aktiver
/// Mail-Bestaetigung bewusst: `POST /signup` antwortet wie bei einer frischen
/// Registrierung — gleicher Status, gleiche Form — nur mit LEEREM
/// `identities`-Array, und es geht keine Mail raus. Ohne diese Unterscheidung
/// verspricht die UI einen Code, der nie kommt.
///
/// Der Wert bleibt REPOSITORY-INTERN in dem Sinn, dass er nichts ueber ein
/// fremdes Konto in die UI traegt: er sagt dem Aufrufer nur, dass der
/// Registrier-Weg hier nicht weitergeht — welchen Satz der Nutzer dann sieht,
/// entscheidet die UI — und der bleibt neutral (Hauslinie gegen
/// Konto-Enumeration, siehe `AuthRepository.sendPasswordReset`).
enum SignUpOutcome {
  /// Registrierung angenommen: Konto angelegt, Bestaetigungscode unterwegs.
  created,

  /// Zu dieser Adresse gibt es bereits ein Konto (leeres `identities`-Array).
  /// Es kommt KEINE Mail — die Code-Seite waere eine Sackgasse.
  emailAlreadyRegistered,
}

abstract class AuthRepository {
  EatovaUser? get currentUser;
  Stream<EatovaUser?> get authStateChanges;

  /// Stoesst die Passwort-Reset-Mail an. Die UI bestaetigt IMMER neutral —
  /// ob zur E-Mail ein Konto existiert (oder ein reines Google-Konto ohne
  /// Passwort), verraet weder Server noch App: alles andere waere ein
  /// Konto-Enumerations-Leck.
  Future<void> sendPasswordReset(String email);

  /// Prueft den 6-stelligen Code aus der Passwort-Reset-Mail (OTP statt
  /// Link, {{ .Token }}-Template; Gueltigkeit mailer_otp_exp = 10 Min).
  /// Erfolg stellt die Session her — danach setzt [updatePassword] das neue
  /// Passwort.
  Future<void> verifyRecoveryCode({required String email, required String code});

  /// Prueft den 6-stelligen Code aus der Registrierungs-Bestaetigung.
  Future<void> verifySignupCode({required String email, required String code});

  /// Fordert die Registrierungs-Bestaetigung erneut an (neuer Code).
  Future<void> resendSignupCode(String email);

  /// Setzt das Passwort des angemeldeten Nutzers (Recovery-Abschluss).
  Future<void> updatePassword(String newPassword);

  // --- Konto-Aenderungen aus der App heraus (2026-08-10) --------------------
  //
  // Beide Wege benutzen GoTrue-Bordmittel statt selbstgebauter Token. Die
  // zugehoerige Server-Konfiguration steht in supabase/AUTH_EMAIL_OTP.md;
  // ohne sie sind die Codes wirkungslos oder kommen als Link.

  /// Fordert den Bestaetigungscode fuer eine Passwort-Aenderung an — GoTrue
  /// schickt ihn an die hinterlegte Adresse (`reauthenticate`).
  ///
  /// Nur fuer den EINGELOGGTEN Nutzer. Das Gegenstueck fuer „Passwort
  /// vergessen" (ausgeloggt) ist [sendPasswordReset].
  Future<void> startPasswordChange();

  /// Setzt das neue Passwort — nur zusammen mit dem Code aus
  /// [startPasswordChange].
  ///
  /// Der Code ist Pflicht, nicht Zierde: mit
  /// `security_update_password_require_reauthentication` lehnt GoTrue eine
  /// Aenderung ohne gueltige Nonce ab. Sonst koennte, wer eine fremde
  /// Sitzung erbeutet, das Passwort ohne Zugriff aufs Postfach tauschen.
  ///
  /// EINSCHRAENKUNG (Audit 2026-08-14, ungeklaert): ob der Server die Nonce
  /// wirklich bei JEDER Sitzung verlangt, ist aus dem Repo nicht belegbar —
  /// der Recovery-Weg kommt ohne sie durch. Der Widerspruch steht bei
  /// [AuthRepository.updatePassword]; bis er am Live-Projekt geklaert ist,
  /// ist die Nonce hier moeglicherweise nur eine Huerde der App.
  Future<void> confirmPasswordChange({
    required String code,
    required String newPassword,
  });

  /// Stoesst die Aenderung der Mailadresse an.
  ///
  /// Bei aktiver „sicherer E-Mail-Aenderung" verschickt GoTrue ZWEI Codes:
  /// einen an die bisherige und einen an die neue Adresse. Erst wenn beide
  /// ueber [confirmEmailChange] bestaetigt sind, traegt das Konto die neue
  /// Adresse — ein einzelnes erbeutetes Postfach genuegt also nicht.
  Future<void> startEmailChange(String newEmail);

  /// Bestaetigt EINEN der beiden Codes aus [startEmailChange]. [email] ist
  /// die Adresse, an die dieser Code ging (alte oder neue).
  Future<void> confirmEmailChange({
    required String email,
    required String code,
  });
  Future<void> signIn({required String email, required String password});

  /// Registriert die Adresse und meldet zurueck, OB der Weg weitergeht —
  /// siehe [SignUpOutcome]. Vorher war der Rueckgabewert `void` und die
  /// `AuthResponse` fiel auf den Boden; der Aufrufer konnte die schon
  /// vergebene Adresse deshalb nicht von einer frischen unterscheiden und
  /// schob die Code-Seite vor eine Mail, die nie kam (Audit 2026-08-14).
  Future<SignUpOutcome> signUp({
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
    // BEWUSST OHNE redirectTo: der Reset laeuft ueber den 6-stelligen Code
    // ({{ .Token }}-Template, AuthCodeScreen), nicht ueber einen Mail-Link.
    // Ein redirect_to wuerde nur dann greifen, wenn jemand das Server-Template
    // auf {{ .ConfirmationURL }} zuruecksetzt — und reaktivierte damit still
    // den kaperbaren eatova://-Deep-Link-Weg (Sicherheits-Audit 2026-08-09).
    // Ohne den Parameter im Code ist diese Drift ausgeschlossen.
    await _client.auth.resetPasswordForEmail(email.trim());
  }

  @override
  Future<void> verifyRecoveryCode(
      {required String email, required String code}) async {
    await _client.auth.verifyOTP(
      type: OtpType.recovery,
      email: email.trim(),
      token: code.trim(),
    );
  }

  @override
  Future<void> verifySignupCode(
      {required String email, required String code}) async {
    await _client.auth.verifyOTP(
      type: OtpType.signup,
      email: email.trim(),
      token: code.trim(),
    );
  }

  @override
  Future<void> resendSignupCode(String email) async {
    await _client.auth.resend(type: OtpType.signup, email: email.trim());
  }

  @override
  Future<void> updatePassword(String newPassword) async {
    // OFFENER WIDERSPRUCH (Audit 2026-08-14) — bewusst NICHT geraderueckt:
    // Dieser Aufruf setzt das Passwort OHNE Nonce, [confirmPasswordChange]
    // MIT; beide landen auf PUT /auth/v1/user. Laut supabase/AUTH_EMAIL_OTP.md
    // steht `security_update_password_require_reauthentication` auf true.
    // Genau eine der beiden Varianten muss falsch sein:
    //  (1) Der Server verlangt die Nonce immer — dann endet „Passwort
    //      vergessen" fuer JEDEN Nutzer hier in einer Sackgasse (der Fehler
    //      faellt in account_change_messages.dart in die Generik).
    //  (2) Der Server verlangt sie nur, wenn die Sitzung nicht frisch ist —
    //      dann kommt dieser Weg durch (verifyRecoveryCode legt die Sitzung
    //      unmittelbar davor an) und die Nonce in confirmPasswordChange ist
    //      serverseitig wirkungslos fuer genau die frischen Sitzungen.
    // Aus dem Repo ist keins von beidem belegbar; (2) passt dazu, dass der
    // Recovery-Weg seit 2026-08-08 unbeanstandet laeuft, waehrend die
    // Reauth-Pflicht erst am 2026-08-10 dazukam. Eine Aenderung auf Verdacht
    // zerstoert im Fall (2) „Passwort vergessen" fuer alle. Bis zur Klaerung
    // am Live-Projekt haelt test/auth_enumeration_test.dart beide
    // Wire-Formate fest, damit ein spaeterer Eingriff auffaellt.
    await _client.auth.updateUser(UserAttributes(password: newPassword));
  }

  @override
  Future<void> startPasswordChange() async {
    await _client.auth.reauthenticate();
  }

  @override
  Future<void> confirmPasswordChange({
    required String code,
    required String newPassword,
  }) async {
    // Gegenstueck zum Widerspruch in [updatePassword]: hier laeuft die Nonce
    // mit. Ueberspringt GoTrue sie bei frischen Sitzungen, schuetzt sie genau
    // die Sitzungsklasse nicht, gegen die der Doc-Kommentar der Schnittstelle
    // sie ins Feld fuehrt. Nicht auf Verdacht anfassen (Audit 2026-08-14).
    await _client.auth.updateUser(
      UserAttributes(password: newPassword, nonce: code.trim()),
    );
  }

  @override
  Future<void> startEmailChange(String newEmail) async {
    // BEWUSST ohne `emailRedirectTo`: der Code-Flow braucht keinen Deep-Link,
    // und sein Fehlen verhindert, dass ein Server-Template-Rueckfall den
    // kaperbaren `eatova://`-Link reaktiviert (Sicherheits-Audit 2026-08-09).
    await _client.auth.updateUser(UserAttributes(email: newEmail.trim()));
  }

  @override
  Future<void> confirmEmailChange({
    required String email,
    required String code,
  }) async {
    await _client.auth.verifyOTP(
      type: OtpType.emailChange,
      email: email.trim(),
      token: code.trim(),
    );
  }

  @override
  Future<void> signIn({required String email, required String password}) async {
    await _client.auth.signInWithPassword(
      email: email.trim(),
      password: password,
    );
  }

  @override
  Future<SignUpOutcome> signUp({
    required String email,
    required String password,
    required String displayName,
  }) async {
    // BEWUSST OHNE emailRedirectTo: die Registrierung bestaetigt die E-Mail
    // ueber den 6-stelligen Code ({{ .Token }}-Template, AuthCodeScreen im
    // signup-Flow), nicht ueber einen Confirm-Link. Kein redirect_to =>
    // keine stille Reaktivierung des Deep-Link-Wegs bei einem Template-
    // Rueckfall (Sicherheits-Audit 2026-08-09).
    final antwort = await _client.auth.signUp(
      email: email.trim(),
      password: password,
      data: {'display_name': displayName.trim()},
    );
    final identitaeten = antwort.user?.identities;
    // Nur das LEERE Array ist das Signal. Fehlt das Feld ganz (null), hat der
    // Server nichts behauptet — dann als frische Registrierung behandeln, statt
    // aus einer Wissensluecke eine Aussage ueber ein fremdes Konto zu machen.
    if (identitaeten != null && identitaeten.isEmpty) {
      return SignUpOutcome.emailAlreadyRegistered;
    }
    return SignUpOutcome.created;
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
  Future<void> verifyRecoveryCode(
      {required String email, required String code}) async {}

  @override
  Future<void> verifySignupCode(
      {required String email, required String code}) async {}

  @override
  Future<void> resendSignupCode(String email) async {}

  @override
  Future<void> updatePassword(String newPassword) async {}

  // Konto-Aenderungen gibt es im Preview-Betrieb nicht: es steht kein
  // Postfach hinter dem Vorschau-Nutzer, ein „Code verschickt" waere gelogen.
  @override
  Future<void> startPasswordChange() async {}

  @override
  Future<void> confirmPasswordChange({
    required String code,
    required String newPassword,
  }) async {}

  @override
  Future<void> startEmailChange(String newEmail) async {}

  @override
  Future<void> confirmEmailChange({
    required String email,
    required String code,
  }) async {}

  @override
  Future<void> signIn({required String email, required String password}) async {}

  @override
  Future<SignUpOutcome> signUp({
    required String email,
    required String password,
    required String displayName,
  }) async =>
      SignUpOutcome.created;

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

  /// Fuer Tests: verifizierte Codes als 'email:code'.
  final List<String> verifiedCodes = <String>[];

  /// Fuer Tests: erneut angeforderte Signup-Codes.
  final List<String> signupResends = <String>[];

  /// Fuer Tests: laesst den naechsten Verify-Aufruf scheitern (falscher/
  /// abgelaufener Code).
  bool verifyFails = false;

  /// Fuer Tests: Adressen, zu denen es schon ein Konto gibt — [signUp]
  /// antwortet darauf mit [SignUpOutcome.emailAlreadyRegistered].
  final Set<String> existingEmails = <String>{};

  @override
  Future<void> sendPasswordReset(String email) async {
    passwordResets.add(email.trim());
  }

  Future<void> _verify(String email, String code) async {
    if (verifyFails) {
      verifyFails = false;
      throw const AuthException('Token has expired or is invalid');
    }
    verifiedCodes.add('${email.trim()}:${code.trim()}');
    _user ??= EatovaUser(id: 'otp-user', email: email.trim());
    _controller.add(_user);
  }

  @override
  Future<void> verifyRecoveryCode(
          {required String email, required String code}) =>
      _verify(email, code);

  @override
  Future<void> verifySignupCode(
          {required String email, required String code}) =>
      _verify(email, code);

  @override
  Future<void> resendSignupCode(String email) async {
    signupResends.add(email.trim());
  }

  @override
  Future<void> updatePassword(String newPassword) async {
    passwordUpdates.add(newPassword);
  }

  // --- Konto-Aenderungen ----------------------------------------------------

  /// Fuer Tests: an welche Adressen ein Passwort-Aenderungs-Code ging.
  final List<String> reauthRequests = <String>[];

  /// Fuer Tests: welche Codes als Nonce beim Passwortsetzen mitliefen.
  final List<String> usedNonces = <String>[];

  /// Fuer Tests: welche neuen Mailadressen angefragt wurden.
  final List<String> emailChangeRequests = <String>[];

  /// Laufende Adress-Aenderung: Zieladresse und die noch offenen
  /// Bestaetigungen. Der Wechsel greift erst, wenn BEIDE weg sind — genau
  /// das Verhalten von GoTrue bei aktiver „sicherer E-Mail-Aenderung".
  String? _pendingEmail;
  final Set<String> _offeneBestaetigungen = <String>{};

  @override
  Future<void> startPasswordChange() async {
    reauthRequests.add(_user?.email ?? '');
  }

  @override
  Future<void> confirmPasswordChange({
    required String code,
    required String newPassword,
  }) async {
    if (verifyFails) {
      verifyFails = false;
      throw const AuthException('Token has expired or is invalid');
    }
    usedNonces.add(code.trim());
    passwordUpdates.add(newPassword);
  }

  @override
  Future<void> startEmailChange(String newEmail) async {
    final ziel = newEmail.trim();
    emailChangeRequests.add(ziel);
    _pendingEmail = ziel;
    _offeneBestaetigungen
      ..clear()
      ..addAll(<String>{
        if (_user?.email != null) _user!.email!,
        ziel,
      });
  }

  @override
  Future<void> confirmEmailChange({
    required String email,
    required String code,
  }) async {
    if (verifyFails) {
      verifyFails = false;
      throw const AuthException('Token has expired or is invalid');
    }
    verifiedCodes.add('${email.trim()}:${code.trim()}');
    _offeneBestaetigungen.remove(email.trim());
    if (_offeneBestaetigungen.isNotEmpty || _pendingEmail == null) return;
    _user = EatovaUser(
      id: _user?.id ?? 'otp-user',
      email: _pendingEmail,
      displayName: _user?.displayName,
    );
    _pendingEmail = null;
    _controller.add(_user);
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
  Future<SignUpOutcome> signUp({
    required String email,
    required String password,
    required String displayName,
  }) async {
    if (existingEmails.contains(email.trim())) {
      // Wie GoTrue: kein Fehler, kein Konto, keine Mail — nur das Signal.
      return SignUpOutcome.emailAlreadyRegistered;
    }
    _user = EatovaUser(id: 'test-user', email: email, displayName: displayName);
    _controller.add(_user);
    return SignUpOutcome.created;
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

  void dispose() => _controller.close();
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
  Future<void> verifyRecoveryCode(
          {required String email, required String code}) =>
      _fail();

  @override
  Future<void> verifySignupCode(
          {required String email, required String code}) =>
      _fail();

  @override
  Future<void> resendSignupCode(String email) => _fail();

  @override
  Future<void> updatePassword(String newPassword) => _fail();

  @override
  Future<void> startPasswordChange() => _fail();

  @override
  Future<void> confirmPasswordChange({
    required String code,
    required String newPassword,
  }) => _fail();

  @override
  Future<void> startEmailChange(String newEmail) => _fail();

  @override
  Future<void> confirmEmailChange({
    required String email,
    required String code,
  }) => _fail();


  @override
  Future<void> signIn({required String email, required String password}) =>
      _fail();

  @override
  Future<SignUpOutcome> signUp({
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
