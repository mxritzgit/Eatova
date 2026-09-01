import 'package:supabase_flutter/supabase_flutter.dart' show AuthException;

import '../../auth/auth_exceptions.dart' show AuthUnavailableException;
import '../../l10n/l10n.dart';
import '../../services/sync_error_messages.dart'
    show isAuthNetworkError, isAuthServerFaultError;

// ---------------------------------------------------------------------------
// Texts and checks of the two account-change flows — and the ONE classifier
// every auth error in this app runs through ([classifyAuthError]).
//
// A widget-free file on purpose: the error translation is the security-
// relevant half of these flows and is testable here without a widget tree.
// `auth_code_screen.dart` used to carry a second, independently maintained copy
// of these rules; it got the typed rewrite (P4-02/P4-03) and this one did not,
// so the settings sheets kept calling "Invalid API key" an expired code and the
// hourly mail quota "a moment". Two classifiers for one question is the bug —
// hence: ONE classifier, and each surface picks its own sentences from the
// [AuthErrorKind] it gets back.
//
// GROUND RULE, as in sync_error_messages.dart: never put `error.toString()`
// into the UI — an `AuthException` text can carry project URL, endpoint or
// internal codes. Classify here, then show an own sentence; the raw exception
// stays in the diagnostics channel.
// ---------------------------------------------------------------------------

/// Minimum password length — identical to `auth_screen.dart` and
/// `auth_code_screen.dart`; three different limits in one app would confuse.
const int kAccountMinPasswordLength = 8;

/// Length of the email code (GoTrue `mailer_otp_length` = 8).
///
/// Eight, not six: /auth/v1/verify is rate-limited per IP only and a wrong
/// attempt does not consume the code, so six digits gave a distributed
/// attacker double-digit hit rates per 10-minute window. Changing this value
/// REQUIRES updating the server config (supabase/AUTH_EMAIL_OTP.md).
const int kAccountCodeLength = 8;

// The functions below take an OPTIONAL [AppLocalizations] with a German
// default ([deL10n]) so tests can call them context-free, while
// `account_change_sheets.dart` passes the active language through.
String kAccountEmailInvalid([AppLocalizations? l10n]) =>
    (l10n ?? deL10n).settingsAccountEmailInvalid;
String kAccountEmailUnchanged([AppLocalizations? l10n]) =>
    (l10n ?? deL10n).settingsAccountEmailUnchanged;
String kAccountCodeInvalid([AppLocalizations? l10n]) =>
    (l10n ?? deL10n).settingsAccountCodeInvalid;
String kAccountPasswordTooShort([AppLocalizations? l10n]) =>
    (l10n ?? deL10n).settingsAccountPasswordTooShort;
String kAccountPasswordMismatch([AppLocalizations? l10n]) =>
    (l10n ?? deL10n).settingsAccountPasswordMismatch;

/// The most common server error of these flows: wrong code, or the 10 minutes
/// (mailer_otp_exp) are up.
String kAccountCodeRejected([AppLocalizations? l10n]) =>
    (l10n ?? deL10n).settingsAccountCodeRejected;

/// Same lenient check as in `auth_screen.dart`: shape only, existence is the
/// server's business. Stricter rules would reject valid addresses (`+` aliases,
/// new TLDs, IDN).
bool isPlausibleAccountEmail(String value) {
  final adresse = value.trim();
  return adresse.contains('@') && adresse.contains('.');
}

/// Exactly [kAccountCodeLength] digits. The field formatter already filters
/// non-digits; this catches the too-short rest before the server rejects it.
bool isAccountCode(String value) =>
    RegExp('^\\d{$kAccountCodeLength}\$').hasMatch(value.trim());

// ---------------------------------------------------------------------------
// The shared classifier
// ---------------------------------------------------------------------------

/// What an auth error really was — one value per statement a screen can
/// honestly make about it. The SENTENCE is each screen's own business
/// ([accountChangeErrorMessage] here, `_friendlyError` on the auth screens):
/// classification and wording are split so a second surface never needs a
/// second copy of these rules.
enum AuthErrorKind {
  /// The auth layer never came up (see `UnavailableAuthRepository`); only a
  /// restart helps.
  unavailable,

  /// No connection to the server: nothing was sent, nothing was checked.
  offline,

  /// The server ANSWERED — with a 5xx. Not the user's connection, and not
  /// their input; it heals on its own within minutes.
  serverFault,

  /// GoTrue's PER-REQUEST send lock, which names the seconds it has left in
  /// [AuthErrorBefund.retryAfter].
  sendThrottled,

  /// GoTrue's PROJECT-wide mail quota (`rate_limit_email_sent`, 60/h since
  /// 2026-09-01, see supabase/AUTH_EMAIL_OTP.md) is spent. It refills
  /// gradually and every user competes for it, so the honest wait is "a few
  /// minutes", not the "moment" a plain throttle text claims.
  quotaExhausted,

  /// A throttle without a usable number in it.
  rateLimited,

  /// The target address already has an account. NEVER passed through verbatim
  /// (audit 2026-08-14, account enumeration).
  emailTaken,

  /// The server refused the address as malformed.
  emailInvalid,

  /// GoTrue insists on a password different from the current one.
  passwordSameAsOld,

  /// GoTrue's password policy refused the new password.
  passwordWeak,

  /// The server really did check the code and refused it.
  codeRejected,

  unknown,
}

/// A classified error plus what the server said about the wait.
class AuthErrorBefund {
  const AuthErrorBefund(this.kind, {this.retryAfter});

  final AuthErrorKind kind;

  /// The wait GoTrue named, when it named one at all.
  final Duration? retryAfter;
}

/// GoTrue's per-request lock carries its remaining time in the message:
/// "For security purposes, you can only request this after 51 seconds."
final RegExp _sekundenImText = RegExp(r'(\d+)\s*second');

/// GoTrue codes that really mean "the code the user typed did not work".
///
/// `otp_disabled` is deliberately NOT here (P4-02d): it means the PROJECT has
/// OTP sign-in switched off ("Signups not allowed for otp"), a server
/// configuration fault the user cannot answer for. Counting it as a rejection
/// showed "Der Code stimmt nicht" and burned all five attempts against a
/// lockout only a new code can lift — while no new code can ever be issued.
/// That is the same misclassification P4-02c removed for `Invalid API key`,
/// only moved from the text fallback into the code list.
///
/// The two `reauth*` codes are the account-change half of the same statement:
/// the nonce that flow calls a "code" was missing or wrong.
const Set<String> _abgelehnteCodes = <String>{
  'otp_expired',
  'invalid_credentials',
  'reauthentication_not_valid',
  'reauth_nonce_missing',
};

/// GoTrue codes for "that address already has an account".
const Set<String> _belegteAdressCodes = <String>{
  'email_exists',
  'user_already_exists',
  'identity_already_exists',
};

/// Text fallback for GoTrue answers that carry NO code ("Token has expired or
/// is invalid", "Invalid token", "Reauthentication token is invalid"). A bare
/// `invalid` is missing on purpose — see [classifyAuthError].
final RegExp _abgelehntImText =
    RegExp(r'expired|invalid token|invalid otp|invalid code|\botp\b|nonce'
        r'|reauth');

/// Classifies [error] for every auth surface in the app.
///
/// TYPE first, then GoTrue's own code, text fragments only as the last stage.
/// The reverse order let "invalid certificate" pass as an expired code and
/// dropped every offline error into the catch-all (P4-02).
AuthErrorBefund classifyAuthError(Object error) {
  if (error is AuthUnavailableException) {
    return const AuthErrorBefund(AuthErrorKind.unavailable);
  }
  // 5xx BEFORE the network branch: gotrue wraps a server outage in the very
  // type that otherwise means "no connection" (see [isAuthServerFaultError]).
  if (isAuthServerFaultError(error)) {
    return const AuthErrorBefund(AuthErrorKind.serverFault);
  }
  // IOException (Socket/Tls), TimeoutException, ClientException and GoTrue's
  // own AuthRetryableFetchException without a status. A 429 becomes an
  // AuthApiException, so this branch cannot swallow a throttle.
  if (isAuthNetworkError(error)) {
    return const AuthErrorBefund(AuthErrorKind.offline);
  }

  final raw = error.toString().toLowerCase();
  final code = error is AuthException ? error.code : null;
  final istMailDrossel = code == 'over_email_send_rate_limit';
  final istDrossel = istMailDrossel ||
      code == 'over_request_rate_limit' ||
      raw.contains('rate limit') ||
      raw.contains('rate_limit') ||
      raw.contains('too many') ||
      raw.contains('for security purposes');

  if (istDrossel) {
    // Both mail throttles ship the SAME error code; only the message tells
    // them apart — the per-request lock names its seconds, the hourly quota
    // does not (P4-03).
    final treffer = _sekundenImText.firstMatch(raw);
    final sekunden = treffer == null ? null : int.tryParse(treffer.group(1)!);
    if (sekunden != null && sekunden > 0) {
      return AuthErrorBefund(
        AuthErrorKind.sendThrottled,
        retryAfter: Duration(seconds: sekunden),
      );
    }
    if (istMailDrossel || raw.contains('email rate limit')) {
      return const AuthErrorBefund(AuthErrorKind.quotaExhausted);
    }
    return const AuthErrorBefund(AuthErrorKind.rateLimited);
  }

  // GoTrue's OWN codes next (P4-02c): once the server names a code, that code
  // is the answer and its prose is never read on top.
  if (code != null) {
    if (_belegteAdressCodes.contains(code)) {
      return const AuthErrorBefund(AuthErrorKind.emailTaken);
    }
    if (code == 'same_password') {
      return const AuthErrorBefund(AuthErrorKind.passwordSameAsOld);
    }
    if (code == 'weak_password') {
      return const AuthErrorBefund(AuthErrorKind.passwordWeak);
    }
    if (_abgelehnteCodes.contains(code)) {
      return const AuthErrorBefund(AuthErrorKind.codeRejected);
    }
  }

  // Account enumeration (audit 2026-08-14): the server reveals that the target
  // address is taken. Deliberately NOT gated on `code == null` — this is the
  // one verdict whose miss leaks something, so every phrasing keeps catching.
  if (raw.contains('already registered') ||
      raw.contains('already been registered') ||
      raw.contains('already in use') ||
      raw.contains('already exists') ||
      raw.contains('email_exists')) {
    return const AuthErrorBefund(AuthErrorKind.emailTaken);
  }

  if (raw.contains('email') &&
      (raw.contains('invalid') || raw.contains('not valid'))) {
    return const AuthErrorBefund(AuthErrorKind.emailInvalid);
  }

  if (raw.contains('password')) {
    if (raw.contains('different')) {
      return const AuthErrorBefund(AuthErrorKind.passwordSameAsOld);
    }
    if (raw.contains('weak') ||
        raw.contains('at least') ||
        raw.contains('short') ||
        raw.contains('characters')) {
      return const AuthErrorBefund(AuthErrorKind.passwordWeak);
    }
    // Reauthentication/nonce errors fall through to the code branch below on
    // purpose: for the user it is the same thing — the code did not work.
  }

  // Text fallback ONLY for answers without a code. The bare `invalid` that used
  // to stand here also caught `AuthApiException('Invalid API key')` — a
  // misconfigured anon key read as "your code is wrong" AND, on the code
  // screen, burned one of the five attempts against a lockout only a new code
  // can lift.
  //
  // The `code == null` guard is what keeps that shut (P4-02d): once GoTrue
  // names a code, that code is the answer — reading its prose on top would let
  // `otp_disabled` ("Signups not allowed for otp") back in through `\botp\b`,
  // and every future config code whose sentence happens to say "otp" with it.
  if (code == null && _abgelehntImText.hasMatch(raw)) {
    return const AuthErrorBefund(AuthErrorKind.codeRejected);
  }
  return const AuthErrorBefund(AuthErrorKind.unknown);
}

/// Translates an error from [AuthRepository.startPasswordChange] and siblings
/// into a user-facing sentence without technical details.
///
/// Pure TEXT CHOICE — the rules live in [classifyAuthError]. The settings flows
/// need their own wording for most kinds (they talk about "die Änderung", not
/// about signing in), which is exactly why the split exists.
String accountChangeErrorMessage(Object error, [AppLocalizations? l10n]) {
  final t = l10n ?? deL10n;
  switch (classifyAuthError(error).kind) {
    // Unreachable in practice — a dead auth layer means no session and thus no
    // settings screen — but restarting is the only advice that could work.
    case AuthErrorKind.unavailable:
      return t.authErrorUnavailable;
    case AuthErrorKind.offline:
      return t.settingsAccountOfflineError;
    case AuthErrorKind.serverFault:
      return t.authErrorServerFault;
    // The per-request lock really is "a moment" (GoTrue names seconds, and
    // these sheets have no countdown of their own to quote it into).
    case AuthErrorKind.sendThrottled:
    case AuthErrorKind.rateLimited:
      return t.settingsAccountRateLimited;
    // The project-wide quota is NOT a moment: the bucket refills gradually and
    // every user competes for the next token (supabase/AUTH_EMAIL_OTP.md).
    case AuthErrorKind.quotaExhausted:
      return t.settingsAccountQuotaExhausted;
    case AuthErrorKind.emailTaken:
      return t.settingsAccountEmailNotAvailable;
    case AuthErrorKind.emailInvalid:
      return t.settingsAccountEmailLooksInvalid;
    case AuthErrorKind.passwordSameAsOld:
      return t.settingsAccountPasswordSameAsOld;
    case AuthErrorKind.passwordWeak:
      return t.settingsAccountPasswordWeak;
    case AuthErrorKind.codeRejected:
      return kAccountCodeRejected(t);
    case AuthErrorKind.unknown:
      return t.commonGenericRetryError;
  }
}
