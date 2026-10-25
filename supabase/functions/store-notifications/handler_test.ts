// Tests for the store webhook (handler.ts): Apple and Google notifications end
// to end against stubbed Supabase RPCs and Google endpoints, with a generated
// Apple chain whose root the handler factory pins. Frozen clock, no network;
// fetch, console and Deno.env are restored after every request.

import { clearGoogleAuthCaches, GOOGLE_OIDC_CERTS_URL, GOOGLE_TOKEN_URI } from '../_shared/google_auth.ts';
import { bytesToBase64Url } from '../_shared/jose.ts';
import {
  assert,
  assertEquals,
  buildAppleChain,
  generateChainKeys,
  pkcs8Pem,
  publicJwk,
  rsaKeyPair,
  signEs256Jws,
  signRs256Jwt,
  type StubCall,
  type TestChain,
  withFetchStub,
} from '../_shared/store_test_fixtures.ts';
import { createHandler } from './handler.ts';

const NOW = Date.parse('2026-10-25T08:00:00.000Z');
const NOW_S = NOW / 1000;
const SIGNED = NOW - 2_000;
const TX_EXPIRES = Date.parse('2027-10-24T08:00:00.000Z');
const GRACE_ENDS = Date.parse('2027-11-07T08:00:00.000Z');
const EVENT_MS = NOW - 5_000;
const SUPABASE = 'https://supabase.test.invalid';
const USER = '11111111-1111-4111-8111-111111111111';
const OTHER_USER = '33333333-3333-4333-8333-333333333333';
const ACCOUNT_TOKEN = '00000000-0000-4000-8000-0000000000a1';
const ORIGINAL_TX = '2000000812345678';
const NOTIFICATION_UUID = '0f1e2d3c-4b5a-4968-8776-655443322110';
const PURCHASE_TOKEN = 'kmopnbecjkeiochgdapbnlio.AO-J1OxV3mXbq_Ue0-test-token';
const MESSAGE_ID = '2070443601311540';
const AUDIENCE = 'https://eatova-test.supabase.co/functions/v1/store-notifications';
const PUSH_EMAIL = 'pubsub-push@eatova-test.iam.gserviceaccount.com';
const ACCESS_TOKEN = 'ya29.c.test-access-token';
const ANON = 'test-anon-key';
const PLAY_URL = 'https://androidpublisher.googleapis.com/androidpublisher/v3/applications/com.eatova.app/' +
  `purchases/subscriptionsv2/tokens/${encodeURIComponent(PURCHASE_TOKEN)}`;
const STORE_ENV = { SUPABASE_URL: SUPABASE, SUPABASE_SERVICE_ROLE_KEY: 'test-service-key', SUPABASE_ANON_KEY: ANON };
const ENV_KEYS = [
  ...Object.keys(STORE_ENV),
  'EATOVA_APPLE_BUNDLE_ID',
  'EATOVA_PLAY_PACKAGE_NAME',
  'EATOVA_PREMIUM_PRODUCT_IDS',
  'EATOVA_PUBSUB_PUSH_AUDIENCE',
  'EATOVA_PUBSUB_PUSH_SA_EMAIL',
  'EATOVA_PLAY_SERVICE_ACCOUNT_JSON',
];

// Built once: ECDSA signatures are randomized, so a rebuilt root has another hash.
let chains: Promise<{ own: TestChain; foreign: TestChain }> | undefined;
let rsaKeys: Promise<{ signer: CryptoKeyPair; other: CryptoKeyPair }> | undefined;
const buildChain = async () => buildAppleChain(await generateChainKeys());
const appleChains = () =>
  chains ??= Promise.all([buildChain(), buildChain()]).then(([own, foreign]) => ({ own, foreign }));
const rsa = () => rsaKeys ??= Promise.all([rsaKeyPair(), rsaKeyPair()]).then(([signer, other]) => ({ signer, other }));
const ownChain = async () => (await appleChains()).own;
const foreignChain = async () => (await appleChains()).foreign;

async function googleEnv(): Promise<Record<string, string>> {
  const { signer } = await rsa();
  return {
    ...STORE_ENV,
    EATOVA_PUBSUB_PUSH_AUDIENCE: AUDIENCE,
    EATOVA_PUBSUB_PUSH_SA_EMAIL: PUSH_EMAIL,
    EATOVA_PLAY_SERVICE_ACCOUNT_JSON: JSON.stringify({
      type: 'service_account',
      project_id: 'eatova-test',
      private_key_id: 'sa-key-1',
      private_key: await pkcs8Pem(signer.privateKey),
      client_email: 'play-verify@eatova-test.iam.gserviceaccount.com',
    }),
  };
}

// ---------------------------------------------------------------------------
// The stubbed backend: owner bindings, account tokens, receipts, Play state.

interface World {
  owners: Record<string, string>;
  tokens: Record<string, string>;
  receipts: Set<string>;
  gate: 'allow' | 'deny' | 'down';
  recordDown: boolean;
  play: () => Response;
}

function world(overrides: Partial<World> = {}): World {
  return {
    owners: {},
    tokens: {},
    receipts: new Set(),
    gate: 'allow',
    recordDown: false,
    play: () => Response.json(playPurchase()),
    ...overrides,
  };
}

function backend(state: World) {
  return async (call: StubCall): Promise<Response> => {
    const rpc = call.url.startsWith(`${SUPABASE}/rest/v1/rpc/`)
      ? call.url.slice(`${SUPABASE}/rest/v1/rpc/`.length)
      : '';
    const body = rpc ? JSON.parse(call.body) : {};
    if (rpc === 'consume_edge_rate_limits') {
      if (state.gate === 'down') return new Response('', { status: 503 });
      return Response.json(
        state.gate === 'deny'
          ? [{ allowed: false, limit: 600, remaining: 0, resetAt: new Date(NOW + 120_000).toISOString() }]
          : [{ allowed: true }],
      );
    }
    if (rpc === 'store_subscription_owner') {
      return Response.json(state.owners[`${body.p_platform}:${body.p_store_key}`] ?? null);
    }
    if (rpc === 'store_account_owner') return Response.json(state.tokens[body.p_token] ?? null);
    if (rpc === 'record_store_subscription') {
      if (state.recordDown) return new Response('', { status: 503 });
      return Response.json({ outcome: 'stored', tier: 'premium' });
    }
    if (rpc === 'record_store_notification') {
      const key = `${body.p_source}:${body.p_notification_id}`;
      const first = !state.receipts.has(key);
      state.receipts.add(key);
      return Response.json(first);
    }
    if (call.url === GOOGLE_OIDC_CERTS_URL) {
      const { signer } = await rsa();
      return Response.json({ keys: [await publicJwk(signer.publicKey, 'kid-1')] });
    }
    if (call.url === GOOGLE_TOKEN_URI) {
      return Response.json({ access_token: ACCESS_TOKEN, expires_in: 3599, token_type: 'Bearer' });
    }
    if (call.url === PLAY_URL) return state.play();
    throw new Error(`unerwarteter Abruf ${call.url}`);
  };
}

interface Sent {
  status: number;
  body: Record<string, unknown>;
  headers: Headers;
  calls: StubCall[];
  records: Record<string, unknown>[];
}

const SECRETS = [PURCHASE_TOKEN, ORIGINAL_TX, NOTIFICATION_UUID, MESSAGE_ID, USER, ACCOUNT_TOKEN, ACCESS_TOKEN];

/** One request against `state` with exactly `env` set; nothing secret may reach the log. */
async function send(
  request: Request | Promise<Request>,
  state: World,
  env: Record<string, string> = STORE_ENV,
): Promise<Sent> {
  const handler = createHandler({ appleRootSha256: (await ownChain()).rootSha256, now: () => NOW });
  const ready = await request;
  const previous = new Map(ENV_KEYS.map((key) => [key, Deno.env.get(key)]));
  for (const key of ENV_KEYS) Deno.env.delete(key);
  for (const [key, value] of Object.entries(env)) Deno.env.set(key, value);
  clearGoogleAuthCaches();
  let sent: Sent | undefined;
  try {
    await withFetchStub(backend(state), async (calls, logs) => {
      const response = await handler(ready);
      const text = await response.text();
      sent = {
        status: response.status,
        body: text ? JSON.parse(text) : {},
        headers: response.headers,
        calls,
        records: calls.filter((call) => call.url.endsWith('/rpc/record_store_subscription'))
          .map((call) => JSON.parse(call.body)),
      };
      const leaked = SECRETS.filter((secret) => logs.some((line) => line.includes(secret)));
      assertEquals(leaked, [], 'nichts Geheimes im Log');
      assert(!logs.some((line) => /eyJ[\w-]{20,}/.test(line)), 'kein JWS im Log');
    });
  } finally {
    clearGoogleAuthCaches();
    for (const [key, value] of previous) value === undefined ? Deno.env.delete(key) : Deno.env.set(key, value);
  }
  return sent!;
}

const touched = (sent: Sent, part: string) => sent.calls.some((call) => call.url.includes(part));

function post(body: unknown, headers: Record<string, string> = {}): Request {
  return new Request('https://edge.test.invalid/store-notifications', {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'cf-connecting-ip': '17.0.0.1', ...headers },
    body: typeof body === 'string' ? body : JSON.stringify(body),
  });
}

// ---------------------------------------------------------------------------
// Apple fixtures (App Store Server Notifications V2 shapes)

const TX: Record<string, unknown> = {
  transactionId: '2000000899999999',
  originalTransactionId: ORIGINAL_TX,
  bundleId: 'com.eatova.app',
  productId: 'eatova_premium_yearly',
  subscriptionGroupIdentifier: '21500000',
  type: 'Auto-Renewable Subscription',
  inAppOwnershipType: 'PURCHASED',
  environment: 'Production',
  appAccountToken: ACCOUNT_TOKEN,
  purchaseDate: NOW - 86_400_000,
  originalPurchaseDate: NOW - 86_400_000,
  expiresDate: TX_EXPIRES,
  transactionReason: 'PURCHASE',
  storefront: 'DEU',
  price: 49990,
  currency: 'EUR',
  signedDate: SIGNED,
};

const RENEWAL: Record<string, unknown> = {
  originalTransactionId: ORIGINAL_TX,
  productId: 'eatova_premium_yearly',
  autoRenewProductId: 'eatova_premium_yearly',
  autoRenewStatus: 1,
  environment: 'Production',
  renewalDate: TX_EXPIRES,
  signedDate: SIGNED,
};

interface AppleSpec {
  type: string;
  subtype?: string;
  data?: Record<string, unknown>;
  tx?: Record<string, unknown>;
  /** null: no signedRenewalInfo. */
  renewal?: Record<string, unknown> | null;
  /** Signs the outer payload; the nested JWS use `nestedChain`. */
  chain?: TestChain;
  nestedChain?: TestChain;
}

async function sign(chain: TestChain, payload: Record<string, unknown>): Promise<string> {
  return await signEs256Jws({ alg: 'ES256', x5c: chain.x5c }, payload, chain.leafKey);
}

async function apple(spec: AppleSpec): Promise<Request> {
  const own = await ownChain();
  const nested = spec.nestedChain ?? own;
  const renewal = spec.renewal === null ? {} : {
    signedRenewalInfo: await sign(nested, { ...RENEWAL, ...spec.renewal }),
  };
  const payload = {
    notificationType: spec.type,
    ...(spec.subtype ? { subtype: spec.subtype } : {}),
    notificationUUID: NOTIFICATION_UUID,
    version: '2.0',
    signedDate: SIGNED,
    data: {
      appAppleId: 6700000000,
      bundleId: 'com.eatova.app',
      bundleVersion: '42',
      environment: 'Production',
      status: 1,
      signedTransactionInfo: await sign(nested, { ...TX, ...spec.tx }),
      ...renewal,
      ...spec.data,
    },
  };
  return post({ signedPayload: await sign(spec.chain ?? own, payload) });
}

const APPLE_RECORD: Record<string, unknown> = {
  p_user_id: USER,
  p_platform: 'apple',
  p_store_key: ORIGINAL_TX,
  p_product_id: 'eatova_premium_yearly',
  p_base_plan_id: null,
  p_status: 'active',
  p_expires_at: new Date(TX_EXPIRES).toISOString(),
  p_auto_renewing: true,
  p_environment: 'production',
  p_ownership: 'PURCHASED',
  p_acknowledged: null,
  p_linked_store_key: null,
  p_last_transaction_id: '2000000899999999',
  p_event_at: new Date(SIGNED).toISOString(),
  p_rebind: false,
  p_purchase_at: new Date(NOW - 86_400_000).toISOString(),
};

const appleBound = () => world({ owners: { [`apple:${ORIGINAL_TX}`]: USER } });

Deno.test('store-notifications: each Apple notification type is stored with the state it reports', async () => {
  const cases: { was: string; spec: AppleSpec; record: Record<string, unknown> }[] = [
    { was: 'SUBSCRIBED', spec: { type: 'SUBSCRIBED', subtype: 'INITIAL_BUY' }, record: {} },
    { was: 'DID_RENEW', spec: { type: 'DID_RENEW' }, record: {} },
    {
      was: 'Auto-Renew aus',
      spec: { type: 'DID_CHANGE_RENEWAL_STATUS', subtype: 'AUTO_RENEW_DISABLED', renewal: { autoRenewStatus: 0 } },
      record: { p_status: 'canceled', p_auto_renewing: false },
    },
    {
      was: 'Auto-Renew aus waehrend der Nachfrist',
      spec: {
        type: 'DID_CHANGE_RENEWAL_STATUS',
        subtype: 'AUTO_RENEW_DISABLED',
        data: { status: 4 },
        renewal: { autoRenewStatus: 0, gracePeriodExpiresDate: GRACE_ENDS },
      },
      record: { p_status: 'grace', p_auto_renewing: false, p_expires_at: new Date(GRACE_ENDS).toISOString() },
    },
    {
      was: 'Nachfrist',
      spec: {
        type: 'DID_FAIL_TO_RENEW',
        subtype: 'GRACE_PERIOD',
        data: { status: 4 },
        renewal: { gracePeriodExpiresDate: GRACE_ENDS },
      },
      record: { p_status: 'grace', p_expires_at: new Date(GRACE_ENDS).toISOString() },
    },
    {
      was: 'Zahlung fehlgeschlagen',
      spec: { type: 'DID_FAIL_TO_RENEW', data: { status: 3 } },
      record: { p_status: 'on_hold' },
    },
    { was: 'Nachfrist vorbei', spec: { type: 'GRACE_PERIOD_EXPIRED' }, record: { p_status: 'on_hold' } },
    {
      was: 'abgelaufen',
      spec: { type: 'EXPIRED', subtype: 'VOLUNTARY', data: { status: 2 }, renewal: { autoRenewStatus: 0 } },
      record: { p_status: 'expired', p_auto_renewing: false },
    },
    {
      was: 'erstattet',
      spec: { type: 'REFUND', tx: { revocationDate: NOW - 60_000, revocationReason: 0 } },
      record: { p_status: 'revoked' },
    },
    { was: 'REVOKE', spec: { type: 'REVOKE' }, record: { p_status: 'revoked' } },
    { was: 'Erstattung zurueckgenommen', spec: { type: 'REFUND_REVERSED' }, record: {} },
    {
      was: 'Sandbox ohne Renewal-Info',
      spec: {
        type: 'SUBSCRIBED',
        subtype: 'RESUBSCRIBE',
        data: { environment: 'Sandbox' },
        tx: { environment: 'Sandbox' },
        renewal: null,
      },
      record: { p_environment: 'sandbox', p_auto_renewing: null },
    },
  ];
  for (const row of cases) {
    const state = appleBound();
    const sent = await send(apple(row.spec), state);
    assertEquals([sent.status, sent.body], [200, { outcome: 'processed' }], row.was);
    assertEquals(sent.records, [{ ...APPLE_RECORD, ...row.record }], `${row.was}: gespeichert`);
    assertEquals([...state.receipts], [`apple:${NOTIFICATION_UUID}`], `${row.was}: Quittung`);
  }
});

Deno.test('store-notifications: Apple owners, duplicates, test and foreign purchases', async () => {
  const subscribed: AppleSpec = { type: 'SUBSCRIBED', subtype: 'INITIAL_BUY' };
  // `rebind`: the account came from the token; record_store_subscription
  // moves a row bound to another account only for a newer purchase.
  const cases: { was: string; spec: AppleSpec; state: World; outcome: string; user?: string; rebind?: true }[] = [
    {
      was: 'Konto aus dem appAccountToken',
      spec: subscribed,
      state: world({ tokens: { [ACCOUNT_TOKEN]: USER } }),
      outcome: 'processed',
      user: USER,
      rebind: true,
    },
    {
      // One originalTransactionId per Apple ID: the newest purchase's token decides.
      was: 'der Token schlaegt die gespeicherte Bindung',
      spec: subscribed,
      state: world({ owners: { [`apple:${ORIGINAL_TX}`]: OTHER_USER }, tokens: { [ACCOUNT_TOKEN]: USER } }),
      outcome: 'processed',
      user: USER,
      rebind: true,
    },
    { was: 'unbekanntes Konto', spec: subscribed, state: world(), outcome: 'unknown_owner' },
    {
      was: 'Duplikat',
      spec: subscribed,
      state: world({ owners: { [`apple:${ORIGINAL_TX}`]: USER }, receipts: new Set([`apple:${NOTIFICATION_UUID}`]) }),
      outcome: 'duplicate',
      user: USER,
    },
    {
      was: 'TEST',
      spec: { type: 'TEST', data: { signedTransactionInfo: undefined, signedRenewalInfo: undefined } },
      state: appleBound(),
      outcome: 'test',
    },
    {
      was: 'nicht abgebildeter Typ',
      spec: { type: 'DID_CHANGE_RENEWAL_PREF', subtype: 'UPGRADE' },
      state: appleBound(),
      outcome: 'ignored',
    },
    {
      was: 'fremdes Produkt',
      spec: { type: 'DID_RENEW', tx: { productId: 'eatova_coins' } },
      state: appleBound(),
      outcome: 'ignored',
    },
    {
      was: 'Familienfreigabe',
      spec: { type: 'DID_RENEW', tx: { inAppOwnershipType: 'FAMILY_SHARED' } },
      state: appleBound(),
      outcome: 'ignored',
    },
  ];
  for (const row of cases) {
    const sent = await send(apple(row.spec), row.state);
    assertEquals([sent.status, sent.body], [200, { outcome: row.outcome }], row.was);
    assertEquals(
      sent.records.map((record) => [record.p_user_id, record.p_rebind]),
      row.user ? [[row.user, row.rebind ?? false]] : [],
      `${row.was}: Konto`,
    );
    assertEquals(touched(sent, 'record_store_notification'), row.outcome !== 'test', `${row.was}: Quittung`);
  }
});

Deno.test('store-notifications: forged or foreign Apple notifications are refused before any write', async () => {
  const foreign = await foreignChain();
  const own = await ownChain();
  const tampered = async () => {
    const request = await apple({ type: 'DID_RENEW' });
    const { signedPayload } = await request.json();
    const [header, , signature] = signedPayload.split('.');
    const payload = btoa(JSON.stringify({ notificationType: 'DID_RENEW', notificationUUID: NOTIFICATION_UUID }))
      .replace(/=+$/, '').replace(/\+/g, '-').replace(/\//g, '_');
    return post({ signedPayload: `${header}.${payload}.${signature}` });
  };
  const cases: { was: string; request: Promise<Request>; status: number; error: string }[] = [
    {
      was: 'fremde Root',
      request: apple({ type: 'DID_RENEW', chain: foreign }),
      status: 401,
      error: 'invalid_notification_auth',
    },
    { was: 'veraenderter Payload', request: tampered(), status: 401, error: 'invalid_notification_auth' },
    {
      was: 'Transaktion fremd signiert',
      request: apple({ type: 'DID_RENEW', nestedChain: foreign }),
      status: 401,
      error: 'invalid_notification_auth',
    },
    {
      was: 'signedPayload kein JWS',
      request: Promise.resolve(post({ signedPayload: 'not-a-jws' })),
      status: 401,
      error: 'invalid_notification_auth',
    },
    {
      was: 'fremdes Bundle',
      request: apple({ type: 'DID_RENEW', data: { bundleId: 'com.example.other' } }),
      status: 400,
      error: 'invalid_notification',
    },
    {
      was: 'Transaktion fremdes Bundle',
      request: apple({ type: 'DID_RENEW', tx: { bundleId: 'com.example.other' } }),
      status: 400,
      error: 'invalid_notification',
    },
    {
      was: 'TEST fremdes Bundle',
      request: apple({ type: 'TEST', data: { bundleId: 'com.example.other' } }),
      status: 400,
      error: 'invalid_notification',
    },
    {
      was: 'ohne Transaktion',
      request: apple({ type: 'DID_RENEW', data: { signedTransactionInfo: undefined } }),
      status: 400,
      error: 'invalid_notification',
    },
    {
      was: 'Renewal anderer Kauf',
      request: apple({ type: 'DID_RENEW', renewal: { originalTransactionId: '2000000000000001' } }),
      status: 400,
      error: 'invalid_notification',
    },
    {
      was: 'Umgebung Xcode',
      request: apple({ type: 'DID_RENEW', data: { environment: 'Xcode' } }),
      status: 400,
      error: 'invalid_notification',
    },
  ];
  assert(own.rootSha256 !== foreign.rootSha256, 'zwei verschiedene Roots');
  for (const row of cases) {
    const sent = await send(row.request, appleBound());
    assertEquals([sent.status, sent.body], [row.status, { error: row.error }], row.was);
    assertEquals(
      sent.calls.map((call) => call.url),
      [`${SUPABASE}/rest/v1/rpc/consume_edge_rate_limits`],
      `${row.was}: nur das Tor`,
    );
  }
});

// ---------------------------------------------------------------------------
// Google fixtures (Pub/Sub push of a DeveloperNotification)

function playPurchase(
  overrides: Record<string, unknown> = {},
  item: Record<string, unknown> = {},
): Record<string, unknown> {
  return {
    kind: 'androidpublisher#subscriptionPurchaseV2',
    regionCode: 'DE',
    startTime: '2026-10-20T08:00:00.000Z',
    subscriptionState: 'SUBSCRIPTION_STATE_ACTIVE',
    latestOrderId: 'GPA.3375-4417-2275-01234',
    acknowledgementState: 'ACKNOWLEDGEMENT_STATE_ACKNOWLEDGED',
    externalAccountIdentifiers: { obfuscatedExternalAccountId: ACCOUNT_TOKEN },
    lineItems: [{
      productId: 'eatova_premium',
      expiryTime: '2027-10-20T08:00:00.000Z',
      autoRenewingPlan: { autoRenewEnabled: true },
      offerDetails: { basePlanId: 'yearly' },
      latestSuccessfulOrderId: 'GPA.3375-4417-2275-01234',
      ...item,
    }],
    ...overrides,
  };
}

function rtdn(extra: Record<string, unknown>, overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return { version: '1.0', packageName: 'com.eatova.app', eventTimeMillis: String(EVENT_MS), ...extra, ...overrides };
}

const subscriptionEvent = (notificationType: number) =>
  rtdn({ subscriptionNotification: { version: '1.0', notificationType, purchaseToken: PURCHASE_TOKEN } });

async function oidcToken(claims: Record<string, unknown> = {}, key?: CryptoKey): Promise<string> {
  const { signer } = await rsa();
  return await signRs256Jwt({ alg: 'RS256', kid: 'kid-1', typ: 'JWT' }, {
    aud: AUDIENCE,
    azp: '102938475610293847561',
    email: PUSH_EMAIL,
    email_verified: true,
    exp: NOW_S + 3000,
    iat: NOW_S - 60,
    iss: 'https://accounts.google.com',
    sub: '102938475610293847561',
    ...claims,
  }, key ?? signer.privateKey);
}

async function google(
  notification: Record<string, unknown>,
  options: { token?: string | null; message?: Record<string, unknown> } = {},
): Promise<Request> {
  const token = options.token === undefined ? await oidcToken() : options.token;
  return post({
    message: {
      attributes: {},
      data: btoa(JSON.stringify(notification)),
      messageId: MESSAGE_ID,
      message_id: MESSAGE_ID,
      publishTime: '2026-10-25T07:59:55.000Z',
      ...options.message,
    },
    subscription: 'projects/eatova-test/subscriptions/play-rtdn',
  }, token === null ? {} : { authorization: `Bearer ${token}` });
}

const GOOGLE_RECORD: Record<string, unknown> = {
  p_user_id: USER,
  p_platform: 'google',
  p_store_key: PURCHASE_TOKEN,
  p_product_id: 'eatova_premium',
  p_base_plan_id: 'yearly',
  p_status: 'active',
  p_expires_at: '2027-10-20T08:00:00.000Z',
  p_auto_renewing: true,
  p_environment: 'production',
  p_ownership: null,
  p_acknowledged: true,
  p_linked_store_key: null,
  p_last_transaction_id: 'GPA.3375-4417-2275-01234',
  p_event_at: new Date(EVENT_MS).toISOString(),
  p_rebind: false,
  p_purchase_at: null,
};

const googleBound = (play: () => Response = () => Response.json(playPurchase())) =>
  world({ tokens: { [ACCOUNT_TOKEN]: USER }, play });

Deno.test('store-notifications: a Google notification stores the state Play reports, a voided one revokes', async () => {
  const env = await googleEnv();
  const cases: {
    was: string;
    event: Record<string, unknown>;
    purchase: Record<string, unknown>;
    record: Record<string, unknown>;
  }[] = [
    { was: 'SUBSCRIPTION_PURCHASED', event: subscriptionEvent(4), purchase: playPurchase(), record: {} },
    {
      was: 'SUBSCRIPTION_CANCELED',
      event: subscriptionEvent(3),
      purchase: playPurchase({ subscriptionState: 'SUBSCRIPTION_STATE_CANCELED' }, { autoRenewingPlan: {} }),
      record: { p_status: 'canceled', p_auto_renewing: false },
    },
    {
      was: 'SUBSCRIPTION_IN_GRACE_PERIOD',
      event: subscriptionEvent(6),
      purchase: playPurchase({ subscriptionState: 'SUBSCRIPTION_STATE_IN_GRACE_PERIOD' }),
      record: { p_status: 'grace' },
    },
    {
      was: 'SUBSCRIPTION_ON_HOLD',
      event: subscriptionEvent(5),
      purchase: playPurchase({ subscriptionState: 'SUBSCRIPTION_STATE_ON_HOLD' }),
      record: { p_status: 'on_hold' },
    },
    {
      was: 'SUBSCRIPTION_EXPIRED',
      event: subscriptionEvent(13),
      purchase: playPurchase({ subscriptionState: 'SUBSCRIPTION_STATE_EXPIRED' }, { autoRenewingPlan: {} }),
      record: { p_status: 'expired', p_auto_renewing: false },
    },
    {
      was: 'Planwechsel mit Testkauf',
      event: subscriptionEvent(4),
      purchase: playPurchase({ testPurchase: {}, linkedPurchaseToken: 'older-purchase-token.AO-J1Ox' }),
      record: { p_environment: 'test', p_linked_store_key: 'older-purchase-token.AO-J1Ox' },
    },
    {
      was: 'Erstattung (voided)',
      event: rtdn({
        voidedPurchaseNotification: {
          purchaseToken: PURCHASE_TOKEN,
          orderId: 'GPA.3375-4417-2275-01234',
          productType: 1,
          refundType: 1,
        },
      }),
      purchase: playPurchase({ subscriptionState: 'SUBSCRIPTION_STATE_EXPIRED' }, { autoRenewingPlan: {} }),
      record: { p_status: 'revoked', p_auto_renewing: false },
    },
  ];
  for (const row of cases) {
    const state = googleBound(() => Response.json(row.purchase));
    const sent = await send(google(row.event), state, env);
    assertEquals([sent.status, sent.body], [200, { outcome: 'processed' }], row.was);
    assertEquals(sent.records, [{ ...GOOGLE_RECORD, ...row.record }], `${row.was}: gespeichert`);
    assertEquals([...state.receipts], [`google:${MESSAGE_ID}`], `${row.was}: Quittung`);
    const play = sent.calls.find((call) => call.url === PLAY_URL);
    assertEquals(
      [play?.headers.get('authorization'), play?.redirect],
      [`Bearer ${ACCESS_TOKEN}`, 'error'],
      `${row.was}: Play`,
    );
  }
});

Deno.test('store-notifications: Google owners, duplicates, tests and purchases Play does not confirm', async () => {
  const env = await googleEnv();
  const cases: {
    was: string;
    event: Record<string, unknown>;
    state: World;
    outcome: string;
    user?: string;
    play: boolean;
  }[] = [
    {
      was: 'gespeicherte Bindung schlaegt den Token',
      event: subscriptionEvent(2),
      state: world({ owners: { [`google:${PURCHASE_TOKEN}`]: OTHER_USER }, tokens: { [ACCOUNT_TOKEN]: USER } }),
      outcome: 'processed',
      user: OTHER_USER,
      play: true,
    },
    { was: 'unbekanntes Konto', event: subscriptionEvent(4), state: world(), outcome: 'unknown_owner', play: true },
    {
      was: 'Duplikat',
      event: subscriptionEvent(2),
      state: world({ tokens: { [ACCOUNT_TOKEN]: USER }, receipts: new Set([`google:${MESSAGE_ID}`]) }),
      outcome: 'duplicate',
      user: USER,
      play: true,
    },
    {
      was: 'testNotification',
      event: rtdn({ testNotification: { version: '1.0' } }),
      state: googleBound(),
      outcome: 'test',
      play: false,
    },
    {
      was: 'Einmalkauf erstattet',
      event: rtdn({ voidedPurchaseNotification: { purchaseToken: PURCHASE_TOKEN, orderId: 'GPA.1', productType: 2 } }),
      state: googleBound(),
      outcome: 'ignored',
      play: false,
    },
    {
      was: 'Play kennt den Kauf nicht',
      event: subscriptionEvent(4),
      state: googleBound(() => new Response('', { status: 410 })),
      outcome: 'ignored',
      play: true,
    },
    {
      was: 'fremdes Produkt',
      event: subscriptionEvent(4),
      state: googleBound(() => Response.json(playPurchase({}, { productId: 'eatova_coins' }))),
      outcome: 'ignored',
      play: true,
    },
    {
      was: 'Zahlung ausstehend',
      event: subscriptionEvent(4),
      state: googleBound(() => Response.json(playPurchase({ subscriptionState: 'SUBSCRIPTION_STATE_PENDING' }))),
      outcome: 'ignored',
      play: true,
    },
  ];
  for (const row of cases) {
    const sent = await send(google(row.event), row.state, env);
    assertEquals([sent.status, sent.body], [200, { outcome: row.outcome }], row.was);
    assertEquals(sent.records.map((record) => record.p_user_id), row.user ? [row.user] : [], `${row.was}: Konto`);
    assertEquals(touched(sent, 'androidpublisher'), row.play, `${row.was}: Play gefragt`);
  }
});

Deno.test('store-notifications: a delivery that failed with 503 leaves no receipt, so the retry is applied', async () => {
  const env = await googleEnv();
  const cases: { was: string; state: World; request: () => Promise<Request>; heal: (state: World) => void }[] = [
    {
      was: 'Apple, Schreiben gescheitert',
      state: { ...appleBound(), recordDown: true },
      request: () => apple({ type: 'SUBSCRIBED', subtype: 'INITIAL_BUY' }),
      heal: (state) => state.recordDown = false,
    },
    {
      was: 'Google, Play nicht erreichbar',
      state: googleBound(() => new Response('', { status: 503 })),
      request: () => google(subscriptionEvent(2)),
      heal: (state) => state.play = () => Response.json(playPurchase()),
    },
  ];
  for (const row of cases) {
    const failed = await send(row.request(), row.state, env);
    assertEquals([failed.status, failed.body], [503, { error: 'store_unavailable' }], row.was);
    assertEquals(row.state.receipts.size, 0, `${row.was}: keine Quittung`);
    row.heal(row.state);
    const retried = await send(row.request(), row.state, env);
    assertEquals([retried.body, retried.records.length], [{ outcome: 'processed' }, 1], `${row.was}: angewendet`);
  }
});

Deno.test('store-notifications: Google pushes with a wrong token or a foreign package are refused before Play', async () => {
  const env = await googleEnv();
  const { other } = await rsa();
  // Built here: a JWT-shaped literal would trip the secret scan.
  const segment = (value: unknown) => bytesToBase64Url(new TextEncoder().encode(JSON.stringify(value)));
  const supabaseJwt = `${segment({ alg: 'HS256', typ: 'JWT' })}.${segment({ role: 'anon' })}.${segment('sig')}`;
  const cases: { was: string; request: Promise<Request>; status: number; error: string }[] = [
    {
      was: 'falsche Audience',
      request: google(subscriptionEvent(4), {
        token: await oidcToken({ aud: 'https://evil.example/functions/v1/store-notifications' }),
      }),
      status: 401,
      error: 'invalid_notification_auth',
    },
    {
      was: 'falsches Push-Konto',
      request: google(subscriptionEvent(4), {
        token: await oidcToken({ email: 'attacker@example.iam.gserviceaccount.com' }),
      }),
      status: 401,
      error: 'invalid_notification_auth',
    },
    {
      was: 'abgelaufen',
      request: google(subscriptionEvent(4), { token: await oidcToken({ exp: NOW_S - 120 }) }),
      status: 401,
      error: 'invalid_notification_auth',
    },
    {
      was: 'fremder Schluessel',
      request: google(subscriptionEvent(4), { token: await oidcToken({}, other.privateKey) }),
      status: 401,
      error: 'invalid_notification_auth',
    },
    {
      was: 'ohne Token',
      request: google(subscriptionEvent(4), { token: null }),
      status: 401,
      error: 'invalid_notification_auth',
    },
    {
      was: 'Anon-Key',
      request: google(subscriptionEvent(4), { token: ANON }),
      status: 401,
      error: 'invalid_notification_auth',
    },
    {
      was: 'Supabase-JWT',
      request: google(subscriptionEvent(4), { token: supabaseJwt }),
      status: 401,
      error: 'invalid_notification_auth',
    },
    {
      was: 'fremdes Paket',
      request: google(subscriptionEvent(4), {
        message: {
          data: btoa(
            JSON.stringify(
              rtdn({ subscriptionNotification: { notificationType: 4, purchaseToken: PURCHASE_TOKEN } }, {
                packageName: 'com.example.other',
              }),
            ),
          ),
        },
      }),
      status: 400,
      error: 'invalid_notification',
    },
    {
      was: 'data kein base64',
      request: google(subscriptionEvent(4), { message: { data: '%%%' } }),
      status: 400,
      error: 'invalid_notification',
    },
    {
      was: 'ohne messageId',
      request: google(subscriptionEvent(4), { message: { messageId: undefined, message_id: undefined } }),
      status: 400,
      error: 'invalid_notification',
    },
    {
      was: 'ohne Ereigniszeit',
      request: google(
        rtdn({ subscriptionNotification: { notificationType: 4, purchaseToken: PURCHASE_TOKEN } }, {
          eventTimeMillis: 'soon',
        }),
      ),
      status: 400,
      error: 'invalid_notification',
    },
  ];
  for (const row of cases) {
    const sent = await send(row.request, googleBound(), env);
    assertEquals([sent.status, sent.body], [row.status, { error: row.error }], row.was);
    assert(!touched(sent, 'androidpublisher') && sent.records.length === 0, `${row.was}: weder Play noch Schreiben`);
    assert(!touched(sent, 'record_store_notification'), `${row.was}: keine Quittung`);
  }
});

Deno.test('store-notifications: the boot probe gets the handler 401, also without the Google secrets', async () => {
  // deploy_functions.py PROBES: POST {} without a token and with the anon key.
  for (const env of [STORE_ENV, await googleEnv()]) {
    for (const headers of [{}, { authorization: `Bearer ${ANON}`, apikey: ANON }] as Record<string, string>[]) {
      const sent = await send(post({}, headers), world(), env);
      assertEquals([sent.status, sent.body], [401, { error: 'invalid_notification_auth' }], 'Probe');
    }
  }
  // A real push without the Google secrets: 503, so Pub/Sub retries once they are set.
  const sent = await send(google(subscriptionEvent(4)), googleBound());
  assertEquals([sent.status, sent.body], [503, { error: 'not_configured' }], 'Google ohne Secrets');
  assert(!touched(sent, 'googleapis'), 'kein Google-Abruf ohne Secrets');
});

Deno.test('store-notifications: methods, configuration, IP gate and body limits come before any verification', async () => {
  const preflight = await send(
    new Request('https://edge.test.invalid/store-notifications', {
      method: 'OPTIONS',
      headers: { origin: 'https://app.test.invalid' },
    }),
    world(),
  );
  assertEquals(
    [preflight.status, preflight.headers.get('access-control-allow-origin')],
    [204, null],
    'Preflight ohne Origin',
  );
  const get = await send(new Request('https://edge.test.invalid/store-notifications'), world());
  assertEquals([get.status, get.body], [405, { error: 'method_not_allowed' }], 'GET');

  const unconfigured = await send(apple({ type: 'DID_RENEW' }), appleBound(), { SUPABASE_URL: SUPABASE });
  assertEquals([unconfigured.status, unconfigured.body, unconfigured.calls.length], [
    503,
    { error: 'not_configured' },
    0,
  ], 'ohne Service-Key');

  const denied = await send(apple({ type: 'DID_RENEW' }), world({ ...appleBound(), gate: 'deny' }));
  assertEquals(
    [denied.status, denied.body, denied.headers.get('retry-after')],
    [429, { error: 'rate_limited' }, '120'],
    'IP-Tor',
  );
  assertEquals(denied.calls.length, 1, 'nur das Tor');
  assertEquals(JSON.parse(denied.calls[0].body).p_gates, [{
    scope: 'store-notifications:ip',
    subject: 'ip:17.0.0.1',
    limit: 600,
    window_seconds: 600,
  }], 'Tor anonym nach IP');
  const down = await send(apple({ type: 'DID_RENEW' }), world({ gate: 'down' }));
  assertEquals([down.status, down.body], [503, { error: 'rate_limit_unavailable' }], 'Tor nicht erreichbar');

  for (
    const [was, body] of [['zu gross', JSON.stringify({ signedPayload: 'a'.repeat(256 * 1024) })], [
      'kein JSON',
      '{"signedPayload":',
    ], ['Liste', '[]']]
  ) {
    const sent = await send(post(body), world());
    assertEquals([sent.status, sent.body], [400, { error: 'invalid_notification' }], was);
  }
});
