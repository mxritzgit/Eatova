import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/supabase_config.dart';
import '../config/auth_email_purpose.dart';
import '../l10n/l10n.dart';
import '../services/crash_reporter.dart';
import '../services/session_revocations.dart';
import '../services/sync_execution_guard.dart';
import 'auth_exceptions.dart';
import 'auth_session_mutation.dart';
import 'google_id_token_provider.dart';
import 'password_recovery.dart';

export 'auth_exceptions.dart';
export 'auth_session_mutation.dart' show ScopedAccountDeleteAction;
export 'password_recovery.dart' show PasswordRecovery;

class EatovaUser {
  const EatovaUser({required this.id, this.email, this.displayName, this.sessionId});

  final String id;
  final String? email;
  final String? displayName;
  final String? sessionId;

  /// First name for greetings: display name, else the mailbox part of the
  /// address, else a neutral ARB fallback. Nothing here is persisted, so the
  /// fallback may be localized; [l10n] defaults to the German bundle for
  /// context-free callers.
  String firstNameFor([AppLocalizations? l10n]) {
    final name = displayName?.trim();
    if (name != null && name.isNotEmpty) {
      return name.split(RegExp(r'\s+')).first;
    }
    final mail = email?.trim();
    if (mail != null && mail.isNotEmpty) {
      return mail.split('@').first;
    }
    return (l10n ?? deL10n).authFallbackFirstName;
  }

  String get firstName => firstNameFor();
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

/// Result of [AuthRepository.signUp].
///
/// With mail confirmation on, GoTrue hides an already-registered address:
/// `POST /signup` answers like a fresh signup but with an EMPTY `identities`
/// array and sends no mail. Without this distinction the UI promises a code
/// that never arrives.
///
/// The value only tells the caller that the signup path stops here; the UI
/// keeps its message neutral (house line against account enumeration).
enum SignUpOutcome {
  /// Signup accepted: account created, confirmation code on its way.
  created,

  /// The address already has an account (empty `identities` array). No mail
  /// is sent, so the code screen would be a dead end.
  emailAlreadyRegistered,
}

abstract class AuthRepository {
  EatovaUser? get currentUser;
  Stream<EatovaUser?> get authStateChanges;

  /// Triggers the password reset mail. The UI always confirms neutrally:
  /// neither server nor app reveals whether an account exists, which would be
  /// an account-enumeration leak.
  Future<void> sendPasswordReset(String email);

  /// Requests a recovery OTP with account-deletion copy, bound to the account
  /// that opened the confirmation. [ScopedAccountDeletion] verifies the code
  /// without replacing the app session.
  Future<void> sendAccountDeletionCode({required String userId, required String email});

  /// Verifies the 8-digit code from the password reset mail (OTP, not a link;
  /// mailer_otp_exp = 10 min). The returned flow owns the proof without
  /// establishing an app login; callers must close it when leaving recovery.
  Future<PasswordRecovery> verifyRecoveryCode({required String email, required String code});

  /// Verifies the 8-digit signup code without establishing an app login.
  Future<void> verifySignupCode({required String email, required String code});

  /// Requests a new signup confirmation code.
  Future<void> resendSignupCode(String email);

  // --- In-app account changes -----------------------------------------------
  //
  // Both paths use GoTrue built-ins, not hand-rolled tokens. Server config is
  // in supabase/AUTH_EMAIL_OTP.md; without it codes are inert or arrive as
  // links.

  /// Requests the confirmation code for a password change; GoTrue sends it to
  /// the stored address (`reauthenticate`). Signed-in users only; the
  /// signed-out counterpart is [sendPasswordReset].
  Future<void> startPasswordChange();

  /// Submits the current password, new password and reauthentication code.
  ///
  /// The native current-password policy protects ordinary password changes.
  /// Nonce verification additionally applies to sessions older than 24 hours;
  /// this is not a universal fresh-mail requirement. Recovery is separate.
  Future<void> confirmPasswordChange({
    required String currentPassword,
    required String code,
    required String newPassword,
  });

  /// Starts the email address change.
  ///
  /// With secure email change GoTrue sends TWO codes, one to the old and one
  /// to the new address; the account only switches once both are confirmed via
  /// [confirmEmailChange], so one compromised mailbox is not enough.
  Future<void> startEmailChange(String newEmail);

  /// Confirms ONE of the two codes from [startEmailChange]; [email] is the
  /// address that code was sent to.
  Future<void> confirmEmailChange({
    required String email,
    required String code,
  });
  Future<void> signIn({required String email, required String password});

  /// Registers the address and reports whether the path continues — see
  /// [SignUpOutcome]. A `void` return dropped the `AuthResponse`, so callers
  /// showed the code screen for a mail that never came (audit 2026-08-14).
  Future<SignUpOutcome> signUp({
    required String email,
    required String password,
    required String displayName,
  });
  Future<void> signInWithOAuth(EatovaOAuthProvider provider);
  Future<void> signOut();
}

/// Optional capability for repositories that must commit logout intent before
/// the caller clears account-scoped caches, photos and device integrations.
abstract interface class CoordinatedSignOut {
  Future<void> signOutWithCleanup(Future<void> Function() cleanup);
}

/// Implementations must keep the recovery token separate from the app login.
abstract interface class ScopedAccountDeletion {
  Future<void> withAccountDeletionCode({
    required String userId,
    required String? sessionId,
    required String email,
    required String code,
    required ScopedAccountDeleteAction performDeletion,
  });
}

class SupabaseAuthRepository
    implements AuthRepository, CoordinatedSignOut, ScopedAccountDeletion {
  const SupabaseAuthRepository(
    this._client, {
    GoogleIdTokenProvider? googleIdTokenProvider,
    http.Client? mutationHttpClient,
    SecureSessionLocalStorage? sessionStorage,
  }) : _googleIdTokenProvider =
           googleIdTokenProvider ?? const GoogleSignInIdTokenProvider(),
       _mutationHttpClient = mutationHttpClient,
       _sessionStorage = sessionStorage;

  final SupabaseClient _client;
  final GoogleIdTokenProvider _googleIdTokenProvider;
  final http.Client? _mutationHttpClient;
  final SecureSessionLocalStorage? _sessionStorage;

  @override
  Future<void> withAccountDeletionCode({
    required String userId,
    required String? sessionId,
    required String email,
    required String code,
    required ScopedAccountDeleteAction performDeletion,
  }) async {
    if (currentUser?.id != userId || currentUser?.sessionId != sessionId) {
      throw const AuthException('Authentication session changed');
    }
    await runAccountDeletionCode(
      _client,
      userId: userId,
      email: email,
      code: code,
      performDeletion: performDeletion,
      httpClient: _mutationHttpClient,
    );
  }

  @override
  EatovaUser? get currentUser => _mapUser(_client.auth.currentUser, _client.auth.currentSession?.accessToken);

  @override
  Stream<EatovaUser?> get authStateChanges async* {
    yield currentUser;
    yield* _client.auth.onAuthStateChange.map(
      (event) => _mapUser(event.session?.user, event.session?.accessToken),
    );
  }

  @override
  Future<void> sendPasswordReset(String email) async {
    await _client.auth.resetPasswordForEmail(email.trim(),
        redirectTo: AuthEmailPurpose.passwordReset);
  }

  @override
  Future<void> sendAccountDeletionCode({required String userId, required String email}) async {
    final user = currentUser;
    if (user == null || user.id != userId || user.email?.trim().toLowerCase() != email.trim().toLowerCase()) {
      throw const AuthException('Account changed. Please sign in again.');
    }
    await _client.auth.resetPasswordForEmail(user.email!.trim(),
        redirectTo: AuthEmailPurpose.accountDeletion);
  }

  @override
  Future<PasswordRecovery> verifyRecoveryCode(
      {required String email, required String code}) async {
    return beginPasswordRecovery(
      _client,
      email: email.trim(),
      code: code.trim(),
      httpClient: _mutationHttpClient,
    );
  }

  @override
  Future<void> verifySignupCode(
      {required String email, required String code}) async {
    await confirmSignupWithoutLogin(
      _client,
      email: email.trim(),
      code: code.trim(),
      httpClient: _mutationHttpClient,
    );
  }

  @override
  Future<void> resendSignupCode(String email) async {
    await _client.auth.resend(type: OtpType.signup, email: email.trim());
  }

  @override
  Future<void> startPasswordChange() async {
    await _client.auth.reauthenticate();
  }

  @override
  Future<void> confirmPasswordChange({
    required String currentPassword,
    required String code,
    required String newPassword,
  }) async {
    // Keep the exact current password: leading/trailing spaces are credentials.
    // GoTrue may consume an older session's nonce before checking this password.
    await updateSessionUser(
      _client,
      UserAttributes(
        password: newPassword,
        nonce: code.trim(),
        currentPassword: currentPassword,
      ),
      httpClient: _mutationHttpClient,
    );
  }

  @override
  Future<void> startEmailChange(String newEmail) async {
    // Deliberately without `emailRedirectTo`: the code flow needs no deep
    // link, and its absence blocks a template regression from reactivating
    // the hijackable `eatova://` link.
    await updateSessionUser(_client, UserAttributes(email: newEmail.trim()),
        httpClient: _mutationHttpClient);
  }

  @override
  Future<void> confirmEmailChange({
    required String email,
    required String code,
  }) async {
    await verifySessionEmailChange(
      _client,
      email: email.trim(),
      code: code.trim(),
      httpClient: _mutationHttpClient,
    );
  }

  @override
  Future<void> signIn({required String email, required String password}) async {
    await authenticateSession(
      _client,
      (scoped) => scoped.signInWithPassword(
        email: email.trim(),
        password: password,
      ),
      httpClient: _mutationHttpClient,
      requireSession: true,
    );
  }

  @override
  Future<SignUpOutcome> signUp({
    required String email,
    required String password,
    required String displayName,
  }) async {
    // Deliberately without emailRedirectTo: signup confirms via the 8-digit
    // code, not a confirm link, so a template regression cannot silently
    // reactivate the deep-link path.
    final antwort = await authenticateSession(
      _client,
      (scoped) => scoped.signUp(
        email: email.trim(),
        password: password,
        data: {'display_name': displayName.trim()},
      ),
      httpClient: _mutationHttpClient,
    );
    final identitaeten = antwort.user?.identities;
    // Only the EMPTY array is the signal. A missing field (null) claims
    // nothing, so treat it as a fresh signup rather than inventing a statement
    // about someone else's account.
    if (identitaeten != null && identitaeten.isEmpty) {
      return SignUpOutcome.emailAlreadyRegistered;
    }
    return SignUpOutcome.created;
  }

  @override
  Future<void> signInWithOAuth(EatovaOAuthProvider provider) async {
    if (provider == EatovaOAuthProvider.google) {
      var nativeOk = false;
      await authenticateSession(
        _client,
        (scoped) async {
          AuthResponse? response;
          nativeOk = await runNativeGoogleSignIn(
            tokenProvider: _googleIdTokenProvider,
            exchangeIdToken: (idToken) async {
              response = await scoped.signInWithIdToken(
                provider: OAuthProvider.google,
                idToken: idToken,
              );
            },
          );
          return response ?? AuthResponse();
        },
        httpClient: _mutationHttpClient,
      );
      if (nativeOk) return;
      // Technical failure in the native flow (no Play Services, client not
      // propagated yet): fall through to the proven web flow.
    }
    await _signInWithWebOAuth(provider);
  }

  /// Web OAuth via browser sheet: the standard path for Apple, the fallback
  /// for Google (which then shows the Supabase domain).
  ///
  /// inAppBrowserView opens SFSafariViewController / Chrome Custom Tabs and
  /// closes once the eatova://login-callback/ scheme fires, while using the
  /// system browser's cookie and auth logic.
  ///
  /// Never inAppWebView: an embedded WKWebView is blocked by Google for OAuth.
  Future<void> _signInWithWebOAuth(EatovaOAuthProvider provider) async {
    final launched = await _client.auth.signInWithOAuth(
      provider.supabaseProvider,
      redirectTo: EatovaSupabaseConfig.oauthRedirectUrl,
      authScreenLaunchMode: LaunchMode.inAppBrowserView,
    );
    if (!launched) {
      throw AuthCancelledException(provider.displayName);
    }
  }

  @override
  Future<void> signOut() => _signOutWithCleanup(null);

  @override
  Future<void> signOutWithCleanup(Future<void> Function() cleanup) =>
      _signOutWithCleanup(cleanup);

  Future<void> _signOutWithCleanup(Future<void> Function()? cleanup) async {
    final session = _client.auth.currentSession;
    final storage =
        _sessionStorage ?? EatovaSupabaseConfig.sessionStorageFor(_client);
    if (session != null && storage != null) {
      await storage.prepareLogout(jsonEncode(session.toJson()));
    }
    _requireSameSession(session);
    if (cleanup != null) await cleanup();
    // A second login during preflight or cleanup belongs to its caller.
    // Never hand that login to the SDK's parameterless signOut().
    _requireSameSession(session);
    final accessToken = _client.auth.currentSession?.accessToken;
    var signedOutEmitted = false;
    // gotrue 2.27.2 clears its session before awaiting PKCE removal. A storage
    // failure skips both signedOut and server revocation. These internal hooks
    // keep the SDK listeners consistent without weakening PKCE storage errors.
    // ignore: invalid_use_of_internal_member
    final subscription = _client.auth.onAuthStateChangeSync.listen(
      (event) {
        if (event.event == AuthChangeEvent.signedOut) signedOutEmitted = true;
      },
      onError: (Object _, StackTrace __) {},
    );
    try {
      await _client.auth.signOut();
    } catch (_) {
      if (!signedOutEmitted) {
        // No await between the null check and notification: a new B login
        // must never receive A's compensating signedOut event.
        if (_client.auth.currentSession == null) {
          // ignore: invalid_use_of_internal_member
          _client.auth.notifyAllSubscribers(
            AuthChangeEvent.signedOut,
            signOutReason: SignOutReason.userInitiated,
          );
        }
        if (accessToken != null) {
          try {
            // Fixed A token, same local scope as the SDK, one bounded attempt.
            await _client.auth.admin
                .signOut(accessToken, scope: SignOutScope.local)
                .timeout(const Duration(seconds: 10));
          } catch (error, stack) {
            unawaited(CrashReporter.capture(
              error, stack, context: 'session_logout_revoke',
            ));
          }
        }
      }
      rethrow;
    } finally {
      await subscription.cancel();
    }
  }

  void _requireSameSession(Session? original) {
    final current = _client.auth.currentSession;
    if (original == null && current == null) return;
    if (original == null || current == null ||
        !SessionRevocations.sameSession(
          jsonEncode(original.toJson()), jsonEncode(current.toJson()),
        )) {
      throw const AuthException('Authentication session changed');
    }
  }

  EatovaUser? _mapUser(User? user, [String? token]) {
    if (user == null) return null;
    final metadata = user.userMetadata ?? <String, dynamic>{};
    final rawName = metadata['display_name'] ??
        metadata['full_name'] ??
        metadata['name'] ??
        metadata['user_name'];
    return EatovaUser(
      sessionId: syncSessionIdFromAccessToken(token ?? ''),
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
  Future<void> sendAccountDeletionCode({required String userId, required String email}) async {}

  @override
  Future<PasswordRecovery> verifyRecoveryCode(
      {required String email, required String code}) async =>
      _InMemoryPasswordRecovery((_) {});

  @override
  Future<void> verifySignupCode(
      {required String email, required String code}) async {}

  @override
  Future<void> resendSignupCode(String email) async {}

  // No account changes in preview mode: there is no mailbox behind the
  // preview user, so "code sent" would be a lie.
  @override
  Future<void> startPasswordChange() async {}

  @override
  Future<void> confirmPasswordChange({
    required String currentPassword,
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

class _InMemoryPasswordRecovery implements PasswordRecovery {
  _InMemoryPasswordRecovery(this._save);
  final void Function(String) _save;
  bool _active = true;

  @override
  bool get isActive => _active;

  @override
  Future<void> updatePassword(String newPassword) async {
    if (!_active) throw const AuthException('Recovery flow closed');
    _save(newPassword);
    _active = false;
  }

  @override
  Future<void> close() async => _active = false;
}

class InMemoryAuthRepository implements AuthRepository, ScopedAccountDeletion {
  InMemoryAuthRepository({EatovaUser? initialUser}) : _user = initialUser;

  EatovaUser? _user;
  final Map<String, String> _registeredNames = {};
  final StreamController<EatovaUser?> _controller =
      StreamController<EatovaUser?>.broadcast();

  /// For tests: addresses a reset was triggered for.
  final List<String> passwordResets = <String>[];

  final List<String> accountDeletionCodes = <String>[];

  @override
  Future<void> withAccountDeletionCode({
    required String userId,
    required String? sessionId,
    required String email,
    required String code,
    required ScopedAccountDeleteAction performDeletion,
  }) async {
    final original = _user;
    bool isCurrent() =>
        identical(_user, original) &&
        _user?.id == userId &&
        _user?.sessionId == sessionId;
    if (!isCurrent() ||
        _user?.email?.trim().toLowerCase() != email.trim().toLowerCase()) {
      throw const AuthException('Authentication session changed');
    }
    if (verifyFails) {
      verifyFails = false;
      throw const AuthException('Token has expired or is invalid');
    }
    verifiedCodes.add('${email.trim()}:${code.trim()}');
    await performDeletion(() async {
      if (!isCurrent()) {
        throw const AuthException('Authentication session changed');
      }
    }, isCurrent);
  }

  /// For tests: new passwords that were set.
  final List<String> passwordUpdates = <String>[];

  /// For tests: verified codes as 'email:code'.
  final List<String> verifiedCodes = <String>[];

  /// For tests: re-requested signup codes.
  final List<String> signupResends = <String>[];

  /// For tests: makes the next verify call fail (wrong/expired code).
  bool verifyFails = false;

  /// For tests: addresses that already have an account; [signUp] answers with
  /// [SignUpOutcome.emailAlreadyRegistered].
  final Set<String> existingEmails = <String>{};

  @override
  Future<void> sendPasswordReset(String email) async {
    passwordResets.add(email.trim());
  }

  @override
  Future<void> sendAccountDeletionCode({required String userId, required String email}) async {
    if (_user?.id != userId || _user?.email?.trim().toLowerCase() != email.trim().toLowerCase()) {
      throw const AuthException('Account changed. Please sign in again.');
    }
    accountDeletionCodes.add(email.trim());
  }

  Future<void> _verify(String email, String code) async {
    if (verifyFails) {
      verifyFails = false;
      throw const AuthException('Token has expired or is invalid');
    }
    verifiedCodes.add('${email.trim()}:${code.trim()}');
  }

  @override
  Future<PasswordRecovery> verifyRecoveryCode(
      {required String email, required String code}) async {
    if (_user != null) throw const AuthException('Sign out before recovery');
    await _verify(email, code);
    return _InMemoryPasswordRecovery(passwordUpdates.add);
  }

  @override
  Future<void> verifySignupCode(
          {required String email, required String code}) =>
      _verify(email, code);

  @override
  Future<void> resendSignupCode(String email) async {
    signupResends.add(email.trim());
  }

  // --- Account changes ------------------------------------------------------

  /// For tests: addresses a password-change code went to.
  final List<String> reauthRequests = <String>[];

  /// For tests: codes passed as nonce when setting a password.
  final List<String> usedNonces = <String>[];

  /// Synthetic credentials supplied by tests; never persisted or logged.
  final List<String> usedCurrentPasswords = <String>[];

  /// For tests: requested new email addresses.
  final List<String> emailChangeRequests = <String>[];

  /// Pending address change: target and the outstanding confirmations. The
  /// switch only applies once both are gone, like GoTrue's secure email
  /// change.
  String? _pendingEmail;
  final Set<String> _offeneBestaetigungen = <String>{};

  @override
  Future<void> startPasswordChange() async {
    reauthRequests.add(_user?.email ?? '');
  }

  @override
  Future<void> confirmPasswordChange({
    required String currentPassword,
    required String code,
    required String newPassword,
  }) async {
    if (verifyFails) {
      verifyFails = false;
      throw const AuthException('Token has expired or is invalid');
    }
    usedNonces.add(code.trim());
    usedCurrentPasswords.add(currentPassword);
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
    _user = EatovaUser(
      id: 'test-user',
      email: email,
      displayName: _registeredNames[email.trim()] ?? 'Test User',
    );
    _controller.add(_user);
  }

  @override
  Future<SignUpOutcome> signUp({
    required String email,
    required String password,
    required String displayName,
  }) async {
    if (existingEmails.contains(email.trim())) {
      // Like GoTrue: no error, no account, no mail — just the signal.
      return SignUpOutcome.emailAlreadyRegistered;
    }
    _registeredNames[email.trim()] = displayName;
    return SignUpOutcome.created;
  }

  @override
  Future<void> signInWithOAuth(EatovaOAuthProvider provider) async {
    _user = EatovaUser(
      id: 'oauth-test-user',
      email: '${provider.displayName.toLowerCase()}@example.com',
      displayName: '${provider.displayName} User',
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

/// Auth layer unavailable (`Supabase.instance` threw during app build).
///
/// The honest counterpart to [PreviewAuthRepository]: no user instead of an
/// invented one, so AuthGate shows the login and sign-in fails loudly.
class UnavailableAuthRepository implements AuthRepository {
  const UnavailableAuthRepository(this.cause);

  /// Why building the real repository failed. Goes into the crash report; the
  /// user sees a typed [AuthUnavailableException] (localized by the screen)
  /// because '$cause' can contain internal URLs or assertion text.
  final Object cause;

  static Future<Never> _fail() =>
      Future.error(const AuthUnavailableException());

  @override
  EatovaUser? get currentUser => null;

  @override
  Stream<EatovaUser?> get authStateChanges async* {
    yield null;
  }

  @override
  Future<void> sendPasswordReset(String email) => _fail();

  @override
  Future<void> sendAccountDeletionCode({required String userId, required String email}) => _fail();

  @override
  Future<PasswordRecovery> verifyRecoveryCode(
          {required String email, required String code}) =>
      _fail();

  @override
  Future<void> verifySignupCode(
          {required String email, required String code}) =>
      _fail();

  @override
  Future<void> resendSignupCode(String email) => _fail();

  @override
  Future<void> startPasswordChange() => _fail();

  @override
  Future<void> confirmPasswordChange({
    required String currentPassword,
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

  /// Deliberately harmless: the profile screen calls signOut on error paths.
  @override
  Future<void> signOut() async {}
}

AuthRepository defaultAuthRepository() => buildDefaultAuthRepository();

/// Sentinel finding 1 (2026-08-08): the fallback used to catch EVERY error and
/// return [PreviewAuthRepository], whose `currentUser` is never null — turning
/// "unknown" into "signed in as preview-user" and rendering the logged-in view.
///
/// [allowPreview] keeps the wanted part: on debug/test (default kDebugMode)
/// flow tests pump `EatovaApp()` without a repository and land on the home
/// page. Release/profile builds get [UnavailableAuthRepository] instead and
/// the real cause goes to the CrashReporter.
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
