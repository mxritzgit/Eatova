import { providerCallBudget, ProviderBudgetError } from './provider_budget.ts';

const context = { supabaseUrl: 'https://budget.invalid', serviceKey: 'test-service', userId: '11111111-1111-4111-8111-111111111111' };
function assert(value: boolean, message: string): void { if (!value) throw new Error(message); }

async function failure(response: () => Response, code = 'ai_budget_unavailable', timeoutMs = 5000): Promise<void> {
  const saved = globalThis.fetch;
  globalThis.fetch = (() => Promise.resolve(response())) as typeof fetch;
  try {
    let error: unknown;
    try { await providerCallBudget({ ...context, timeoutMs })('coach_answer'); } catch (caught) { error = caught; }
    assert(error instanceof ProviderBudgetError && error.code === code, 'exact safe failure code');
  } finally { globalThis.fetch = saved; }
}

Deno.test('provider budget requires fresh verified claims for every call', async () => {
  const saved = globalThis.fetch;
  const bodies: unknown[] = [];
  globalThis.fetch = ((_input: unknown, init?: RequestInit) => {
    const headers = new Headers(init?.headers);
    assert(headers.get('Authorization') === 'Bearer test-service', 'server authorization');
    assert(init?.signal instanceof AbortSignal, 'bounded RPC');
    bodies.push(JSON.parse(String(init?.body)));
    return Promise.resolve(Response.json({ allowed: true, reason: 'allowed' }));
  }) as typeof fetch;
  try {
    const budget = providerCallBudget(context);
    await budget('coach_classifier');
    await budget('coach_answer');
    assert(JSON.stringify(bodies) === JSON.stringify([
      { p_user_id: context.userId, p_operation: 'coach_classifier' },
      { p_user_id: context.userId, p_operation: 'coach_answer' },
    ]), 'no cached approval or client-supplied identity');
  } finally { globalThis.fetch = saved; }
});

Deno.test('provider budget rejects denied, missing, malformed and oversized responses', async () => {
  await failure(() => Response.json({ allowed: false, reason: 'budget_exhausted' }), 'ai_budget_exhausted');
  await failure(() => Response.json({ allowed: false, reason: 'disabled' }), 'ai_disabled');
  for (const raw of ['{}', 'null', '[]', '{"allowed":true}', '{"allowed":"true","reason":"allowed"}', 'invalid', 'x'.repeat(4097)]) {
    await failure(() => new Response(raw));
  }
  await failure(() => new Response('PRIVATE_RPC_FAILURE', { status: 500 }));
});

Deno.test('provider budget bounds stalled response bodies and cancels the reader', async () => {
  let cancelled = false;
  await failure(() => new Response(new ReadableStream({
    start(controller) { controller.enqueue(new TextEncoder().encode('{')); },
    cancel() { cancelled = true; },
  })), 'ai_budget_unavailable', 10);
  assert(cancelled, 'body cancelled at deadline');
});

Deno.test('provider budget abort before execution cannot reserve or start work', async () => {
  const saved = globalThis.fetch;
  let calls = 0;
  globalThis.fetch = (() => { calls++; throw new Error('unexpected fetch'); }) as typeof fetch;
  try {
    const signal = AbortSignal.abort();
    try { await providerCallBudget({ ...context, signal })('coach_answer'); } catch (error) {
      assert(error instanceof ProviderBudgetError, 'sanitized abort');
    }
    assert(calls === 0, 'nothing sent');
  } finally { globalThis.fetch = saved; }
});

Deno.test('provider budget HTTP outage does not await stalled response cancellation', async () => {
  const saved = globalThis.fetch;
  globalThis.fetch = (() => Promise.resolve(new Response(new ReadableStream<Uint8Array>({
    cancel() { return new Promise<void>(() => {}); },
  }), { status: 500 }))) as typeof fetch;
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    let error: unknown;
    try {
      await Promise.race([
        providerCallBudget(context)('coach_answer'),
        new Promise<never>((_resolve, reject) => {
          timer = setTimeout(() => reject(new Error('budget waited for stalled body.cancel()')), 1000);
        }),
      ]);
    } catch (caught) { error = caught; }
    assert(error instanceof ProviderBudgetError && error.code === 'ai_budget_unavailable', 'bounded fail-closed outage');
  } finally {
    clearTimeout(timer);
    globalThis.fetch = saved;
  }
});
