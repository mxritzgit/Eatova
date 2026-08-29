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
//
// P6-05 (review 2026-08-29), the residual risk and why it stays as it is:
// once a bucket is full, every further failed auth from it gets a 429
// `rate_limited` instead of its 401. For the per-IP bucket that is the honest
// answer — the caller filling it IS the caller being answered, and RFC 9110
// 15.5.30 is exactly this case. For the shared "uid:anon" bucket it is not:
// there 30 failures per hour cover the WHOLE app, so one flooder would answer
// 429 to everyone else's honest 401. Weighed and deliberately not changed:
//  - the bucket is unreachable behind Cloudflare (cf-connecting-ip is set from
//    the TCP source address), and clientIpSubject already warns per request
//    when it is not;
//  - the gateway runs verify_jwt = true, so an EXPIRED session never reaches
//    the function at all — only revoked-but-unexpired tokens do (window <= 1 h);
//  - the wrong answer costs the user one wrong message text: the client picks
//    between two strings by status code and neither signs out nor re-routes;
//  - and the numbers are pinned identically by all three functions' tests, so
//    a separate, larger shared limit would fork the "one set of numbers" rule
//    for a case that cannot occur in the deployed environment.
// What was missing is the operator's signal for the moment it DOES start
// happening — the console.warn below. If that line ever shows up in
// function_logs, the environment assumption broke and the shared bucket
// deserves its own, much larger limit.

import { isIpSubject } from "./client_ip.ts";

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
  // P6-05: only the shared no-IP bucket, and only on exhaustion — from here on
  // callers who never failed themselves are answered 429 instead of 401.
  if (!isIpSubject(options.subject)) {
    console.warn(
      `${label}: geteilter ${options.subject}-Bucket erschoepft — bis ${resetAt} wird jede 401 als 429 beantwortet`,
    );
  }
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
