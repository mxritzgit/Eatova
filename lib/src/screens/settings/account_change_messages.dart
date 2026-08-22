import '../../l10n/l10n.dart';
import '../../services/sync_error_messages.dart' show isNetworkSyncError;

// ---------------------------------------------------------------------------
// Texts and checks of the two account-change flows.
//
// A widget-free file on purpose: the error translation is the security-
// relevant half of these flows and is testable here without a widget tree.
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

/// Translates an error from [AuthRepository.startPasswordChange] and siblings
/// into a user-facing sentence without technical details.
///
/// Branch order matters: several GoTrue messages share a trigger word
/// (`invalid`, `password`), so specific comes before generic.
String accountChangeErrorMessage(Object error, [AppLocalizations? l10n]) {
  final t = l10n ?? deL10n;
  // Network first, and by TYPE not text: offline there is no server message
  // to read at all.
  if (isNetworkSyncError(error)) {
    return t.settingsAccountOfflineError;
  }

  final raw = error.toString().toLowerCase();

  // GoTrue throttles mail sending and reauth requests hard.
  if (raw.contains('rate limit') ||
      raw.contains('rate_limit') ||
      raw.contains('too many') ||
      raw.contains('for security purposes')) {
    return t.settingsAccountRateLimited;
  }

  // Account enumeration (audit 2026-08-14): the server reveals that the
  // target address is taken. Passing that through let any signed-in user probe
  // foreign addresses, so the message now only names the way out.
  if (raw.contains('already registered') ||
      raw.contains('already been registered') ||
      raw.contains('already in use') ||
      raw.contains('already exists') ||
      raw.contains('email_exists')) {
    return t.settingsAccountEmailNotAvailable;
  }

  if (raw.contains('email') &&
      (raw.contains('invalid') || raw.contains('not valid'))) {
    return t.settingsAccountEmailLooksInvalid;
  }

  if (raw.contains('password')) {
    if (raw.contains('different')) {
      return t.settingsAccountPasswordSameAsOld;
    }
    if (raw.contains('weak') ||
        raw.contains('at least') ||
        raw.contains('short') ||
        raw.contains('characters')) {
      return t.settingsAccountPasswordWeak;
    }
    // Reauthentication/nonce errors fall through to the code branch below on
    // purpose: for the user it is the same thing — the code did not work.
  }

  if (raw.contains('expired') ||
      raw.contains('invalid') ||
      raw.contains('nonce') ||
      raw.contains('reauth') ||
      raw.contains('otp')) {
    return kAccountCodeRejected(t);
  }

  return t.commonGenericRetryError;
}
