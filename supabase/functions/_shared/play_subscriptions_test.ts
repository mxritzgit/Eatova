// Tests for play_subscriptions.ts: the subscriptionsv2.get and acknowledge
// wire, their typed outcomes, and the mapping of SubscriptionPurchaseV2
// bodies (shapes from the androidpublisher v3 reference) to stored rows.
// Stubbed fetch, no network.

import {
  acknowledgeSubscription,
  getSubscriptionV2,
  mapPlayPurchase,
  type PlayMapOptions,
} from './play_subscriptions.ts';
import { assert, assertEquals, withFetchStub } from './store_test_fixtures.ts';

const PACKAGE = 'com.eatova.app';
const TOKEN = 'kmopnbecjkeiochgdapbnlio.AO-J1OxV3mXbq_Ue0-test-token';
const ACCESS = 'ya29.c.test-access-token';
const ACCOUNT = '00000000-0000-4000-8000-0000000000a1';
const BASE = 'https://androidpublisher.googleapis.com/androidpublisher/v3/applications/com.eatova.app/purchases';
const OPTIONS: PlayMapOptions = {
  productAllowlist: new Set(['eatova_premium', 'eatova_premium_monthly', 'eatova_premium_yearly']),
  accountToken: ACCOUNT,
};

/** A yearly purchase in its free trial, fresh from the app, not yet acknowledged. */
function yearlyTrial(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    kind: 'androidpublisher#subscriptionPurchaseV2',
    regionCode: 'DE',
    startTime: '2026-10-25T08:00:00.512Z',
    subscriptionState: 'SUBSCRIPTION_STATE_ACTIVE',
    acknowledgementState: 'ACKNOWLEDGEMENT_STATE_PENDING',
    externalAccountIdentifiers: { obfuscatedExternalAccountId: ACCOUNT },
    lineItems: [{
      productId: 'eatova_premium',
      expiryTime: '2026-11-01T08:00:00.512Z',
      autoRenewingPlan: {
        autoRenewEnabled: true,
        recurringPrice: { currencyCode: 'EUR', units: '49', nanos: 990000000 },
      },
      offerDetails: { basePlanId: 'yearly', offerId: 'yearly-trial-7d', offerTags: ['trial'] },
      latestSuccessfulOrderId: 'GPA.3375-4417-2275-01234',
    }],
    ...overrides,
  };
}

const request = () => ({ accessToken: ACCESS, signal: AbortSignal.timeout(5_000) });

Deno.test('play_subscriptions: subscriptionsv2.get sends the bearer without redirects and types every answer', async () => {
  await withFetchStub(() => Response.json(yearlyTrial()), async (calls) => {
    const outcome = await getSubscriptionV2(PACKAGE, TOKEN, request());
    assert(outcome.kind === 'ok', `ok erwartet, war ${outcome.kind}`);
    assertEquals(outcome.purchase, yearlyTrial(), 'Kauf');
    const call = calls[0];
    assertEquals(call.url, `${BASE}/subscriptionsv2/tokens/${encodeURIComponent(TOKEN)}`, 'URL');
    assertEquals(
      [call.method, call.redirect, call.headers.get('authorization')],
      ['GET', 'error', `Bearer ${ACCESS}`],
      'Anfrage',
    );
  });
  const cases: { was: string; reply: () => Response; expected: unknown }[] = [
    {
      was: '404',
      reply: () => Response.json({ error: { code: 404 } }, { status: 404 }),
      expected: { kind: 'not_found' },
    },
    {
      was: '410',
      reply: () => Response.json({ error: { code: 410 } }, { status: 410 }),
      expected: { kind: 'not_found' },
    },
    { was: '500', reply: () => new Response('', { status: 500 }), expected: { kind: 'unavailable', status: 500 } },
    { was: '503', reply: () => new Response('', { status: 503 }), expected: { kind: 'unavailable', status: 503 } },
    { was: '401', reply: () => new Response('', { status: 401 }), expected: { kind: 'unavailable', status: 401 } },
    { was: 'Liste statt Objekt', reply: () => Response.json([]), expected: { kind: 'unavailable', status: 200 } },
    {
      was: 'uebergross',
      reply: () => new Response(`{"x":"${'a'.repeat(70_000)}"}`),
      expected: { kind: 'unavailable', status: 200 },
    },
    {
      was: 'Zeitlimit',
      reply: () => {
        throw new DOMException('timed out', 'TimeoutError');
      },
      expected: { kind: 'unavailable', status: null },
    },
  ];
  for (const row of cases) {
    await withFetchStub(row.reply, async () => {
      assertEquals(await getSubscriptionV2(PACKAGE, TOKEN, request()), row.expected, row.was);
    });
  }
});

Deno.test('play_subscriptions: acknowledge posts to the v1 endpoint of the product', async () => {
  await withFetchStub(() => new Response(null, { status: 200 }), async (calls) => {
    assertEquals(await acknowledgeSubscription(PACKAGE, 'eatova_premium', TOKEN, request()), { kind: 'ok' }, 'ok');
    const call = calls[0];
    assertEquals(
      call.url,
      `${BASE}/subscriptions/eatova_premium/tokens/${encodeURIComponent(TOKEN)}:acknowledge`,
      'URL',
    );
    assertEquals(
      [call.method, call.redirect, call.headers.get('authorization')],
      ['POST', 'error', `Bearer ${ACCESS}`],
      'Anfrage',
    );
  });
  for (
    const [status, expected] of [[404, { kind: 'not_found' }], [410, { kind: 'not_found' }], [502, {
      kind: 'unavailable',
      status: 502,
    }]] as const
  ) {
    await withFetchStub(() => new Response('', { status }), async () => {
      assertEquals(
        await acknowledgeSubscription(PACKAGE, 'eatova_premium', TOKEN, request()),
        expected,
        `HTTP ${status}`,
      );
    });
  }
});

Deno.test('play_subscriptions: a yearly trial maps to the row record_store_subscription stores', () => {
  assertEquals(mapPlayPurchase(yearlyTrial(), OPTIONS), {
    ok: true,
    row: {
      platform: 'google',
      productId: 'eatova_premium',
      basePlanId: 'yearly',
      status: 'active',
      expiresAt: '2026-11-01T08:00:00.512Z',
      expiresAtMs: Date.parse('2026-11-01T08:00:00.512Z'),
      autoRenewing: true,
      environment: 'production',
      ownership: null,
      acknowledged: false,
      needsAcknowledge: true,
      linkedStoreKey: null,
      lastTransactionId: 'GPA.3375-4417-2275-01234',
      obfuscatedAccountId: ACCOUNT,
    },
  }, 'Zeile');
});

Deno.test('play_subscriptions: states, plan changes and bindings map or reject as the contract says', () => {
  const item = (yearlyTrial().lineItems as Record<string, unknown>[])[0];
  type Row = Record<string, unknown>;
  const cases: { was: string; purchase: Row; options?: PlayMapOptions; expected: Row }[] = [
    {
      was: 'IN_GRACE_PERIOD',
      purchase: yearlyTrial({ subscriptionState: 'SUBSCRIPTION_STATE_IN_GRACE_PERIOD' }),
      expected: { status: 'grace', needsAcknowledge: true },
    },
    {
      was: 'CANCELED, Verlaengerung aus (false fehlt im JSON)',
      purchase: yearlyTrial({
        subscriptionState: 'SUBSCRIPTION_STATE_CANCELED',
        acknowledgementState: 'ACKNOWLEDGEMENT_STATE_ACKNOWLEDGED',
        canceledStateContext: { userInitiatedCancellation: { cancelTime: '2026-10-26T09:00:00Z' } },
        lineItems: [{ ...item, autoRenewingPlan: {} }],
      }),
      expected: { status: 'canceled', autoRenewing: false, acknowledged: true, needsAcknowledge: false },
    },
    {
      was: 'ON_HOLD',
      purchase: yearlyTrial({ subscriptionState: 'SUBSCRIPTION_STATE_ON_HOLD' }),
      expected: { status: 'on_hold', needsAcknowledge: false },
    },
    {
      was: 'PAUSED',
      purchase: yearlyTrial({ subscriptionState: 'SUBSCRIPTION_STATE_PAUSED' }),
      expected: { status: 'paused' },
    },
    {
      was: 'EXPIRED',
      purchase: yearlyTrial({ subscriptionState: 'SUBSCRIPTION_STATE_EXPIRED' }),
      expected: { status: 'expired' },
    },
    {
      was: 'PENDING_PURCHASE_CANCELED ohne Laufzeit',
      purchase: yearlyTrial({
        subscriptionState: 'SUBSCRIPTION_STATE_PENDING_PURCHASE_CANCELED',
        lineItems: [{ productId: 'eatova_premium' }],
      }),
      expected: { status: 'expired', expiresAt: '2026-10-25T08:00:00.512Z' },
    },
    { was: 'Lizenztester', purchase: yearlyTrial({ testPurchase: {} }), expected: { environment: 'test' } },
    {
      was: 'Planwechsel: spaetestes expiryTime, linkedPurchaseToken',
      purchase: yearlyTrial({
        linkedPurchaseToken: 'old-monthly-token.AO-J1Ox',
        lineItems: [
          { ...item, expiryTime: '2026-11-01T08:00:00Z' },
          { productId: 'eatova_premium_monthly', expiryTime: '2027-11-01T08:00:00.123456789Z', prepaidPlan: {} },
          { productId: 'someone_elses_product', expiryTime: '2030-01-01T00:00:00Z' },
        ],
      }),
      expected: {
        productId: 'eatova_premium_monthly',
        basePlanId: null,
        expiresAt: '2027-11-01T08:00:00.123Z',
        autoRenewing: false,
        linkedStoreKey: 'old-monthly-token.AO-J1Ox',
        lastTransactionId: null,
      },
    },
    {
      was: 'ausserhalb der App gekauft (kein Konto-Token)',
      purchase: yearlyTrial({ externalAccountIdentifiers: undefined }),
      expected: { obfuscatedAccountId: null },
    },
    {
      was: 'Konto-Token in Grossbuchstaben',
      purchase: yearlyTrial({ externalAccountIdentifiers: { obfuscatedExternalAccountId: ACCOUNT.toUpperCase() } }),
      expected: { obfuscatedAccountId: ACCOUNT.toUpperCase() },
    },
    {
      was: 'Benachrichtigung ohne Aufrufer-Token',
      purchase: yearlyTrial({ externalAccountIdentifiers: { obfuscatedExternalAccountId: 'another-account' } }),
      options: { ...OPTIONS, accountToken: null },
      expected: { obfuscatedAccountId: 'another-account' },
    },
    {
      was: 'fremdes Konto',
      purchase: yearlyTrial({ externalAccountIdentifiers: { obfuscatedExternalAccountId: 'another-account' } }),
      expected: { reason: 'account' },
    },
    {
      was: 'fremdes Produkt',
      purchase: yearlyTrial({ lineItems: [{ ...item, productId: 'other_app_premium' }] }),
      expected: { reason: 'product' },
    },
    {
      was: 'PENDING',
      purchase: yearlyTrial({ subscriptionState: 'SUBSCRIPTION_STATE_PENDING' }),
      expected: { reason: 'pending' },
    },
    {
      was: 'unbekannter Zustand',
      purchase: yearlyTrial({ subscriptionState: 'SUBSCRIPTION_STATE_UNSPECIFIED' }),
      expected: { reason: 'malformed' },
    },
    {
      was: 'ACTIVE ohne expiryTime',
      purchase: yearlyTrial({ lineItems: [{ ...item, expiryTime: undefined }] }),
      expected: { reason: 'malformed' },
    },
  ];
  for (const row of cases) {
    const result = mapPlayPurchase(JSON.parse(JSON.stringify(row.purchase)), row.options ?? OPTIONS);
    if ('reason' in row.expected) {
      assertEquals(result, { ok: false, reason: row.expected.reason }, row.was);
      continue;
    }
    assert(result.ok, `${row.was}: ok erwartet, war ${JSON.stringify(result)}`);
    const picked = Object.fromEntries(
      Object.keys(row.expected).map((key) => [key, (result.row as unknown as Row)[key]]),
    );
    assertEquals(picked, row.expected, row.was);
  }
});
