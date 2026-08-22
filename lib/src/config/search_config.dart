/// Build-time config of the own OFF search index (Meilisearch mirror), and
/// only the last link of a runtime chain, since a compiled-in key can never
/// be rotated. [SearchCredentialsStore] resolves at runtime: cached key (12 h
/// TTL, stale entries still used) -> `search-key` edge function -> the
/// constants below -> empty, meaning mirror off and straight to OFF.
///
/// Rotation is driven by the mirror's 401/403, not the TTL. The key is
/// search-only, so it may ship in the client.
class SearchConfig {
  const SearchConfig._();

  /// Last-resort base URL (`--dart-define=OFF_MIRROR_URL`).
  static const String fallbackMirrorBaseUrl = String.fromEnvironment(
    'OFF_MIRROR_URL',
    defaultValue: 'https://eatova.de/meili',
  );

  /// Last-resort search-only key (`--dart-define=OFF_MIRROR_SEARCH_KEY`).
  static const String fallbackMirrorSearchKey = String.fromEnvironment(
    'OFF_MIRROR_SEARCH_KEY',
    defaultValue:
        '72aac3969484de63f87f83c1952fdfcdd85c8736eef983a571aaf30393a67206',
  );

  /// Local kill switch: an empty `OFF_MIRROR_URL` never starts the mirror.
  /// Separate from the server kill switch, so a build that opted out cannot
  /// get the mirror back through a server secret.
  static bool get mirrorHardDisabled => fallbackMirrorBaseUrl.trim().isEmpty;
}
