// Opportunistic table hygiene for public.edge_rate_limits.
//
// Always called fire-and-forget (`void pruneRateLimits(...)`) so the user
// request never waits for it. That is exactly why every error must stay
// inside: a rejecting fetch would be an unhandled rejection and kill the
// isolate — in analyze-meal that lands mid model call, with the provider call
// paid, the rate-limit slot spent and no refund path.
//
// A6 (performance audit 2026-09-01): all three functions fired this on EVERY
// request they let through, so every request paid a DELETE on a table whose
// whole job is to forget rows older than two days. The work is not per-request
// work — it is housekeeping that only has to happen often enough. It is
// therefore SAMPLED now; see PRUNE_SAMPLE_RATE.
//
// Shared by analyze-meal, search-key and coach-chat.

import { positiveIntFromEnv } from "./env.ts";

/** Credentials of the service-role call. An object rather than two string
 *  parameters: swapped, they would go out with the key as base URL and nothing
 *  would look wrong. */
export type PruneRateLimitsOptions = {
  supabaseUrl: string;
  serviceKey: string;
  /** Overrides PRUNE_TIMEOUT_MS; only meant for tests. */
  timeoutMs?: number;
  /**
   * Source of the sampling draw, `Math.random`-shaped: a value in [0, 1).
   *
   * Injectable so a test decides instead of the dice — `() => 0` always draws
   * the pruning slot, `() => 0.99` never does at any rate above 1. Production
   * never passes it; leaving the draw to Math.random in tests would make every
   * assertion about the outgoing call a 1-in-N coin flip.
   */
  sampler?: () => number;
};

/**
 * Deadline for the cleanup call (P6-07). Nobody waits for the result, but a
 * hanging fetch keeps the isolate and its connection alive for as long as the
 * platform allows. Generous, because this is housekeeping that may lose a race
 * against a busy table without anyone noticing.
 */
export const PRUNE_TIMEOUT_MS = 10_000;

/**
 * Sampling divisor (A6): on average one call in PRUNE_SAMPLE_RATE issues the
 * DELETE, the other nineteen return without touching the network.
 *
 * WHY 20. What bounds the table is the RPC's own retention
 * (`window_start < now() - interval '2 days'`, 20260517220000), NOT how often
 * it runs — a skipped sweep costs nothing as long as SOME sweep lands well
 * inside those two days. So the only question is the wall-clock gap between
 * sweeps at the LOWEST traffic where the table exists at all: at a trickle of
 * ~20 requests a day one in 20 still sweeps about daily, half the retention
 * window, while at real traffic it drops 95 % of the DELETEs — which is
 * exactly where they cost. A larger divisor buys almost nothing (the remaining
 * 5 % is already noise) and stretches that low-traffic gap past two days,
 * where rows would start outliving their retention; a smaller one keeps a
 * fifth of the load for no extra safety.
 *
 * WHY a random draw and not a per-isolate counter. Edge isolates are recycled
 * constantly. Any "every Nth call" counter restarts at zero on each cold start
 * and would sweep on the FIRST request of every fresh isolate — under bursty
 * traffic that is most requests, i.e. the behaviour being removed. A memoryless
 * draw does not care how long an isolate lives.
 */
export const PRUNE_SAMPLE_RATE = 20;

/** Operator override for the divisor. 1 restores the pre-A6 "prune on every
 *  request" behaviour, which is also how a test pins the call deterministically
 *  without reaching for the `sampler` seam. */
export const PRUNE_SAMPLE_RATE_ENV = "PRUNE_SAMPLE_RATE";

/** Ceiling for the override. Past this the low-traffic gap between sweeps runs
 *  far beyond the two-day retention, so a fat-fingered secret would quietly
 *  turn the cleanup off; positiveIntFromEnv rejects it and warns instead. */
export const PRUNE_SAMPLE_RATE_MAX = 1000;

/** Last raw env string seen, and what it parsed to. `null` means "nothing read
 *  yet" and is distinct from an unset variable (`undefined`).
 *
 *  The parse is memoised because this runs per request, not at module load like
 *  the other positiveIntFromEnv callers: a value that IS set but unusable warns
 *  on every parse, and an unmemoised read would put that line into function_logs
 *  once per request of all three functions instead of once per cold start. */
let sampleRateRaw: string | undefined | null = null;
let sampleRateValue = PRUNE_SAMPLE_RATE;

function sampleRate(): number {
  let raw: string | undefined;
  try {
    raw = Deno.env.get(PRUNE_SAMPLE_RATE_ENV);
  } catch {
    // No env permission is not a reason to stop cleaning up; the code default
    // applies. Never rethrown — see the always-resolves invariant below.
    return PRUNE_SAMPLE_RATE;
  }
  if (raw !== sampleRateRaw) {
    sampleRateRaw = raw;
    sampleRateValue = positiveIntFromEnv(
      PRUNE_SAMPLE_RATE_ENV,
      PRUNE_SAMPLE_RATE,
      PRUNE_SAMPLE_RATE_MAX,
    );
  }
  return sampleRateValue;
}

/** Whether this call draws the pruning slot. Every uncertain answer is "yes":
 *  pruning too often is the old, harmless behaviour, while wrongly skipping
 *  forever lets the table grow unwatched. */
function drawsPruneSlot(sampler: () => number = Math.random): boolean {
  const rate = sampleRate();
  if (rate <= 1) return true;
  const draw = sampler();
  // A draw outside [0, 1) means the injected source is not Math.random-shaped;
  // Math.floor(NaN) would otherwise be permanently != 0, i.e. cleanup off.
  if (!Number.isFinite(draw) || draw < 0 || draw >= 1) return true;
  return Math.floor(draw * rate) === 0;
}

/**
 * Calls the `prune_edge_rate_limits` RPC and swallows every error.
 *
 * ALWAYS resolves, network errors and error statuses included, so
 * `void pruneRateLimits(...)` stays without consequence. A call that loses the
 * sampling draw resolves just as quietly — no log, because a line per skipped
 * call would cost more than the DELETE it replaced.
 */
export async function pruneRateLimits(options: PruneRateLimitsOptions): Promise<void> {
  try {
    // Inside the try on purpose: the env read and the injected sampler are
    // foreign code, and the invariant above holds for them too.
    if (!drawsPruneSlot(options.sampler)) return;
    const response = await fetch(`${options.supabaseUrl}/rest/v1/rpc/prune_edge_rate_limits`, {
      method: "POST",
      headers: {
        apikey: options.serviceKey,
        authorization: `Bearer ${options.serviceKey}`,
        "content-type": "application/json",
      },
      body: "{}",
      signal: AbortSignal.timeout(Math.max(1, options.timeoutMs ?? PRUNE_TIMEOUT_MS)),
    });
    // fetch does not throw on 4xx/5xx. Without this, a permanently failing RPC
    // (revoked grant, missed migration) would stay invisible while the table
    // grows. Log the status only; the body holds nothing needed here.
    if (!response.ok) {
      console.error(`prune_edge_rate_limits failed: HTTP ${response.status}`);
    }
  } catch (e) {
    console.error(`prune_edge_rate_limits failed: ${e instanceof Error ? e.message : String(e)}`);
  }
}
