// The store table clients: what each sends, how a 22023 refusal differs from
// an outage, and that nothing sensitive reaches the log. No network: fetch is
// stubbed and restored per test.
import {
  markStoreSubscriptionAcknowledged,
  planSnapshot,
  recordStoreNotification,
  recordStoreSubscription,
  type StoreRpcContext,
  type StoreRpcResult,
  storeAccountOwner,
  storeAccountTokenOf,
  storeSubscriptionOwner,
  type StoreSubscriptionRecord,
} from './store_records.ts';

const USER = '11111111-1111-4111-8111-111111111111';
const TOKEN = '22222222-2222-4222-8222-222222222222';
const PURCHASE_TOKEN = 'purchase-token-secret';
const ctx: StoreRpcContext = { supabaseUrl: 'https://store.invalid', serviceKey: 'test-service-key' };

const RECORD: StoreSubscriptionRecord = {
  userId: USER, platform: 'google', storeKey: PURCHASE_TOKEN, productId: 'eatova_premium',
  basePlanId: 'yearly', status: 'active', expiresAt: '2027-10-25T08:00:00.000Z', autoRenewing: true,
  environment: 'production', ownership: null, acknowledged: false, linkedStoreKey: null,
  lastTransactionId: 'GPA.1234', eventAt: null,
};

const SNAPSHOT = {
  tier: 'premium', subscription: { platform: 'google', status: 'active' },
  limits: { current: {}, free: {}, premium: {} }, legacy: null,
  usage: { day: '2026-10-25', coach: 1, meal_analysis: 0, recipe_import: 0 },
  reset_at: '2026-10-26T00:00:00Z',
};

function assert(value: boolean, message: string): void {
  if (!value) throw new Error(message);
}

function assertJson(actual: unknown, expected: unknown, message: string): void {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a !== e) throw new Error(`${message}: expected ${e}, got ${a}`);
}

interface Seen { url: string; init: RequestInit }

/** Runs `run` with fetch answering `respond`; records requests and console.error. */
async function withFetch(
  respond: (seen: Seen) => Response | Promise<Response>,
  run: (requests: Seen[], errors: string[]) => Promise<void>,
): Promise<void> {
  const savedFetch = globalThis.fetch;
  const savedError = console.error;
  const requests: Seen[] = [];
  const errors: string[] = [];
  globalThis.fetch = ((input: string | URL | Request, init?: RequestInit) => {
    const seen = { url: String(input), init: init ?? {} };
    requests.push(seen);
    return Promise.resolve(respond(seen));
  }) as typeof fetch;
  console.error = (...args: unknown[]) => { errors.push(args.map(String).join(' ')); };
  try {
    await run(requests, errors);
  } finally {
    globalThis.fetch = savedFetch;
    console.error = savedError;
  }
}

Deno.test('each client sends its call with the service key and maps the answer', async () => {
  const cases: Array<{
    call: () => Promise<StoreRpcResult<unknown>>;
    answer: unknown;
    url: string;
    body?: unknown;
    value: unknown;
  }> = [
    {
      call: () => recordStoreSubscription(ctx, RECORD),
      answer: { outcome: 'stored', tier: 'premium' },
      url: '/rest/v1/rpc/record_store_subscription',
      body: {
        p_user_id: USER, p_platform: 'google', p_store_key: PURCHASE_TOKEN, p_product_id: 'eatova_premium',
        p_base_plan_id: 'yearly', p_status: 'active', p_expires_at: '2027-10-25T08:00:00.000Z',
        p_auto_renewing: true, p_environment: 'production', p_ownership: null, p_acknowledged: false,
        p_linked_store_key: null, p_last_transaction_id: 'GPA.1234', p_event_at: null,
        p_rebind: false, p_purchase_at: null,
      },
      value: { outcome: 'stored', tier: 'premium' },
    },
    {
      call: () => markStoreSubscriptionAcknowledged(ctx, 'google', PURCHASE_TOKEN),
      answer: true,
      url: '/rest/v1/rpc/mark_store_subscription_acknowledged',
      body: { p_platform: 'google', p_store_key: PURCHASE_TOKEN },
      value: true,
    },
    {
      call: () => recordStoreNotification(ctx, 'apple', 'notification-1'),
      answer: false,
      url: '/rest/v1/rpc/record_store_notification',
      body: { p_source: 'apple', p_notification_id: 'notification-1' },
      value: false,
    },
    {
      call: () => storeAccountOwner(ctx, TOKEN),
      answer: USER,
      url: '/rest/v1/rpc/store_account_owner',
      body: { p_token: TOKEN },
      value: USER,
    },
    {
      call: () => storeSubscriptionOwner(ctx, 'google', PURCHASE_TOKEN),
      answer: null,
      url: '/rest/v1/rpc/store_subscription_owner',
      body: { p_platform: 'google', p_store_key: PURCHASE_TOKEN },
      value: null,
    },
    {
      call: () => storeAccountTokenOf(ctx, USER),
      answer: [{ token: TOKEN }],
      url: `/rest/v1/store_account_tokens?select=token&user_id=eq.${USER}&limit=1`,
      value: TOKEN,
    },
    {
      call: () => storeAccountTokenOf(ctx, USER),
      answer: [],
      url: `/rest/v1/store_account_tokens?select=token&user_id=eq.${USER}&limit=1`,
      value: null,
    },
    {
      call: () => planSnapshot(ctx, USER),
      answer: SNAPSHOT,
      url: '/rest/v1/rpc/plan_snapshot',
      body: { p_user_id: USER },
      value: SNAPSHOT,
    },
  ];
  for (const testCase of cases) {
    await withFetch(() => Response.json(testCase.answer), async (requests, errors) => {
      assertJson(await testCase.call(), { kind: 'ok', value: testCase.value }, testCase.url);
      const [seen] = requests;
      const headers = new Headers(seen.init.headers);
      assert(requests.length === 1 && seen.url === `https://store.invalid${testCase.url}`, `${testCase.url}: target`);
      assert(headers.get('authorization') === 'Bearer test-service-key' && headers.get('apikey') === 'test-service-key',
        `${testCase.url}: service key`);
      assert(seen.init.redirect === 'error' && seen.init.signal instanceof AbortSignal, `${testCase.url}: no redirect, bounded`);
      if (testCase.body === undefined) assert(seen.init.method === 'GET' && seen.init.body === undefined, 'table read');
      else assertJson(JSON.parse(String(seen.init.body)), testCase.body, `${testCase.url}: arguments`);
      assert(errors.length === 0, `${testCase.url}: no log on success`);
    });
  }
});

Deno.test('a 22023 refusal is invalid, every other failure unavailable, and nothing sensitive is logged', async () => {
  const refusal = (code: string, status = 400) =>
    () => Response.json({ code, message: `invalid ${PURCHASE_TOKEN}`, details: USER }, { status });
  const cases: Array<[string, () => Response | Promise<Response>, 'invalid' | 'unavailable']> = [
    ['22023', refusal('22023'), 'invalid'],
    ['foreign key', refusal('23503', 409), 'unavailable'],
    ['server error', refusal('XX000', 500), 'unavailable'],
    ['gateway page', () => new Response(`<html>${PURCHASE_TOKEN}</html>`, { status: 502 }), 'unavailable'],
    ['unexpected outcome', () => Response.json({ outcome: 'rebound', tier: 'premium' }), 'unavailable'],
    ['unexpected tier', () => Response.json({ outcome: 'stored', tier: 'gold' }), 'unavailable'],
    ['not JSON', () => new Response('{"outcome":'), 'unavailable'],
    ['oversized', () => new Response(' '.repeat(2000) + '{"outcome":"stored","tier":"free"}'), 'unavailable'],
    ['transport error', () => Promise.reject(new TypeError(`connect ${PURCHASE_TOKEN}`)), 'unavailable'],
  ];
  for (const [label, respond, kind] of cases) {
    await withFetch(respond, async (_requests, errors) => {
      assertJson(await recordStoreSubscription(ctx, RECORD), { kind }, label);
      const log = errors.join('\n');
      assert(kind === 'invalid' ? errors.length === 0 : errors.length === 1, `${label}: log lines`);
      assert(!log.includes(PURCHASE_TOKEN) && !log.includes(USER) && !log.includes('GPA.'), `${label}: sanitized log`);
    });
  }
});

Deno.test('a stalled answer ends at the timeout as unavailable', async () => {
  let cancelled = false;
  await withFetch(() => new Response(new ReadableStream<Uint8Array>({
    start(controller) { controller.enqueue(new TextEncoder().encode('{')); },
    cancel() { cancelled = true; },
  })), async () => {
    assertJson(await recordStoreNotification({ ...ctx, timeoutMs: 20 }, 'google', 'message-1'), { kind: 'unavailable' }, 'timeout');
  });
  assert(cancelled, 'the stalled body is cancelled');
});

Deno.test('answers outside the contract are outages, inputs that cannot match skip the call', async () => {
  const outages: Array<[string, () => Promise<StoreRpcResult<unknown>>, unknown]> = [
    ['notification as string', () => recordStoreNotification(ctx, 'apple', 'n'), 'true'],
    ['owner not a uuid', () => storeAccountOwner(ctx, TOKEN), 'someone'],
    ['two token rows', () => storeAccountTokenOf(ctx, USER), [{ token: TOKEN }, { token: TOKEN }]],
    ['token not a uuid', () => storeAccountTokenOf(ctx, USER), [{ token: 'x' }]],
    ['snapshot without usage', () => planSnapshot(ctx, USER), { ...SNAPSHOT, usage: undefined }],
    ['snapshot with a foreign tier', () => planSnapshot(ctx, USER), { ...SNAPSHOT, tier: 'legacy' }],
  ];
  for (const [label, call, answer] of outages) {
    await withFetch(() => Response.json(answer), async () => {
      assertJson(await call(), { kind: 'unavailable' }, label);
    });
  }
  await withFetch(() => { throw new Error('unexpected fetch'); }, async (requests) => {
    assertJson(await storeAccountOwner(ctx, 'not-a-token'), { kind: 'ok', value: null }, 'malformed token has no owner');
    assertJson(await storeSubscriptionOwner(ctx, 'apple', ''), { kind: 'ok', value: null }, 'empty store key has no owner');
    assertJson(await storeAccountTokenOf(ctx, 'x&user_id=neq.0'), { kind: 'invalid' }, 'no query injection');
    assertJson(await planSnapshot(ctx, 'x'), { kind: 'invalid' }, 'snapshot needs a user id');
    assert(requests.length === 0, 'nothing sent');
  });
});
