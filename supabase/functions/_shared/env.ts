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
 *
 * P6-03: a value that IS set but unusable is logged. Silence was the actual
 * trap — `ANALYZE_MEAL_USER_WINDOW_SECONDS=86400` without an explicit `max`
 * became 3600, i.e. 24x looser than intended, at a cap that costs money, and
 * nothing anywhere said so.
 */
export function positiveIntFromEnv(
  name: string,
  fallback: number,
  max: number = EDGE_RATE_LIMIT_MAX_LIMIT,
): number {
  const raw = Deno.env.get(name)?.trim();
  // Unset or empty is the normal case, not a config error: stays silent.
  if (!raw) return fallback;
  const isPlainInteger = /^\d+$/.test(raw);
  const parsed = isPlainInteger ? Number.parseInt(raw, 10) : Number.NaN;
  if (!Number.isSafeInteger(parsed) || parsed <= 0 || parsed > max) {
    // E2 (review 2026-08-31), CWE-532: the value is NEVER logged. The old line
    // wrote 32 characters of it, and this branch fires precisely when the slot
    // does NOT hold a number — i.e. in the case it exists for: a secret that
    // slipped into a numeric slot (`ANALYZE_MEAL_USER_LIMIT=<service-role
    // JWT>` from a misaligned bulk paste) would have put its header and the
    // start of its payload into function_logs on EVERY cold start of all three
    // functions, for the whole log retention.
    //
    // Nothing diagnostic is lost: the variable NAME says what to fix, `reason`
    // says why it was rejected, `max`/`fallback` say what applies instead, and
    // length plus fingerprint tell two wrong values apart and show whether a
    // corrected secret actually reached the deployment. The fingerprint is
    // FNV-1a rather than SHA-256 because callers are module-level constants and
    // crypto.subtle is async.
    console.warn('env value ignored, code default applies', {
      name,
      reason: !isPlainInteger
        ? 'not a plain integer'
        : parsed <= 0
        ? 'not positive'
        : 'out of range',
      valueLength: raw.length,
      valueFingerprint: fingerprint(raw),
      max,
      fallback,
    });
    return fallback;
  }
  return parsed;
}

/** FNV-1a/32 as 8 hex chars: identifies a value across restarts without
 *  carrying any of it. Not a security primitive, and never used as one. */
function fingerprint(value: string): string {
  let hash = 0x811c9dc5;
  for (let i = 0; i < value.length; i++) {
    hash ^= value.charCodeAt(i);
    // 32-bit FNV prime multiply, kept in range via Math.imul.
    hash = Math.imul(hash, 0x01000193);
  }
  return (hash >>> 0).toString(16).padStart(8, '0');
}
