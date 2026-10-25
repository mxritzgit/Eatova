// Every paid outbound call requires a fresh, non-refundable database claim.
import type { AiCallLog } from './ai_telemetry.ts';
import { nextUtcMidnightIso } from './plan.ts';

export type ProviderOperation = 'coach_classifier' | 'coach_answer' | 'coach_recipe' |
  'coach_plan' | 'coach_image' | 'analyze_meal';
/** Which ceiling of reserve_ai_provider_call denied (20261026100000). */
export type ProviderBudgetScope = 'all' | 'images' | 'plan' | 'free' | 'account';
const BUDGET_SCOPES: ReadonlySet<unknown> = new Set<ProviderBudgetScope>(['all', 'images', 'plan', 'free', 'account']);
/**
 * Reserves one paid call. Every paid call passes through the request's budget
 * first, so it also carries the request's AI call log (ai_telemetry.ts).
 */
export type ProviderCallBudget = ((operation: ProviderOperation) => Promise<void>) & {
  readonly calls?: AiCallLog;
};

export class ProviderBudgetError extends Error {
  readonly status: number;
  constructor(
    readonly code: 'ai_budget_exhausted' | 'ai_disabled' | 'ai_budget_unavailable',
    /** Only for `ai_budget_exhausted`; undefined when the RPC named none it knows. */
    readonly scope?: ProviderBudgetScope,
  ) {
    super(code);
    this.name = 'ProviderBudgetError';
    this.status = code === 'ai_budget_exhausted' ? 429 : 503;
  }
}

/**
 * The public body of a budget stop. A capacity denial also says which ceiling
 * (when known) and when every ceiling resets: the next 00:00 UTC.
 */
export function providerBudgetErrorBody(error: ProviderBudgetError, nowMs = Date.now()): Record<string, string> {
  if (error.code !== 'ai_budget_exhausted') return { error: error.code };
  return { error: error.code, ...(error.scope ? { scope: error.scope } : {}), resetAt: nextUtcMidnightIso(nowMs) };
}

interface BudgetContext {
  supabaseUrl: string;
  serviceKey: string;
  userId: string;
  signal?: AbortSignal;
  timeoutMs?: number;
  /** The request's AI call log, handed on to the provider calls. */
  calls?: AiCallLog;
}

export function providerCallBudget(context: BudgetContext): ProviderCallBudget {
  const reserve = async (operation: ProviderOperation): Promise<void> => {
    const signal = AbortSignal.any([
      AbortSignal.timeout(Math.max(1, Math.min(context.timeoutMs ?? 5000, 5000))),
      ...(context.signal ? [context.signal] : []),
    ]);
    let reader: ReadableStreamDefaultReader<Uint8Array> | undefined;
    const abort = () => { void reader?.cancel().catch(() => {}); };
    signal.addEventListener('abort', abort, { once: true });
    try {
      signal.throwIfAborted();
      const response = await fetch(`${context.supabaseUrl}/rest/v1/rpc/reserve_ai_provider_call`, {
        method: 'POST',
        headers: { 'apikey': context.serviceKey, 'Authorization': `Bearer ${context.serviceKey}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({ p_user_id: context.userId, p_operation: operation }),
        signal,
      });
      if (!response.ok || !response.body) {
        void response.body?.cancel().catch(() => {});
        throw new ProviderBudgetError('ai_budget_unavailable');
      }
      reader = response.body.getReader();
      let bytes = 0;
      let raw = '';
      const decoder = new TextDecoder();
      while (true) {
        signal.throwIfAborted();
        const { done, value } = await reader.read();
        signal.throwIfAborted();
        if (done) break;
        bytes += value.byteLength;
        if (bytes > 4096) throw new ProviderBudgetError('ai_budget_unavailable');
        raw += decoder.decode(value, { stream: true });
      }
      raw += decoder.decode();
      const result = JSON.parse(raw);
      if (result?.allowed === true && result.reason === 'allowed') return;
      if (result?.allowed === false && result.reason === 'budget_exhausted') {
        // An unknown scope is no reason to fail: the denial itself stands.
        throw new ProviderBudgetError('ai_budget_exhausted',
          BUDGET_SCOPES.has(result.scope) ? result.scope as ProviderBudgetScope : undefined);
      }
      if (result?.allowed === false && result.reason === 'disabled') throw new ProviderBudgetError('ai_disabled');
      throw new ProviderBudgetError('ai_budget_unavailable');
    } catch (error) {
      if (error instanceof ProviderBudgetError) throw error;
      // RPC bodies/transport exceptions never become public diagnostics.
      throw new ProviderBudgetError('ai_budget_unavailable');
    } finally {
      signal.removeEventListener('abort', abort);
      void reader?.cancel().catch(() => {});
    }
  };
  return Object.assign(reserve, { calls: context.calls });
}
