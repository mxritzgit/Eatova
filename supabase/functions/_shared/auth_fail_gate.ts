// Pre-auth IP limiter for auth FAILURES, shared by coach-chat, analyze-meal
// and search-key (F-28-1, review 2026-08-28).
//
// Every non-anon bearer costs one /auth/v1/user introspection. The gateway's
// verify_jwt rejects garbage signatures, but a signature-valid yet revoked
// token (signed-out session, deleted account — free via OTP signup) reaches
// the function, and without a cap on FAILURES a replay flood is unbounded
// GoTrue amplification (CWE-400). coach-chat had this gate inline; the other
// two had none. One implementation, one set of numbers.
//
// Rules, identical for every caller:
//  - Consume ONLY after a failed lookup. consume_edge_rate_limit is
//    check+increment ATOMICALLY, so there is no "peek", and consuming before
//    the lookup would count successful auths.
//  - Local rejections (no bearer, the public anon key) cost no roundtrip and
//    must not reach this gate; a 200 without a usable id is not a failure
//    here either — nothing was amplified, and counting it would let a broken
//    auth server 429 whole IPs.
//  - A limiter outage never blocks the 401: this is a damper, not an auth
//    boundary — unlike the gates behind it, which protect paid work. The
//    helper therefore never throws and never reports `limited` on an error.
//  - The subject is the client IP, `clientIpSubject(req, "anon")`; without an
//    IP header that is the SHARED "uid:anon" bucket, acceptable because only
//    failed logins land in it.

/** 30 failures per hour and IP: far above honest use (one stale token per
 *  app start), far below anything that looks like a flood. Pinned by the
 *  coach-chat tests; all three functions share it. */
export const AUTH_FAIL_LIMIT = 30;
export const AUTH_FAIL_WINDOW_SECONDS = 3600;

export type AuthFailGateOptions = {
  supabaseUrl: string;
  serviceKey: string;
  /** One scope per function: `<slug>:auth-fail`. */
  scope: string;
  /** `clientIpSubject(req, "anon")` of the failing request. */
  subject: string;
  limit?: number;
  windowSeconds?: number;
};

export type AuthFailGateResult =
  | { limited: false }
  | {
    limited: true;
    limit: number;
    remaining: number;
    resetAt: string;
    windowSeconds: number;
    /** For the Retry-After header; falls back to windowSeconds when resetAt
     *  is unreadable. */
    retryAfterSeconds: number;
  };

/**
 * Consumes one slot of the fail bucket and reports whether the caller should
 * answer 429 instead of 401. ALWAYS resolves; on any limiter problem the
 * result is `{ limited: false }` with one console.error line.
 */
export async function authFailGate(options: AuthFailGateOptions): Promise<AuthFailGateResult> {
  const limit = options.limit ?? AUTH_FAIL_LIMIT;
  const windowSeconds = options.windowSeconds ?? AUTH_FAIL_WINDOW_SECONDS;
  const label = `consume_edge_rate_limit (${options.scope})`;

  let data: unknown;
  try {
    const response = await fetch(`${options.supabaseUrl}/rest/v1/rpc/consume_edge_rate_limit`, {
      method: "POST",
      headers: {
        apikey: options.serviceKey,
        authorization: `Bearer ${options.serviceKey}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({
        p_scope: options.scope,
        p_subject: options.subject,
        p_limit: limit,
        p_window_seconds: windowSeconds,
      }),
    });
    // Status only, never the body: nothing in it is needed here.
    if (!response.ok) {
      console.error(`${label} failed: HTTP ${response.status}`);
      return { limited: false };
    }
    data = await response.json();
  } catch (e) {
    console.error(`${label} failed: ${e instanceof Error ? e.message : String(e)}`);
    return { limited: false };
  }

  // E6, same guard as the application gates: a broken response shape is a
  // limiter outage, not a measured limit. The diagnostic names the fields,
  // not their values.
  const record = data !== null && typeof data === "object" ? data as Record<string, unknown> : null;
  if (record === null || typeof record.allowed !== "boolean") {
    const shape = record === null ? typeof data : Object.keys(record).join(",");
    console.error(`${label}: 200 ohne lesbares allowed (Felder: ${shape})`);
    return { limited: false };
  }
  if (record.allowed) return { limited: false };

  const resetAt = String(record.resetAt ?? new Date(Date.now() + windowSeconds * 1000).toISOString());
  const reportedWindow = Number(record.windowSeconds);
  const effectiveWindow = Number.isFinite(reportedWindow) && reportedWindow > 0 ? reportedWindow : windowSeconds;
  return {
    limited: true,
    limit: Number(record.limit ?? limit),
    remaining: Number(record.remaining ?? 0),
    resetAt,
    windowSeconds: effectiveWindow,
    retryAfterSeconds: retryAfterSeconds(resetAt, effectiveWindow),
  };
}

function retryAfterSeconds(resetAt: string, fallback: number): number {
  const ms = new Date(resetAt).getTime() - Date.now();
  return Number.isFinite(ms) ? Math.max(1, Math.ceil(ms / 1000)) : fallback;
}
