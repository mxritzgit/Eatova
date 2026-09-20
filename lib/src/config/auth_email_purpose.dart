/// Allowlisted HTTPS context for the recovery email's copy. It does not change
/// the OTP's authorization scope and is never rendered as a sign-in link.
abstract final class AuthEmailPurpose {
  static const passwordReset = 'https://eatova.de/auth/email/password-reset';
  static const accountDeletion =
      'https://eatova.de/auth/email/account-deletion';
}
