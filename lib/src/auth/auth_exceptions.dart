/// Typed auth failures the UI maps to localized sentences.
///
/// Types, not messages: the auth screen used to match the German word
/// "abgebrochen" in `error.toString()`, which broke the moment the sentence
/// was translated. A type survives any wording.
library;

/// The user (or the platform) abandoned a sign-in before it completed — the
/// native Google sheet was dismissed, or the browser sheet never opened.
class AuthCancelledException implements Exception {
  const AuthCancelledException([this.provider]);

  /// Display name of the provider ("Google"), diagnostics only.
  final String? provider;

  @override
  String toString() => 'AuthCancelledException(provider: $provider)';
}

/// The auth layer is not usable in this process (`Supabase.instance` threw at
/// boot, see `UnavailableAuthRepository`). Every auth call fails with it; the
/// screen shows a restart hint.
class AuthUnavailableException implements Exception {
  const AuthUnavailableException();

  @override
  String toString() => 'AuthUnavailableException';
}
