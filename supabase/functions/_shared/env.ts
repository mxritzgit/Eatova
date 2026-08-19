// Gemeinsame, defensive Env-Parser fuer alle Edge Functions.
//
// Warum das ein eigenes Modul ist: ein falsch gesetztes Function-Secret darf
// nie zu einem Totalausfall fuehren. `Number(Deno.env.get('X') ?? '20')`
// liefert fuer einen nicht-numerischen Wert NaN; NaN wird von JSON.stringify
// zu `null` serialisiert, die RPC consume_edge_rate_limit bekommt dann
// p_limit = null, der SQL-Guard wirft, PostgREST antwortet 500 und JEDER
// Request der Function scheitert mit `rate_limit_unavailable`. Ein Tippfehler
// im Secret legt damit die komplette Function lahm.
//
// Derselbe SQL-Guard hat aber auch OBERE Grenzen (p_limit > 10000 bzw.
// p_window_seconds > 86400 werfen genauso). Ein zu GROSS gesetztes Secret
// fuehrte deshalb frueher in exakt denselben Totalausfall, den dieses Modul
// verhindern soll - die Bereichspruefung endete bei "> 0".
//
// Deshalb: nicht gesetzt / leer / kein reines Integer / <= 0 / kein sicherer
// Integer / ueber der RPC-Obergrenze -> Fallback auf den Code-Default.
//
// Das `_`-Prefix des Verzeichnisses haelt die Supabase-CLI davon ab, _shared
// als eigene deploybare Function zu behandeln; relative Imports werden beim
// Deploy mitgebundelt.

/** Obergrenze fuer p_limit aus dem SQL-Guard von consume_edge_rate_limit
 *  (supabase/migrations/20260518000100_fix_edge_rate_limit_pgcrypto_search_path.sql:33).
 *  Zugleich der Default-Deckel unten: er ist der engere der beiden Guards und
 *  damit fuer jeden Aufrufer sicher. */
export const EDGE_RATE_LIMIT_MAX_LIMIT = 10000;

/** Obergrenze fuer p_window_seconds aus demselben Guard (Z. 36), 24 h.
 *  Aufrufer, die ein Fenster JENSEITS von EDGE_RATE_LIMIT_MAX_LIMIT Sekunden
 *  (~2,8 h) konfigurierbar halten wollen, muessen diesen Wert explizit als
 *  `max` uebergeben - sonst greift der engere Default und der Wert faellt
 *  still auf den Code-Default zurueck. */
export const EDGE_RATE_LIMIT_MAX_WINDOW_SECONDS = 86400;

/**
 * Liest `name` aus der Environment und gibt nur eine positive Ganzzahl im
 * erlaubten Bereich zurueck; alles andere -> `fallback`.
 *
 * `max` bewusst per Default auf die engere der beiden RPC-Grenzen: ein
 * ignoriertes Secret ist ein Konfigurationsfehler, ein durchgereichter zu
 * grosser Wert dagegen ein 500 auf JEDEM Request der Function.
 */
export function positiveIntFromEnv(
  name: string,
  fallback: number,
  max: number = EDGE_RATE_LIMIT_MAX_LIMIT,
): number {
  const raw = Deno.env.get(name)?.trim();
  if (!raw || !/^\d+$/.test(raw)) return fallback;
  const parsed = Number.parseInt(raw, 10);
  if (!Number.isSafeInteger(parsed) || parsed <= 0 || parsed > max) return fallback;
  return parsed;
}
