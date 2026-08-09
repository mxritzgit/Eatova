/// Build-Zeit-Konfiguration des eigenen OFF-Suchindex (Meilisearch auf dem
/// Host-Unlimited-vServer, seit 2026-08-03 — Nachfolger des teuren
/// GCP-Mirrors).
///
/// Seit 2026-08-07 laeuft der Zugriff ueber die eigene Domain
/// (`eatova.de/meili/*`, Caddy-Route mit Rate-Limit 120 req/min pro IP)
/// statt der Roh-IP; die alte sslip.io-Route bleibt fuer Bestands-Builds
/// serverseitig aktiv.
///
/// **Die Werte hier sind nur noch das letzte Glied einer Laufzeit-Kette.**
/// Ein einkompilierter Key laesst sich nie rotieren — jeder installierte
/// Build wuerde beim Key-Wechsel auf einen Schlag kaputtgehen. Deshalb
/// loest [SearchCredentialsStore] die Zugangsdaten zur Laufzeit auf:
///
///   1. **Cache** — der zuletzt geholte Key aus SharedPreferences
///      (12 h TTL, abgelaufene Eintraege werden weiter BENUTZT und nur im
///      Hintergrund erneuert).
///   2. **Fetch** — die Edge Function `search-key` liefert URL + Key
///      frisch (JWT-pflichtig; Suche laeuft ohnehin immer post-login).
///   3. **Compile-Time-Default** — genau die beiden Konstanten unten.
///      Greift beim frischen Install ohne Netz, damit die Suche sofort
///      funktioniert statt auf einen Fetch zu warten.
///   4. **Mirror aus** — leere Credentials (Server-Kill-Switch oder ein
///      abgelehnter Key ohne Ersatz) => direkt live zu OpenFoodFacts.
///
/// Der eigentliche Rotations-Mechanismus ist NICHT die TTL, sondern die
/// 401/403-Antwort des Mirrors: [MeilisearchProductService] laesst den
/// abgelehnten Key verwerfen und einen neuen holen — konvergiert innerhalb
/// einer einzigen Suche.
///
/// Der Key ist ein Meilisearch **Search-only** Key — er kann ausschliesslich
/// lesen/suchen und darf deshalb im Client stecken. **Am Server verifiziert
/// (2026-08-09, `GET /keys`): der ausgelieferte Key (name
/// "shiftfit-app-search") traegt `actions: ["search"]`, `indexes:
/// ["products"]`** — kein Schreiben, kein Loeschen, kein Zugriff auf andere
/// Indizes. Master-/Admin-Keys existieren nur serverseitig, nie im Client.
class SearchConfig {
  const SearchConfig._();

  /// Letzte Rueckfallebene fuer die Basis-URL (`--dart-define=OFF_MIRROR_URL`).
  static const String fallbackMirrorBaseUrl = String.fromEnvironment(
    'OFF_MIRROR_URL',
    defaultValue: 'https://eatova.de/meili',
  );

  /// Letzte Rueckfallebene fuer den Search-only-Key
  /// (`--dart-define=OFF_MIRROR_SEARCH_KEY`).
  static const String fallbackMirrorSearchKey = String.fromEnvironment(
    'OFF_MIRROR_SEARCH_KEY',
    defaultValue:
        '72aac3969484de63f87f83c1952fdfcdd85c8736eef983a571aaf30393a67206',
  );

  /// Harter, rein LOKALER Kill-Switch: ein Build mit
  /// `--dart-define=OFF_MIRROR_URL=` (leer) faehrt den Mirror gar nicht
  /// erst hoch — es wird kein Key geholt, kein Cache gelesen, nichts.
  ///
  /// Bewusst getrennt vom Server-Kill-Switch (leere Credentials aus der
  /// Edge Function): wer sich beim Bauen bewusst gegen den Mirror
  /// entschieden hat, darf ihn nicht durch ein Server-Secret zurueckbekommen.
  static bool get mirrorHardDisabled => fallbackMirrorBaseUrl.trim().isEmpty;
}
