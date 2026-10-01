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
//    the lookup would count successful auths. (What is known without a peek
//    is cached in-isolate instead, see P7-02 below.)
//  - Local rejections (no bearer, the public anon key) cost no roundtrip and
//    must not reach this gate; a 200 without a usable id is not a failure
//    here either — nothing was amplified, and counting it would let a broken
//    auth server 429 whole IPs.
//  - A limiter outage never blocks the 401: this is a damper, not an auth
//    boundary — unlike the gates behind it, which protect paid work. The
//    helper therefore never throws and never reports `limited` on an error.
//  - The deadline belongs to the CALLER (`options.signal`, E1): a stalling
//    PostgREST must not hold the 401 path open past the client's own budget.
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
//
// P7-02 (review 2026-10-01): the bucket answered 429 but did not CAP the
// amplification — every replay of a revoked token still cost one GoTrue
// lookup plus one upsert, because the consume has no peek. Two small,
// bounded, per-isolate caches (no migration) now short-circuit what is
// already known:
//  - rejected tokens: SHA-256 of the exact token GoTrue answered 401/403 for.
//    Only the SECOND rejection within AUTH_FAIL_TOKEN_TTL_MS makes a token
//    "known bad"; from then on it is answered before the lookup. Two strikes,
//    because GoTrue occasionally 401s a brand-new valid token (Sentry
//    FLUTTER-9/-A/-B): a client retrying the same token once must still reach
//    GoTrue (StaleAuthRetry's first retry reuses its token, the second one
//    refreshes it — a new token is a new hash). A successful lookup clears the
//    token's strike. 429/5xx/timeouts never get here (`auth_unavailable`).
//  - blocked buckets: when the consume reports `allowed: false`, the bucket is
//    remembered until its resetAt (capped at one window), and further failed
//    lookups from it get the same 429 without another upsert.
// The bucket key is the client IP, so a blocked bucket NEVER short-circuits a
// request before its lookup — a valid token from the same IP (CGNAT, office)
// still reaches GoTrue and passes. Only a token that is itself known bad is
// answered early: 429 while its bucket is known blocked, else its 401.
// Memory is capped per cache; only hashes are stored, nothing is logged.

import { isIpSubject } from "./client_ip.ts";

/** 30 failures per hour and IP: far above honest use (one stale token per
 *  app start), far below anything that looks like a flood. Pinned by the
 *  coach-chat tests; all three functions share it. */
export const AUTH_FAIL_LIMIT = 30;
export const AUTH_FAIL_WINDOW_SECONDS = 3600;

/** P7-02: rejections of the same token before it is answered without a
 *  lookup, how long a strike lives, and the entry cap of each cache. */
export const AUTH_FAIL_TOKEN_STRIKES = 2;
export const AUTH_FAIL_TOKEN_TTL_MS = 60_000;
export const AUTH_FAIL_CACHE_MAX_ENTRIES = 1000;

type TokenStrike = { strikes: number; expiresAt: number };
type BlockedBucket = { limit: number; resetAt: string; windowSeconds: number; expiresAt: number };

/** Insertion-ordered map with a hard size cap: expired entries go first,
 *  then the oldest. Re-setting a key moves it to the end. */
class BoundedExpiringMap<V extends { expiresAt: number }> {
  readonly #entries = new Map<string, V>();
  constructor(readonly maxEntries: number) {}

  get size(): number {
    return this.#entries.size;
  }

  get(key: string, now: number): V | undefined {
    const entry = this.#entries.get(key);
    if (entry === undefined) return undefined;
    if (entry.expiresAt <= now) {
      this.#entries.delete(key);
      return undefined;
    }
    return entry;
  }

  set(key: string, value: V, now: number): void {
    this.#entries.delete(key);
    if (this.#entries.size >= this.maxEntries) {
      for (const [k, v] of this.#entries) {
        if (v.expiresAt <= now) this.#entries.delete(k);
      }
    }
    while (this.#entries.size >= this.maxEntries) {
      const oldest = this.#entries.keys().next().value;
      if (oldest === undefined) break;
      this.#entries.delete(oldest);
    }
    this.#entries.set(key, value);
  }

  delete(key: string): void {
    this.#entries.delete(key);
  }

  clear(): void {
    this.#entries.clear();
  }
}

// Per isolate, like every other module-level state of an edge function.
const rejectedTokens = new BoundedExpiringMap<TokenStrike>(AUTH_FAIL_CACHE_MAX_ENTRIES);
const blockedBuckets = new BoundedExpiringMap<BlockedBucket>(AUTH_FAIL_CACHE_MAX_ENTRIES);
let clock: () => number = () => Date.now();

/** Test seam: a cold isolate (empty caches, real clock). */
export function resetAuthFailCacheForTests(): void {
  rejectedTokens.clear();
  blockedBuckets.clear();
  clock = () => Date.now();
}

/** Test seam: frozen/advanced time for TTL tests, never sleeps. */
export function setAuthFailClockForTests(now: () => number): void {
  clock = now;
}

/** Test seam: entry counts, to pin the memory bound. */
export function authFailCacheSizesForTests(): { tokens: number; buckets: number } {
  return { tokens: rejectedTokens.size, buckets: blockedBuckets.size };
}

// The scope keeps the functions apart where they share an isolate (tests);
// \u0000 cannot occur in a scope.
function bucketKey(scope: string, subject: string): string {
  return `${scope}\u0000${subject}`;
}

async function tokenKey(scope: string, token: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(token));
  const hex = Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
  return `${scope}\u0000${hex}`;
}

function blockedResult(bucket: BlockedBucket, now: number): AuthFailGateResult {
  return {
    limited: true,
    limit: bucket.limit,
    remaining: 0,
    resetAt: bucket.resetAt,
    windowSeconds: bucket.windowSeconds,
    retryAfterSeconds: retryAfterSeconds(bucket.resetAt, bucket.windowSeconds, now),
  };
}

export type KnownAuthFailureOptions = {
  /** Same scope and subject the caller passes to authFailGate. */
  scope: string;
  subject: string;
  /** The bearer exactly as it would be sent to /auth/v1/user. */
  token: string;
};

/**
 * P7-02, BEFORE the /auth/v1/user lookup: `null` means "look it up" — the
 * answer for every token that is not itself known bad, whatever its IP did.
 * For a known-bad token it returns what the failure path would answer
 * without a lookup or upsert: `limited` (429) while the bucket is known
 * blocked, else `{ limited: false }` (401). Never throws.
 */
export async function knownAuthFailure(options: KnownAuthFailureOptions): Promise<AuthFailGateResult | null> {
  // Fast path: an isolate that has seen no rejection hashes nothing.
  if (rejectedTokens.size === 0) return null;
  try {
    const now = clock();
    const strike = rejectedTokens.get(await tokenKey(options.scope, options.token), now);
    if (strike === undefined || strike.strikes < AUTH_FAIL_TOKEN_STRIKES) return null;
    const bucket = blockedBuckets.get(bucketKey(options.scope, options.subject), now);
    return bucket === undefined ? { limited: false } : blockedResult(bucket, now);
  } catch {
    return null;
  }
}

/** P7-02: GoTrue accepted this token, so an earlier strike was a flake. */
export async function forgetAuthFailure(scope: string, token: string): Promise<void> {
  if (rejectedTokens.size === 0) return;
  try {
    rejectedTokens.delete(await tokenKey(scope, token));
  } catch {
    // Nothing to undo: a missing strike only means one more lookup.
  }
}

async function recordRejection(scope: string, rejection: AuthRejection): Promise<void> {
  // Only a definite "this token is not valid"; anything else is not cached.
  if (rejection.status !== 401 && rejection.status !== 403) return;
  try {
    const key = await tokenKey(scope, rejection.token);
    const now = clock();
    const previous = rejectedTokens.get(key, now);
    rejectedTokens.set(key, {
      strikes: (previous?.strikes ?? 0) + 1,
      expiresAt: now + AUTH_FAIL_TOKEN_TTL_MS,
    }, now);
  } catch {
    // A missing strike only means one more lookup.
  }
}

/** The failed lookup behind a gate call: the token and GoTrue's status. */
export type AuthRejection = { token: string; status: number };

export type AuthFailGateOptions = {
  supabaseUrl: string;
  serviceKey: string;
  /** One scope per function: `<slug>:auth-fail`. */
  scope: string;
  /** `clientIpSubject(req, "anon")` of the failing request. */
  subject: string;
  limit?: number;
  windowSeconds?: number;
  /**
   * Deadline for the one RPC roundtrip below (E1, review 2026-08-31).
   *
   * This runs on the 401 path of every function, so a stalling PostgREST used
   * to hold the request open until the platform killed the isolate while the
   * client had long given up. The signal belongs to the CALLER because only it
   * knows what is left of its own request budget; without one the fetch is
   * unbounded, which is why all three callers pass one.
   *
   * An abort is a limiter problem like any other: it lands in the catch below
   * and reports `{ limited: false }`. The helper still never throws.
   */
  signal?: AbortSignal;
  /**
   * P7-02: the failed lookup this call is about. A 401/403 counts as a strike
   * against the exact token (hashed); without it nothing is remembered about
   * the token, only about the bucket.
   */
  rejection?: AuthRejection;
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
 * answer 429 instead of 401. ALWAYS resolves; on any limiter problem — HTTP
 * error, broken shape, network failure, or an aborted `options.signal` — the
 * result is `{ limited: false }` with one console.error line.
 */
export async function authFailGate(options: AuthFailGateOptions): Promise<AuthFailGateResult> {
  const limit = options.limit ?? AUTH_FAIL_LIMIT;
  const windowSeconds = options.windowSeconds ?? AUTH_FAIL_WINDOW_SECONDS;
  const label = `consume_edge_rate_limit (${options.scope})`;

  if (options.rejection !== undefined) await recordRejection(options.scope, options.rejection);
  // P7-02: a bucket the limiter already reported exhausted answers the same
  // 429 without another upsert. Only reached AFTER a failed lookup.
  const key = bucketKey(options.scope, options.subject);
  const known = blockedBuckets.get(key, clock());
  if (known !== undefined) return blockedResult(known, clock());

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
      // Undefined is exactly "no signal", the pre-E1 behaviour, so a caller
      // that has no deadline of its own keeps compiling and working.
      signal: options.signal,
    });
    // Status only, never the body: nothing in it is needed here.
    if (!response.ok) {
      console.error(`${label} failed: HTTP ${response.status}`);
      return { limited: false };
    }
    data = await response.json();
  } catch (e) {
    const kind = e instanceof DOMException && (e.name === 'TimeoutError' || e.name === 'AbortError')
      ? 'timeout'
      : 'transport unavailable';
    console.error(`${label} failed: ${kind}`);
    return { limited: false };
  }

  // E6, same guard as the application gates: a broken response shape is a
  // limiter outage, not a measured limit. Never log upstream field names.
  const record = data !== null && typeof data === "object" ? data as Record<string, unknown> : null;
  if (record === null || typeof record.allowed !== "boolean") {
    console.error(`${label}: 200 ohne lesbares allowed`);
    return { limited: false };
  }
  if (record.allowed) return { limited: false };

  const resetAt = String(record.resetAt ?? new Date(Date.now() + windowSeconds * 1000).toISOString());
  // P6-05: only the shared no-IP bucket, and only on exhaustion — from here on
  // callers who never failed themselves are answered 429 instead of 401.
  if (!isIpSubject(options.subject)) {
    // Only the NAMESPACE, never the subject itself: all three callers pass
    // clientIpSubject(req, "anon") today, so the fallback reads `uid:anon` —
    // but the same helper turns a verified user id into `uid:<uuid>`, and one
    // caller changing its fallback would have put that id into function_logs
    // (CWE-532). Which bucket it is, is all this warning ever needed.
    console.warn(
      `${label}: geteilter ${options.subject.split(":")[0]}-Bucket erschoepft — jede 401 wird als 429 beantwortet`,
    );
  }
  const reportedWindow = Number(record.windowSeconds);
  const effectiveWindow = Number.isFinite(reportedWindow) && reportedWindow > 0 ? reportedWindow : windowSeconds;
  const result = {
    limited: true as const,
    limit: Number(record.limit ?? limit),
    remaining: Number(record.remaining ?? 0),
    resetAt,
    windowSeconds: effectiveWindow,
    retryAfterSeconds: retryAfterSeconds(resetAt, effectiveWindow, clock()),
  };
  // P7-02: remembered until the bucket resets, never longer than one window.
  // An unreadable or past resetAt is not cached: the next failure asks again.
  const now = clock();
  const resetMs = new Date(resetAt).getTime();
  if (Number.isFinite(resetMs) && resetMs > now) {
    blockedBuckets.set(key, {
      limit: result.limit,
      resetAt,
      windowSeconds: effectiveWindow,
      expiresAt: Math.min(resetMs, now + effectiveWindow * 1000),
    }, now);
  }
  return result;
}

function retryAfterSeconds(resetAt: string, fallback: number, now: number): number {
  const ms = new Date(resetAt).getTime() - now;
  return Number.isFinite(ms) ? Math.max(1, Math.ceil(ms / 1000)) : fallback;
}
