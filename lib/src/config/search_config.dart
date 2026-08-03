/// Konfiguration des eigenen OFF-Suchindex (Meilisearch auf dem
/// Host-Unlimited-vServer, seit 2026-08-03 — Nachfolger des teuren
/// GCP-Mirrors). Beides zur Build-Zeit ueberschreibbar:
/// `--dart-define=OFF_MIRROR_URL=` (leer) schaltet den Mirror ab ->
/// die App sucht direkt live bei OpenFoodFacts.
///
/// Der Key ist ein Meilisearch **Search-only** Key (actions: [search],
/// index: products) — er kann ausschliesslich lesen/suchen und darf
/// deshalb im Client stecken.
class SearchConfig {
  const SearchConfig._();

  static const String mirrorBaseUrl = String.fromEnvironment(
    'OFF_MIRROR_URL',
    defaultValue: 'https://88-218-227-227.sslip.io',
  );

  static const String mirrorSearchKey = String.fromEnvironment(
    'OFF_MIRROR_SEARCH_KEY',
    defaultValue:
        '72aac3969484de63f87f83c1952fdfcdd85c8736eef983a571aaf30393a67206',
  );

  /// True, solange URL + Key konfiguriert sind. Leer => Mirror aus,
  /// direkt OpenFoodFacts.
  static bool get mirrorEnabled =>
      mirrorBaseUrl.trim().isNotEmpty && mirrorSearchKey.trim().isNotEmpty;
}
