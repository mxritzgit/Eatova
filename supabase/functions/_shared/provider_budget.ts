// Every paid outbound call requires a fresh, non-refundable database claim.
export type ProviderOperation = 'coach_classifier' | 'coach_answer' | 'coach_recipe' |
  'coach_plan' | 'coach_image' | 'analyze_meal';
export type ProviderCallBudget = (operation: ProviderOperation) => Promise<void>;

export class ProviderBudgetError extends Error {
  readonly status: number;
  constructor(readonly code: 'ai_budget_exhausted' | 'ai_disabled' | 'ai_budget_unavailable') {
    super(code);
    this.name = 'ProviderBudgetError';
    this.status = code === 'ai_budget_exhausted' ? 429 : 503;
  }
}

interface BudgetContext {
  supabaseUrl: string;
  serviceKey: string;
  userId: string;
  signal?: AbortSignal;
  timeoutMs?: number;
}

export function providerCallBudget(context: BudgetContext): ProviderCallBudget {
  return async (operation) => {
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
        await response.body?.cancel().catch(() => {});
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
        throw new ProviderBudgetError('ai_budget_exhausted');
      }
      if (result?.allowed === false && result.reason === 'disabled') throw new ProviderBudgetError('ai_disabled');
      throw new ProviderBudgetError('ai_budget_unavailable');
    } catch (error) {
      if (error instanceof ProviderBudgetError) throw error;
      // RPC bodies/transport exceptions never become public diagnostics.
      throw new ProviderBudgetError('ai_budget_unavailable');
    } finally {
      signal.removeEventListener('abort', abort);
      await reader?.cancel().catch(() => {});
    }
  };
}
