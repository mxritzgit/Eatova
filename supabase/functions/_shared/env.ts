// Shared defensive env parsers for all edge functions.
//
// A misconfigured function secret must never cause a total outage.
// `Number(env ?? '20')` yields NaN for a non-numeric value, JSON.stringify
// turns NaN into `null`, consume_edge_rate_limit gets p_limit = null, the SQL
// guard throws and EVERY request fails with `rate_limit_unavailable`. The same
// guard also has UPPER bounds (p_limit > 10000, p_window_seconds > 86400), so
// an oversized secret used to cause the identical outage.
//
// Therefore: unset / empty / not a plain integer / <= 0 / not a safe integer /
// above the RPC ceiling -> fall back to the code default.
//
// The `_` directory prefix keeps the Supabase CLI from treating _shared as a
// deployable function; relative imports are bundled on deploy.

/** Upper bound for p_limit from the consume_edge_rate_limit SQL guard
 *  (supabase/migrations/20260518000100_fix_edge_rate_limit_pgcrypto_search_path.sql:33),
 *  also the default cap below because it is the tighter of the two guards. */
export const EDGE_RATE_LIMIT_MAX_LIMIT = 10000;

/** Upper bound for p_window_seconds from the same guard (line 36), 24 h.
 *  Callers wanting a window beyond EDGE_RATE_LIMIT_MAX_LIMIT seconds (~2.8 h)
 *  must pass this value as `max` explicitly, or the tighter default applies
 *  and the value silently falls back to the code default. */
export const EDGE_RATE_LIMIT_MAX_WINDOW_SECONDS = 86400;

/**
 * Reads `name` from the environment and returns only a positive integer within
 * the allowed range; anything else -> `fallback`.
 *
 * `max` defaults to the tighter of the two RPC bounds: an ignored secret is a
 * config error, an oversized value passed through is a 500 on EVERY request.
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
