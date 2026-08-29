// Opportunistic table hygiene for public.edge_rate_limits.
//
// Always called fire-and-forget (`void pruneRateLimits(...)`) so the user
// request never waits for it. That is exactly why every error must stay
// inside: a rejecting fetch would be an unhandled rejection and kill the
// isolate — in analyze-meal that lands mid model call, with the provider call
// paid, the rate-limit slot spent and no refund path.
//
// Shared by analyze-meal, search-key and coach-chat.

/** Credentials of the service-role call. An object rather than two string
 *  parameters: swapped, they would go out with the key as base URL and nothing
 *  would look wrong. */
export type PruneRateLimitsOptions = {
  supabaseUrl: string;
  serviceKey: string;
  /** Overrides PRUNE_TIMEOUT_MS; only meant for tests. */
  timeoutMs?: number;
};

/**
 * Deadline for the cleanup call (P6-07). Nobody waits for the result, but a
 * hanging fetch keeps the isolate and its connection alive for as long as the
 * platform allows. Generous, because this is housekeeping that may lose a race
 * against a busy table without anyone noticing.
 */
export const PRUNE_TIMEOUT_MS = 10_000;

/**
 * Calls the `prune_edge_rate_limits` RPC and swallows every error.
 *
 * ALWAYS resolves, network errors and error statuses included, so
 * `void pruneRateLimits(...)` stays without consequence.
 */
export async function pruneRateLimits(options: PruneRateLimitsOptions): Promise<void> {
  try {
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
