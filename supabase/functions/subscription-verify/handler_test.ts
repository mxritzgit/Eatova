// End-to-end tests for subscription-verify (docs/PREMIUM.md 3.4) over a
// stubbed fetch: the status table, Google's store-then-acknowledge order, the
// Apple record and which rows a refresh re-checks. A generated Apple chain
// with an injected root pin, a generated service-account key, a fixed clock.
// No network; env, fetch and console are restored after every scenario, and
// every scenario checks that no token, JWS or user id reached a log line or
// the answer.

import { createHandler } from './handler.ts';
import { resetAuthFailCacheForTests } from '../_shared/auth_fail_gate.ts';
import { userToken } from '../_shared/auth_test_fixtures.ts';
import { clearGoogleAuthCaches } from '../_shared/google_auth.ts';
import {
  buildAppleChain,
  generateChainKeys,
  pkcs8Pem,
  rsaKeyPair,
  signEs256Jws,
  type TestChain,
} from '../_shared/store_test_fixtures.ts';

const NOW = Date.parse('2026-10-25T08:00:00.000Z');
const HOUR = 3_600_000;
const DAY = 24 * HOUR;
const USER_ID = '11111111-1111-4111-8111-111111111111';
const OTHER_USER = '33333333-3333-4333-8333-333333333333';
const ACCOUNT_TOKEN = '00000000-0000-4000-8000-0000000000a1';
const OTHER_TOKEN = '00000000-0000-4000-8000-0000000000b2';
const BASE = 'https://supabase.test.invalid';
const ANON = 'test-anon-key';
const BEARER = userToken(USER_ID);
const PURCHASE_TOKEN = 'kmopnbecjkeiochgdapbnlio.AO-J1Ox-secret-purchase-token';
const ACCESS_TOKEN = 'ya29.c.test-access-token';
const PLAY = 'https://androidpublisher.googleapis.com/androidpublisher/v3/applications/com.eatova.app/purchases';
const GOOGLE_VERIFY = {
  action: 'verify',
  platform: 'google',
  productId: 'eatova_premium',
  purchaseToken: PURCHASE_TOKEN,
};
const ENV_KEYS = [
  'SUPABASE_URL',
  'SUPABASE_ANON_KEY',
  'SUPABASE_SERVICE_ROLE_KEY',
  'EATOVA_PLAY_SERVICE_ACCOUNT_JSON',
  'EATOVA_PLAY_PACKAGE_NAME',
  'EATOVA_PREMIUM_PRODUCT_IDS',
  'EATOVA_APPLE_BUNDLE_ID',
  'EATOVA_ALLOWED_ORIGINS',
];

type Json = Record<string, unknown>;
type Handler = (request: Request) => Promise<Response>;

function check(value: boolean, message: string): asserts value {
  if (!value) throw new Error(message);
}

function same(actual: unknown, expected: unknown, message: string): void {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a !== e) throw new Error(`${message}: expected ${e}, got ${a}`);
}

/** The fields of `expected` in `actual`, nothing else compared. */
function contains(actual: Json, expected: Json, message: string): void {
  same(Object.fromEntries(Object.keys(expected).map((key) => [key, actual[key]])), expected, message);
}

// ---------------------------------------------------------------------------
// Fixtures

let chainPromise: Promise<TestChain> | undefined;
const chain = () => chainPromise ??= generateChainKeys().then((keys) => buildAppleChain(keys));

let keyPromise: Promise<string> | undefined;
const serviceAccountJson = () =>
  keyPromise ??= rsaKeyPair().then(async (pair) =>
    JSON.stringify({
      type: 'service_account',
      private_key_id: 'test-key-1',
      private_key: await pkcs8Pem(pair.privateKey),
      client_email: 'play-verify@eatova-test.iam.gserviceaccount.com',
    })
  );

/** A handler trusting the generated root, at NOW. */
async function testHandler(): Promise<Handler> {
  return createHandler({ appleRootSha256: (await chain()).rootSha256, now: () => NOW });
}

/** A yearly Play purchase in its trial, bound to the caller, not yet acknowledged. */
function purchase(overrides: Json = {}): Json {
  return {
    startTime: '2026-10-25T07:59:00.000Z',
    subscriptionState: 'SUBSCRIPTION_STATE_ACTIVE',
    acknowledgementState: 'ACKNOWLEDGEMENT_STATE_PENDING',
    externalAccountIdentifiers: { obfuscatedExternalAccountId: ACCOUNT_TOKEN },
    lineItems: [{
      productId: 'eatova_premium',
      expiryTime: '2026-11-01T08:00:00.000Z',
      autoRenewingPlan: { autoRenewEnabled: true },
      offerDetails: { basePlanId: 'yearly', offerId: 'yearly-trial-7d' },
      latestSuccessfulOrderId: 'GPA.3375-4417-2275-01234',
    }],
    ...overrides,
  };
}

const APPLE_TRANSACTION = {
  transactionId: '2000000812345679',
  originalTransactionId: '2000000812345678',
  bundleId: 'com.eatova.app',
  productId: 'eatova_premium_yearly',
  type: 'Auto-Renewable Subscription',
  inAppOwnershipType: 'PURCHASED',
  environment: 'Sandbox',
  appAccountToken: ACCOUNT_TOKEN,
  purchaseDate: NOW - 60_000,
  expiresDate: NOW + 7 * DAY,
  signedDate: NOW - 1_000,
};

async function appleVerify(overrides: Json = {}): Promise<Json> {
  const { x5c, leafKey } = await chain();
  const signedTransaction = await signEs256Jws({ alg: 'ES256', x5c }, { ...APPLE_TRANSACTION, ...overrides }, leafKey);
  return { action: 'verify', platform: 'apple', signedTransaction };
}

function snapshot(tier: 'free' | 'premium'): Json {
  return {
    tier,
    subscription: null,
    limits: { current: {}, free: {}, premium: {} },
    legacy: null,
    usage: { day: '2026-10-25', coach: 0, meal_analysis: 0, recipe_import: 0 },
    reset_at: '2026-10-26T00:00:00Z',
  };
}

// ---------------------------------------------------------------------------
// The stubbed backend

interface StoredRow {
  key: string;
  user?: string;
  platform?: 'google' | 'apple';
  status: string;
  expires: number;
  verified: number;
  superseded?: string;
}

interface World {
  /** Status of the /auth/v1/user lookup; 200 answers USER_ID. */
  auth?: number;
  gates?: 'allowed' | 'denied' | 'broken';
  /** The caller's store_account_tokens row; null: none yet. */
  accountToken?: string | null;
  /** false: EATOVA_PLAY_SERVICE_ACCOUNT_JSON unset. */
  serviceAccount?: boolean;
  /** subscriptionsv2 by purchase token: the purchase or an HTTP status. */
  play?: Record<string, Json | number>;
  /** HTTP status of record_store_subscription instead of its answer. */
  recordStatus?: number;
  /** The account every stored key already belongs to. */
  owner?: string;
  /** When `owner` bought (last_purchase_at); a newer Apple purchase with p_rebind moves the row. */
  ownerPurchasedAt?: number;
  /** HTTP status of Google's acknowledge instead of 200. */
  ackStatus?: number;
  rows?: StoredRow[];
}

interface Seen {
  url: string;
  method: string;
  body: string;
}

interface Outcome {
  status: number;
  body: Json;
  retryAfter: string | null;
  seen: Seen[];
  /** The p_* arguments of every record_store_subscription call. */
  records: Json[];
  /** Indexes into `seen`. */
  recordAt: number[];
  ackAt: number[];
  markAt: number[];
  playLookups: string[];
}

const ENTITLING = new Set(['active', 'grace', 'canceled']);

/** PostgREST over `rows`, for exactly the filters the refresh query uses. */
function selectRows(rows: StoredRow[], params: URLSearchParams): Json[] {
  const columns = (row: StoredRow): Record<string, string | number | null> => ({
    user_id: row.user ?? USER_ID,
    platform: row.platform ?? 'google',
    status: row.status,
    superseded_by: row.superseded ?? null,
    expires_at: row.expires,
    last_verified_at: row.verified,
  });
  let selected = [...rows];
  for (const [name, value] of params) {
    if (name === 'select') {
      check(value === 'store_key,product_id,environment,expires_at', `select ${value}`);
    } else if (name === 'order') {
      check(value === 'expires_at.desc', `order ${value}`);
      selected.sort((a, b) => b.expires - a.expires);
    } else if (name === 'limit') {
      selected = selected.slice(0, Number(value));
    } else {
      const dot = value.indexOf('.');
      const [op, operand] = [value.slice(0, dot), value.slice(dot + 1)];
      selected = selected.filter((row) => {
        const cell = columns(row)[name];
        check(cell !== undefined, `unknown column ${name}`);
        if (op === 'eq') return String(cell) === operand;
        if (op === 'lt') return Number(cell) < Date.parse(operand);
        if (op === 'in') return operand.replace(/^\(|\)$/g, '').split(',').includes(String(cell));
        if (op === 'is' && operand === 'null') return cell === null;
        throw new Error(`unknown filter ${name}=${value}`);
      });
    }
  }
  return selected.map((row) => ({
    store_key: row.key,
    product_id: 'eatova_premium',
    environment: 'production',
    expires_at: new Date(row.expires).toISOString(),
  }));
}

function backend(world: World, seen: Seen, state: { tier: 'free' | 'premium' }): Response {
  const url = new URL(seen.url);
  const path = url.origin === BASE ? url.pathname : `${url.origin}${url.pathname}`;
  if (path === '/auth/v1/user') {
    return world.auth && world.auth !== 200
      ? Response.json({ msg: 'invalid JWT' }, { status: world.auth })
      : Response.json({ id: USER_ID });
  }
  if (path === '/rest/v1/rpc/consume_edge_rate_limits') {
    const gates = JSON.parse(seen.body).p_gates as { limit: number; window_seconds: number }[];
    const resetAt = new Date(NOW + 600_000).toISOString();
    if (world.gates === 'broken') return Response.json({});
    if (world.gates === 'denied') {
      return Response.json([{ allowed: false, limit: 60, remaining: 0, resetAt, windowSeconds: 600 }]);
    }
    return Response.json(gates.map((gate) => ({
      allowed: true,
      limit: gate.limit,
      remaining: gate.limit - 1,
      resetAt,
      windowSeconds: gate.window_seconds,
    })));
  }
  if (path === '/rest/v1/rpc/consume_edge_rate_limit') return Response.json({ allowed: true });
  if (path === '/rest/v1/store_account_tokens') {
    const token = world.accountToken === undefined ? ACCOUNT_TOKEN : world.accountToken;
    return Response.json(token === null ? [] : [{ token }]);
  }
  if (path === '/rest/v1/store_subscriptions') return Response.json(selectRows(world.rows ?? [], url.searchParams));
  if (path === '/rest/v1/rpc/record_store_subscription') {
    if (world.recordStatus) return Response.json({ code: 'XX000' }, { status: world.recordStatus });
    const args = JSON.parse(seen.body) as Json;
    // The binding rule of record_store_subscription, as far as these tests need it.
    const rebinds = args.p_platform === 'apple' && args.p_rebind === true &&
      typeof args.p_purchase_at === 'string' && Date.parse(args.p_purchase_at) > (world.ownerPurchasedAt ?? -Infinity);
    if (world.owner && world.owner !== args.p_user_id && !rebinds) {
      return Response.json({ outcome: 'owned_by_other', tier: state.tier });
    }
    if (ENTITLING.has(String(args.p_status)) && Date.parse(String(args.p_expires_at)) > NOW) state.tier = 'premium';
    return Response.json({ outcome: 'stored', tier: state.tier });
  }
  if (path === '/rest/v1/rpc/plan_snapshot') return Response.json(snapshot(state.tier));
  if (path === 'https://oauth2.googleapis.com/token') {
    return Response.json({ access_token: ACCESS_TOKEN, expires_in: 3599, token_type: 'Bearer' });
  }
  if (path.startsWith(`${PLAY}/subscriptionsv2/tokens/`)) {
    const answer = world.play?.[decodeURIComponent(path.slice(`${PLAY}/subscriptionsv2/tokens/`.length))];
    check(answer !== undefined, 'subscriptionsv2 for an unknown token');
    return typeof answer === 'number' ? Response.json({}, { status: answer }) : Response.json(answer);
  }
  if (path.startsWith(`${PLAY}/subscriptions/`) && path.endsWith(':acknowledge')) {
    return Response.json({}, { status: world.ackStatus ?? 200 });
  }
  if (path === '/rest/v1/rpc/mark_store_subscription_acknowledged') return Response.json(true);
  throw new Error(`unexpected request ${path}`);
}

/** One request against the stubbed backend; restores env, fetch and console. */
async function run(
  world: World,
  body: unknown,
  options: { bearer?: string | null; raw?: string; handler?: Handler } = {},
): Promise<Outcome> {
  resetAuthFailCacheForTests();
  clearGoogleAuthCaches();
  const handler = options.handler ?? await testHandler();
  const saJson = await serviceAccountJson();
  const previousEnv = new Map(ENV_KEYS.map((key) => [key, Deno.env.get(key)]));
  const originalFetch = globalThis.fetch;
  const consoles = { log: console.log, info: console.info, warn: console.warn, error: console.error };
  const seen: Seen[] = [];
  const logs: string[] = [];
  const unexpected: string[] = [];
  const state = { tier: 'free' as 'free' | 'premium' };
  for (const key of ENV_KEYS) Deno.env.delete(key);
  Deno.env.set('SUPABASE_URL', BASE);
  Deno.env.set('SUPABASE_ANON_KEY', ANON);
  Deno.env.set('SUPABASE_SERVICE_ROLE_KEY', 'test-service-key');
  if (world.serviceAccount !== false) Deno.env.set('EATOVA_PLAY_SERVICE_ACCOUNT_JSON', saJson);
  console.log =
    console.info =
    console.warn =
    console.error =
      (...args: unknown[]) =>
        logs.push(args.map((arg) => typeof arg === 'string' ? arg : JSON.stringify(arg)).join(' '));
  globalThis.fetch = ((input: string | URL | Request, init: RequestInit = {}) => {
    const call = { url: String(input), method: init.method ?? 'GET', body: init.body ? String(init.body) : '' };
    seen.push(call);
    try {
      return Promise.resolve(backend(world, call, state));
    } catch (error) {
      unexpected.push((error as Error).message);
      return Promise.resolve(Response.json({}, { status: 500 }));
    }
  }) as typeof fetch;
  try {
    const headers: Record<string, string> = { 'content-type': 'application/json', 'cf-connecting-ip': '203.0.113.7' };
    const bearer = options.bearer === undefined ? BEARER : options.bearer;
    if (bearer !== null) headers.authorization = `Bearer ${bearer}`;
    const response = await handler(
      new Request('https://edge.test.invalid/subscription-verify', {
        method: 'POST',
        headers,
        body: options.raw ?? JSON.stringify(body),
      }),
    );
    const text = await response.text();
    check(unexpected.length === 0, `unexpected backend use: ${unexpected.join('; ')}`);
    // Never a token, a JWS or a user id in a log line or the answer.
    const secrets = [BEARER, USER_ID, ACCOUNT_TOKEN, PURCHASE_TOKEN, saJson.slice(150, 200), ACCESS_TOKEN];
    if (body !== null && typeof body === 'object') {
      secrets.push(
        ...Object.values(body).filter((value): value is string => typeof value === 'string' && value.length > 40),
      );
    }
    for (const secret of secrets) {
      check(!logs.some((line) => line.includes(secret)), `secret in a log line: ${logs.join(' | ')}`);
      check(!text.includes(secret), 'secret in the answer');
    }
    const at = (test: (call: Seen) => boolean) => seen.flatMap((call, index) => test(call) ? [index] : []);
    const recordAt = at((call) => call.url.endsWith('/rpc/record_store_subscription'));
    return {
      status: response.status,
      body: JSON.parse(text),
      retryAfter: response.headers.get('retry-after'),
      seen,
      records: recordAt.map((index) => JSON.parse(seen[index].body)),
      recordAt,
      ackAt: at((call) => call.url.endsWith(':acknowledge')),
      markAt: at((call) => call.url.endsWith('/rpc/mark_store_subscription_acknowledged')),
      playLookups: seen.filter((call) => call.url.startsWith(`${PLAY}/subscriptionsv2/tokens/`))
        .map((call) => decodeURIComponent(call.url.slice(`${PLAY}/subscriptionsv2/tokens/`.length))),
    };
  } finally {
    globalThis.fetch = originalFetch;
    Object.assign(console, consoles);
    for (const [key, value] of previousEnv) {
      if (value === undefined) Deno.env.delete(key);
      else Deno.env.set(key, value);
    }
  }
}

// ---------------------------------------------------------------------------

Deno.test('subscription-verify: jede Zeile der Statustabelle, ohne Schreiben und ohne Bestaetigung', async () => {
  const google = (overrides: Json = {}) => ({ play: { [PURCHASE_TOKEN]: purchase(overrides) } });
  const rows: {
    name: string;
    world?: World;
    body?: unknown;
    raw?: string;
    bearer?: string | null;
    handler?: Handler;
    status: number;
    answer: Json;
    recorded?: boolean;
  }[] = [
    { name: 'ohne Bearer', bearer: null, status: 401, answer: { error: 'missing_bearer_token' } },
    { name: 'Anon-Key statt Nutzertoken', bearer: ANON, status: 401, answer: { error: 'user_token_required' } },
    { name: 'GoTrue lehnt ab', world: { auth: 401 }, status: 401, answer: { error: 'invalid_user_token' } },
    { name: 'Tor erschoepft', world: { gates: 'denied' }, status: 429, answer: { error: 'rate_limited' } },
    { name: 'Limiter kaputt', world: { gates: 'broken' }, status: 503, answer: { error: 'rate_limit_unavailable' } },
    { name: 'kein JSON', raw: '{"action":', status: 400, answer: { error: 'invalid_request' } },
    {
      name: 'unbekanntes Feld',
      body: { ...GOOGLE_VERIFY, extra: 1 },
      status: 400,
      answer: { error: 'invalid_request' },
    },
    {
      name: 'Body ueber 64 KiB',
      body: { action: 'verify', platform: 'apple', signedTransaction: 'x'.repeat(70_000) },
      status: 400,
      answer: { error: 'invalid_request' },
    },
    {
      name: 'Google ohne Dienstkonto',
      world: { ...google(), serviceAccount: false },
      status: 503,
      answer: { error: 'store_not_configured' },
    },
    {
      name: 'Google nicht erreichbar',
      world: { play: { [PURCHASE_TOKEN]: 503 } },
      status: 503,
      answer: { error: 'store_unavailable' },
    },
    {
      name: 'Google-Produkt nicht freigegeben',
      world: google(),
      body: { ...GOOGLE_VERIFY, productId: 'eatova_lifetime' },
      status: 422,
      answer: { error: 'purchase_invalid', reason: 'product' },
    },
    {
      name: 'Google-Kauf eines anderen Kontos',
      world: google({ externalAccountIdentifiers: { obfuscatedExternalAccountId: OTHER_TOKEN } }),
      status: 422,
      answer: { error: 'purchase_invalid', reason: 'account' },
    },
    {
      name: 'Konto ohne Token, Kauf mit Token',
      world: { ...google(), accountToken: null },
      status: 422,
      answer: { error: 'purchase_invalid', reason: 'account' },
    },
    {
      name: 'Google-Zahlung ausstehend',
      world: google({ subscriptionState: 'SUBSCRIPTION_STATE_PENDING' }),
      status: 202,
      answer: { error: 'purchase_pending', plan: snapshot('free') },
    },
    {
      name: 'Kauf gehoert schon einem anderen Konto',
      world: { ...google(), owner: OTHER_USER },
      status: 409,
      answer: { error: 'purchase_owned_by_other_account' },
      recorded: true,
    },
    {
      name: 'Apple-Kette ohne Apples Wurzel',
      handler: createHandler({ now: () => NOW }),
      body: await appleVerify(),
      status: 422,
      answer: { error: 'purchase_invalid', reason: 'signature' },
    },
    {
      name: 'Apple fremdes Bundle',
      body: await appleVerify({ bundleId: 'com.example.other' }),
      status: 422,
      answer: { error: 'purchase_invalid', reason: 'bundle' },
    },
    {
      name: 'Apple kein Abo',
      body: await appleVerify({ type: 'Non-Consumable' }),
      status: 422,
      answer: { error: 'purchase_invalid', reason: 'product' },
    },
    {
      name: 'Apple Xcode-Testumgebung',
      body: await appleVerify({ environment: 'Xcode' }),
      status: 422,
      answer: { error: 'purchase_invalid', reason: 'environment' },
    },
    {
      name: 'Apple Familienfreigabe',
      body: await appleVerify({ inAppOwnershipType: 'FAMILY_SHARED' }),
      status: 422,
      answer: { error: 'purchase_invalid', reason: 'ownership' },
    },
    {
      name: 'Apple fremder appAccountToken',
      body: await appleVerify({ appAccountToken: OTHER_TOKEN }),
      status: 422,
      answer: { error: 'purchase_invalid', reason: 'account' },
    },
  ];
  for (const row of rows) {
    const result = await run(row.world ?? {}, row.body ?? GOOGLE_VERIFY, row);
    same([result.status, result.body], [row.status, row.answer], row.name);
    same(result.recordAt.length, row.recorded ? 1 : 0, `${row.name}: Schreibzugriffe`);
    same(result.ackAt.length, 0, `${row.name}: Bestaetigungen`);
    check(row.status !== 429 || /^[1-9]\d*$/.test(result.retryAfter ?? ''), `${row.name}: Retry-After`);
  }
});

Deno.test('subscription-verify: Google speichert erst und bestaetigt danach; ohne Speichern keine Bestaetigung', async () => {
  const play = { [PURCHASE_TOKEN]: purchase() };

  const stored = await run({ play }, GOOGLE_VERIFY);
  same([stored.status, stored.body], [200, { outcome: 'active', plan: snapshot('premium') }], 'Antwort');
  contains(stored.records[0], {
    p_user_id: USER_ID,
    p_platform: 'google',
    p_store_key: PURCHASE_TOKEN,
    p_product_id: 'eatova_premium',
    p_base_plan_id: 'yearly',
    p_status: 'active',
    p_expires_at: '2026-11-01T08:00:00.000Z',
    p_environment: 'production',
    p_acknowledged: false,
    p_event_at: null,
  }, 'gespeicherte Zeile');
  same(stored.ackAt.length, 1, 'genau eine Bestaetigung');
  check(stored.recordAt[0] < stored.ackAt[0], 'bestaetigt erst nach dem Speichern');
  same(
    stored.seen[stored.ackAt[0]].url,
    `${PLAY}/subscriptions/eatova_premium/tokens/${encodeURIComponent(PURCHASE_TOKEN)}:acknowledge`,
    'Bestaetigungs-URL',
  );
  // The stored row still holds Google's PENDING answer: the confirmed
  // acknowledgement is written to that row alone afterwards.
  same(stored.markAt.length, 1, 'eine Markierung');
  check(stored.ackAt[0] < stored.markAt[0], 'markiert erst nach der Bestaetigung');
  same(JSON.parse(stored.seen[stored.markAt[0]].body), { p_platform: 'google', p_store_key: PURCHASE_TOKEN }, 'markierte Zeile');

  const unacknowledged = await run({ play, ackStatus: 500 }, GOOGLE_VERIFY);
  same([unacknowledged.status, unacknowledged.body], [200, { outcome: 'active', plan: snapshot('premium') }], 'Bestaetigung scheitert');
  same(unacknowledged.markAt.length, 0, 'ohne Bestaetigung keine Markierung');

  const failed = await run({ play, recordStatus: 500 }, GOOGLE_VERIFY);
  same([failed.status, failed.body], [503, { error: 'store_unavailable' }], 'Schreibfehler');
  same(failed.ackAt.length, 0, 'ohne gespeicherte Zeile keine Bestaetigung');
});

// Apple keeps one originalTransactionId per Apple ID, so B's resubscribe or
// crossgrade arrives under the row bound to A. Signed by Apple with B's own
// token, the newer purchase moves it; a token-less one stays A's (409).
Deno.test('subscription-verify: Apple-Kauf mit eigenem Token uebernimmt die Bindung, ohne Token nicht', async () => {
  const world: World = { owner: OTHER_USER, ownerPurchasedAt: NOW - 30 * DAY };
  const own = await run(world, await appleVerify());
  same([own.status, own.body], [200, { outcome: 'active', plan: snapshot('premium') }], 'eigener Token');
  contains(own.records[0], { p_rebind: true, p_purchase_at: new Date(NOW - 60_000).toISOString() }, 'Rebind mit Kaufzeit');

  const tokenless = await run(world, await appleVerify({ appAccountToken: undefined }));
  same([tokenless.status, tokenless.body], [409, { error: 'purchase_owned_by_other_account' }], 'ohne Token');
  contains(tokenless.records[0], { p_rebind: false }, 'kein Rebind ohne Token');
});

Deno.test('subscription-verify: Apple-Sandboxkauf als sandbox gespeichert, Widerruf als revoked und inactive', async () => {
  const cases: { name: string; overrides: Json; outcome: string; tier: 'free' | 'premium'; status: string }[] = [
    { name: 'Sandboxkauf', overrides: {}, outcome: 'active', tier: 'premium', status: 'active' },
    {
      name: 'widerrufen',
      overrides: { revocationDate: NOW - HOUR },
      outcome: 'inactive',
      tier: 'free',
      status: 'revoked',
    },
  ];
  for (const { name, overrides, outcome, tier, status } of cases) {
    const result = await run({}, await appleVerify(overrides));
    same([result.status, result.body], [200, { outcome, plan: snapshot(tier) }], name);
    same(result.records.length, 1, `${name}: ein Schreibzugriff`);
    contains(result.records[0], {
      p_user_id: USER_ID,
      p_platform: 'apple',
      p_store_key: '2000000812345678',
      p_product_id: 'eatova_premium_yearly',
      p_status: status,
      p_expires_at: new Date(NOW + 7 * DAY).toISOString(),
      p_environment: 'sandbox',
      p_ownership: 'PURCHASED',
      p_auto_renewing: null,
      p_last_transaction_id: '2000000812345679',
      p_event_at: new Date(NOW - 1_000).toISOString(),
    }, `${name}: gespeicherte Zeile`);
    same(result.playLookups.length + result.ackAt.length, 0, `${name}: kein Google-Aufruf`);
  }
});

Deno.test('subscription-verify: refresh fragt nur faellige Google-Zeilen nach, hoechstens drei', async () => {
  const rows: StoredRow[] = [
    // Due, latest expiry first: these three are asked.
    { key: 'due-renewing', status: 'active', expires: NOW + 20 * HOUR, verified: NOW - 2 * HOUR },
    { key: 'due-lapsed', status: 'canceled', expires: NOW - 2 * HOUR, verified: NOW - DAY },
    { key: 'due-forgotten', status: 'on_hold', expires: NOW - 70 * DAY, verified: NOW - 40 * DAY },
    // Due as well, but the fourth.
    { key: 'due-fourth', status: 'active', expires: NOW - 100 * DAY, verified: NOW - 90 * DAY },
    // Not due.
    { key: 'just-verified', status: 'active', expires: NOW - HOUR, verified: NOW - 2 * 60_000 },
    { key: 'far-from-expiry', status: 'active', expires: NOW + 5 * DAY, verified: NOW - DAY },
    { key: 'final-expired', status: 'expired', expires: NOW - DAY, verified: NOW - DAY },
    { key: 'superseded', status: 'active', expires: NOW + HOUR, verified: NOW - DAY, superseded: 'due-renewing' },
    { key: 'other-account', user: OTHER_USER, status: 'active', expires: NOW + HOUR, verified: NOW - DAY },
    { key: 'apple-row', platform: 'apple', status: 'active', expires: NOW + HOUR, verified: NOW - DAY },
  ];
  const renewed = purchase({
    acknowledgementState: 'ACKNOWLEDGEMENT_STATE_ACKNOWLEDGED',
    lineItems: [{
      productId: 'eatova_premium',
      expiryTime: '2027-10-25T08:00:00.000Z',
      offerDetails: { basePlanId: 'yearly' },
    }],
  });
  const lapsed = purchase({
    subscriptionState: 'SUBSCRIPTION_STATE_EXPIRED',
    lineItems: [{ productId: 'eatova_premium', expiryTime: new Date(NOW - 2 * HOUR).toISOString() }],
  });
  const result = await run(
    { rows, play: { 'due-renewing': renewed, 'due-lapsed': lapsed, 'due-forgotten': 410 } },
    { action: 'refresh' },
  );
  same([result.status, result.body], [200, { outcome: 'active', plan: snapshot('premium') }], 'Antwort');
  same(result.playLookups.sort(), ['due-forgotten', 'due-lapsed', 'due-renewing'], 'bei Google nachgefragt');
  same(
    result.records.map((args) => [args.p_store_key, args.p_status, args.p_expires_at]).sort(),
    [
      // Google no longer knows it and it already ended: closed with its stored expiry.
      ['due-forgotten', 'expired', new Date(NOW - 70 * DAY).toISOString()],
      ['due-lapsed', 'expired', new Date(NOW - 2 * HOUR).toISOString()],
      ['due-renewing', 'active', '2027-10-25T08:00:00.000Z'],
    ],
    'gespeicherte Zeilen',
  );
  same(result.ackAt.length, 0, 'schon bestaetigt');
});
