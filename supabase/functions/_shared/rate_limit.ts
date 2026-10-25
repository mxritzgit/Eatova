// One client for public.consume_edge_rate_limits(jsonb), the batched limiter
// in front of every edge function.
//
// The RPC walks the gates IN ORDER, does per element what the single-gate RPC
// did (window floor, sha256 subject, upsert +1, allowed = count <= limit) and
// STOPS at the first denial. Its answer is therefore SHORT exactly when a gate
// denied: result[i] belongs to gates[i], and a missing trailing element means
// "never consumed", never "allowed".
//
// Fail-closed contract, the same for every caller: a limiter that hangs,
// fails, answers non-2xx or in a shape that cannot be mapped back onto the
// gates is an OUTAGE (`unavailable`), never a measured limit and never a pass.
// Only a complete, all-allowed answer lets a request through.
//
// Deliberate differences between the functions stay with the caller: the
// public status of an outage (500 or 503), the Retry-After ceiling and the
// texts of a 429. Pruning stays in rate_limit_prune.ts.
//
// releaseRateLimit is the one way back: a slot spent on a request whose first
// provider reservation failed (denied, disabled or unavailable, so nothing
// was paid) is given back, best effort.

import { readProviderBody } from './provider_body.ts';

/** One gate of a batch. Mapped to the RPC's element shape on the wire. */
export type RateLimitGate = { scope: string; subject: string; limit: number; windowSeconds: number };

/**
 * Verdict of one consumed gate, with the gate's own numbers as defaults. The
 * field set is wire contract: analyze-meal and search-key return it to the
 * client as `rateLimit`.
 */
export type RateLimitVerdict = {
  allowed: boolean;
  limit: number;
  remaining: number;
  resetAt: string;
  windowSeconds: number;
};

/** Why the limiter could not answer. `aborted` is the caller's own signal. */
export type RateLimitUnavailableReason =
  | 'timeout'
  | 'aborted'
  | 'transport'
  | 'http_status'
  | 'body'
  | 'shape'
  | 'incomplete';

export type RateLimitOutcome =
  /** Every gate was consumed and allowed; verdicts match the gates by index. */
  | { kind: 'allowed'; verdicts: RateLimitVerdict[] }
  /** The first denial. Gates behind it were not consumed and are not reported. */
  | { kind: 'denied'; denied: RateLimitVerdict; deniedIndex: number; deniedScope: string }
  | { kind: 'unavailable'; reason: RateLimitUnavailableReason };

export interface ConsumeRateLimitsOptions {
  supabaseUrl: string;
  serviceKey: string;
  gates: readonly RateLimitGate[];
  /** Bounds the call AND the body read; the caller derives it from its deadline. */
  signal: AbortSignal;
  /** Byte cap of the answer; a few gates need a few hundred bytes. */
  maxResponseBytes?: number;
}

export const RATE_LIMIT_MAX_RESPONSE_BYTES = 12_000;

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function errorReason(error: unknown): RateLimitUnavailableReason {
  if (error instanceof DOMException && error.name === 'TimeoutError') return 'timeout';
  if (error instanceof DOMException && error.name === 'AbortError') return 'aborted';
  return 'transport';
}

/**
 * Consumes `gates` in ONE roundtrip and maps every failure to `unavailable`.
 * Never throws for limiter problems; diagnostics name scopes and statuses
 * only, never a response body or a subject.
 */
export async function consumeRateLimits(options: ConsumeRateLimitsOptions): Promise<RateLimitOutcome> {
  const { gates, signal } = options;
  const scopes = gates.map((gate) => gate.scope).join(',');
  const unavailable = (reason: RateLimitUnavailableReason, line?: string): RateLimitOutcome => {
    if (line) console.error(line);
    return { kind: 'unavailable', reason };
  };

  let response: Response;
  try {
    response = await fetch(`${options.supabaseUrl}/rest/v1/rpc/consume_edge_rate_limits`, {
      method: 'POST',
      headers: {
        apikey: options.serviceKey,
        authorization: `Bearer ${options.serviceKey}`,
        'content-type': 'application/json',
      },
      body: JSON.stringify({
        p_gates: gates.map((gate) => ({
          scope: gate.scope,
          subject: gate.subject,
          limit: gate.limit,
          window_seconds: gate.windowSeconds,
        })),
      }),
      // The service key must never follow a redirect.
      redirect: 'error',
      signal,
    });
  } catch (error) {
    const reason = errorReason(error);
    // A caller abort is the caller's story; it has nothing to diagnose here.
    return unavailable(reason, reason === 'aborted' ? undefined : `consume_edge_rate_limits (${scopes}) ${reason === 'timeout' ? 'timeout' : 'unavailable'}`);
  }

  if (!response.ok) {
    // Not awaited: a stalled cancel must not hold the outage answer.
    void response.body?.cancel().catch(() => {});
    return unavailable('http_status', `consume_edge_rate_limits (${scopes}) failed: HTTP ${response.status}`);
  }

  let data: unknown;
  try {
    const raw = await readProviderBody(response, options.maxResponseBytes ?? RATE_LIMIT_MAX_RESPONSE_BYTES, signal);
    if (raw === null) return unavailable('body', `consume_edge_rate_limits (${scopes}) body too large`);
    data = JSON.parse(raw);
  } catch (error) {
    // PostgREST sends 200 and its headers, then stalls or garbles the row.
    const reason = errorReason(error);
    if (reason === 'aborted') return unavailable('aborted');
    return unavailable(
      reason === 'timeout' ? 'timeout' : 'body',
      `consume_edge_rate_limits (${scopes}) ${reason === 'timeout' ? 'body timeout' : 'body unreadable'}`,
    );
  }

  // More elements than gates is a different RPC than the one called.
  if (!Array.isArray(data) || data.length === 0 || data.length > gates.length) {
    return unavailable('shape', `consume_edge_rate_limits (${scopes}): 200 ohne lesbares Ergebnis`);
  }

  const verdicts: RateLimitVerdict[] = [];
  for (const [index, entry] of data.entries()) {
    const gate = gates[index];
    // `typeof` and not truthiness: "false", 1 and {} are truthy.
    if (!isRecord(entry) || typeof entry.allowed !== 'boolean') {
      return unavailable('shape', `consume_edge_rate_limits (${gate.scope}): 200 ohne lesbares allowed`);
    }
    const verdict: RateLimitVerdict = {
      allowed: entry.allowed,
      limit: Number(entry.limit ?? gate.limit),
      remaining: Number(entry.remaining ?? 0),
      resetAt: String(entry.resetAt ?? new Date(Date.now() + gate.windowSeconds * 1000).toISOString()),
      windowSeconds: Number(entry.windowSeconds ?? gate.windowSeconds),
    };
    // Nothing behind a denial ran. Trailing elements cannot exist by
    // contract; ignoring them is the safe reading either way.
    if (!verdict.allowed) return { kind: 'denied', denied: verdict, deniedIndex: index, deniedScope: gate.scope };
    verdicts.push(verdict);
  }

  // All allowed, so the answer has to be COMPLETE: a short one would mean a
  // gate silently went unconsumed before a paid call.
  if (verdicts.length !== gates.length) {
    return unavailable('incomplete', `consume_edge_rate_limits (${scopes}): nur ${verdicts.length}/${gates.length} Tore, ohne Ablehnung`);
  }
  return { kind: 'allowed', verdicts };
}

/** Upper bound of one release; the answer to the client waits for it. */
const RELEASE_TIMEOUT_MS = 3000;

/**
 * Gives one consumed slot of `gate` back through
 * public.release_edge_rate_limit (20261026100000), for a request that ended
 * before anything was paid. The window is the consumed one, `verdict.resetAt`
 * minus the gate's window, so a release after midnight still hits the day it
 * counted. Best effort: never throws, resolves whether a slot came back, and
 * a failure logs one fixed line, never a body or a subject.
 */
export async function releaseRateLimit(options: {
  supabaseUrl: string;
  serviceKey: string;
  gate: RateLimitGate;
  verdict: RateLimitVerdict;
}): Promise<boolean> {
  const { gate } = options;
  const signal = AbortSignal.timeout(RELEASE_TIMEOUT_MS);
  try {
    // An unreadable resetAt throws a RangeError here: the fallback below.
    const windowStart = new Date(Date.parse(options.verdict.resetAt) - gate.windowSeconds * 1000).toISOString();
    const response = await fetch(`${options.supabaseUrl}/rest/v1/rpc/release_edge_rate_limit`, {
      method: 'POST',
      headers: {
        apikey: options.serviceKey,
        authorization: `Bearer ${options.serviceKey}`,
        'content-type': 'application/json',
      },
      body: JSON.stringify({
        p_scope: gate.scope,
        p_subject: gate.subject,
        p_window_start: windowStart,
        p_window_seconds: gate.windowSeconds,
      }),
      // The service key must never follow a redirect.
      redirect: 'error',
      signal,
    });
    if (response.ok) {
      const raw = await readProviderBody(response, 64, signal);
      const released = raw === null ? null : JSON.parse(raw);
      if (typeof released === 'boolean') return released;
    } else {
      // Not awaited: a stalled cancel must not hold the answer.
      void response.body?.cancel().catch(() => {});
    }
  } catch {
    // Transport, timeout, invalid window or unreadable body: the line below.
  }
  console.error('release_edge_rate_limit unavailable');
  return false;
}

/**
 * Seconds until `resetAt`, at least 1. An unreadable reset falls back to
 * `fallbackSeconds`; `maxSeconds` caps a far-future reset for callers that
 * promise a bounded delay.
 */
export function retryAfterSeconds(
  resetAt: string,
  fallbackSeconds: number,
  maxSeconds = Number.POSITIVE_INFINITY,
  now = Date.now(),
): number {
  const resetMs = new Date(resetAt).getTime();
  if (!Number.isFinite(resetMs)) return fallbackSeconds;
  return Math.max(1, Math.min(Math.ceil((resetMs - now) / 1000), maxSeconds));
}
