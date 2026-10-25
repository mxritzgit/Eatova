// store-notifications: the public webhook for App Store Server Notifications V2
// and Google Play real-time developer notifications (docs/PREMIUM.md 3.5).
//
// The gateway's verify_jwt is off for this function only (supabase/config.toml),
// so every request authenticates itself. Apple: the signedPayload and its nested
// transaction and renewal JWS verify against the pinned Apple root
// (_shared/jws_apple.ts). Google: the Pub/Sub push carries a Google OIDC token
// for the configured audience and push service account (_shared/google_auth.ts),
// and the purchase state is read fresh from subscriptionsv2, never taken from
// the message. The account comes from the stored binding, else from the account
// token the app sent with the purchase; for Apple the token comes first (one
// originalTransactionId spans every purchase of an Apple ID, see ownerOf).
//
// An event is applied first and its receipt written afterwards: a delivery that
// failed with 503 is retried and applied, never dropped as a duplicate. Applying
// one twice is harmless, because record_store_subscription ignores events older
// than the stored one.
//
// Answers: 200 {outcome}; 400 invalid_notification; 401
// invalid_notification_auth; 429 rate_limited; 503 not_configured,
// store_unavailable or rate_limit_unavailable (the stores retry). Log lines carry
// fixed reasons only, never a payload, token or id.

import { clientIpSubject } from '../_shared/client_ip.ts';
import { clearGoogleAuthCaches, googleAccessToken, verifyGoogleOidcToken } from '../_shared/google_auth.ts';
import { jsonResponse, responseHeaders } from '../_shared/http.ts';
import { base64ToBytes, jsonObjectFromBytes, parseCompactJws } from '../_shared/jose.ts';
import { type AppleJwsResult, verifyAppleJws } from '../_shared/jws_apple.ts';
import { getSubscriptionV2, isPlayPurchaseToken, mapPlayPurchase } from '../_shared/play_subscriptions.ts';
import { readProviderBody } from '../_shared/provider_body.ts';
import { consumeRateLimits, retryAfterSeconds } from '../_shared/rate_limit.ts';
import {
  recordStoreNotification,
  recordStoreSubscription,
  storeAccountOwner,
  type StorePlatform,
  type StoreRpcContext,
  type StoreStatus,
  storeSubscriptionOwner,
  type StoreSubscriptionRecord,
} from '../_shared/store_records.ts';

const MAX_BODY_BYTES = 256 * 1024;
const REQUEST_BUDGET_MS = 20_000;
const STEP_MS = 5_000;
const PLAY_STEP_MS = 10_000;
// A damper against floods before any signature work. Generous, because each
// store sends from a few addresses.
const IP_GATE = { scope: 'store-notifications:ip', limit: 600, windowSeconds: 600 };
const OIDC_TOKEN_MAX_LENGTH = 16_384;
const ID_MAX_LENGTH = 200;
const DEFAULT_APP_ID = 'com.eatova.app';
const DEFAULT_PRODUCT_IDS = 'eatova_premium,eatova_premium_monthly,eatova_premium_yearly';

type Outcome = 'processed' | 'duplicate' | 'unknown_owner' | 'ignored' | 'test';

export interface StoreNotificationOptions {
  /** SHA-256 of the pinned Apple root. Only tests pass their own. */
  appleRootSha256?: string;
  /** Epoch milliseconds; tests freeze it. */
  now?: () => number;
}

interface Config {
  supabaseUrl: string;
  serviceKey: string;
  anonKey: string;
  appleBundleId: string;
  playPackageName: string;
  productIds: ReadonlySet<string>;
  pushAudience: string;
  pushEmail: string;
  playServiceAccount: string;
}

/** A notification after its sender was verified, with its receipt key. */
interface Handled {
  source: StorePlatform;
  id: string;
  outcome: Outcome;
}

class NotificationError extends Error {
  constructor(readonly status: number, readonly code: string, readonly retryAfter?: number) {
    super(code);
  }
}

const invalidNotification = () => new NotificationError(400, 'invalid_notification');
const invalidAuth = () => new NotificationError(401, 'invalid_notification_auth');
const notConfigured = () => new NotificationError(503, 'not_configured');
const storeUnavailable = () => new NotificationError(503, 'store_unavailable');

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

/** A non-empty printable string up to `max` characters, or null. */
function text(value: unknown, max = ID_MAX_LENGTH): string | null {
  return typeof value === 'string' && value.length <= max && /^[\x21-\x7e]+$/.test(value) ? value : null;
}

/** Epoch milliseconds as Apple writes them, or null. */
function millis(value: unknown): number | null {
  return typeof value === 'number' && Number.isSafeInteger(value) && value > 0 ? value : null;
}

function step(total: AbortSignal, milliseconds = STEP_MS): AbortSignal {
  total.throwIfAborted();
  return AbortSignal.any([total, AbortSignal.timeout(milliseconds)]);
}

function note(line: string): void {
  console.warn(`store-notifications: ${line}`);
}

// Server to server: no browser origin is ever allowed.
function headers(request: Request): Headers {
  return responseHeaders(request, { methods: 'POST, OPTIONS', origins: [] });
}

function json(request: Request, data: unknown, status: number, retryAfter?: number): Response {
  return jsonResponse(data, status, headers(request), retryAfter ? { 'Retry-After': String(retryAfter) } : {});
}

function readConfig(): Config {
  const env = (name: string) => (Deno.env.get(name) ?? '').trim();
  const supabaseUrl = env('SUPABASE_URL');
  const serviceKey = env('SUPABASE_SERVICE_ROLE_KEY');
  if (!supabaseUrl || !serviceKey) throw notConfigured();
  return {
    supabaseUrl,
    serviceKey,
    anonKey: env('SUPABASE_ANON_KEY'),
    appleBundleId: env('EATOVA_APPLE_BUNDLE_ID') || DEFAULT_APP_ID,
    playPackageName: env('EATOVA_PLAY_PACKAGE_NAME') || DEFAULT_APP_ID,
    productIds: new Set(
      (env('EATOVA_PREMIUM_PRODUCT_IDS') || DEFAULT_PRODUCT_IDS).split(',').map((id) => id.trim()).filter(Boolean),
    ),
    pushAudience: env('EATOVA_PUBSUB_PUSH_AUDIENCE'),
    pushEmail: env('EATOVA_PUBSUB_PUSH_SA_EMAIL'),
    playServiceAccount: env('EATOVA_PLAY_SERVICE_ACCOUNT_JSON'),
  };
}

async function ipGate(request: Request, config: Config, total: AbortSignal, nowMs: number): Promise<void> {
  const outcome = await consumeRateLimits({
    supabaseUrl: config.supabaseUrl,
    serviceKey: config.serviceKey,
    gates: [{ ...IP_GATE, subject: clientIpSubject(request, 'anon') }],
    signal: step(total),
  });
  if (outcome.kind === 'unavailable') throw new NotificationError(503, 'rate_limit_unavailable');
  if (outcome.kind === 'denied') {
    throw new NotificationError(
      429,
      'rate_limited',
      retryAfterSeconds(outcome.denied.resetAt, IP_GATE.windowSeconds, IP_GATE.windowSeconds, nowMs),
    );
  }
}

async function readBody(request: Request, total: AbortSignal): Promise<Record<string, unknown>> {
  if (Number(request.headers.get('content-length')) > MAX_BODY_BYTES) throw invalidNotification();
  const raw = await readProviderBody(new Response(request.body), MAX_BODY_BYTES, step(total));
  if (raw === null) throw invalidNotification();
  let body: unknown;
  try {
    body = JSON.parse(raw);
  } catch {
    throw invalidNotification();
  }
  if (!isRecord(body)) throw invalidNotification();
  return body;
}

/** The account a notification is for; `viaToken` when its account token named it. */
type Owner = { userId: string; viaToken: boolean };

async function tokenOwner(ctx: StoreRpcContext, accountToken: unknown): Promise<string | null> {
  if (typeof accountToken !== 'string') return null;
  const bound = await storeAccountOwner(ctx, accountToken);
  if (bound.kind === 'unavailable') throw storeUnavailable();
  return bound.kind === 'ok' ? bound.value : null;
}

/**
 * Google: the stored binding of the purchase, else the account of its token
 * (the first binding wins). Apple: the account of the transaction's token
 * first, because Apple keeps one originalTransactionId per Apple ID and the
 * newest purchase decides (record_store_subscription rebinds only a newer
 * one); the stored binding only for a transaction without a known token.
 */
async function ownerOf(
  ctx: StoreRpcContext,
  platform: StorePlatform,
  storeKey: string,
  accountToken: unknown,
): Promise<Owner | null> {
  if (platform === 'apple') {
    const byToken = await tokenOwner(ctx, accountToken);
    if (byToken !== null) return { userId: byToken, viaToken: true };
  }
  const stored = await storeSubscriptionOwner(ctx, platform, storeKey);
  if (stored.kind === 'unavailable') throw storeUnavailable();
  if (stored.kind === 'ok' && stored.value !== null) return { userId: stored.value, viaToken: false };
  if (platform === 'apple') return null;
  const byToken = await tokenOwner(ctx, accountToken);
  return byToken === null ? null : { userId: byToken, viaToken: true };
}

async function apply(ctx: StoreRpcContext, record: StoreSubscriptionRecord): Promise<Outcome> {
  const result = await recordStoreSubscription(ctx, record);
  if (result.kind === 'unavailable') throw storeUnavailable();
  // 22023, e.g. a deleted account: retrying cannot help.
  if (result.kind === 'invalid') {
    note(`${record.platform}: record refused`);
    return 'ignored';
  }
  if (result.value.outcome !== 'stored') note(`${record.platform}: ${result.value.outcome}`);
  return 'processed';
}

// ---------------------------------------------------------------------------
// Apple

const APPLE_ENVIRONMENTS: Readonly<Record<string, 'production' | 'sandbox'>> = {
  Production: 'production',
  Sandbox: 'sandbox',
};

/** The types that change what an account may use; every other type is acknowledged and ignored. */
const APPLE_TYPES: ReadonlySet<string> = new Set([
  'SUBSCRIBED',
  'DID_RENEW',
  'DID_CHANGE_RENEWAL_STATUS',
  'DID_FAIL_TO_RENEW',
  'GRACE_PERIOD_EXPIRED',
  'EXPIRED',
  'REFUND',
  'REVOKE',
  'REFUND_REVERSED',
]);

/** Types that report the subscription's standing rather than one result. */
const APPLE_STANDING: ReadonlySet<string> = new Set([
  'SUBSCRIBED',
  'DID_RENEW',
  'DID_CHANGE_RENEWAL_STATUS',
  'REFUND_REVERSED',
]);

/** data.status: Apple's status of the subscription as of the payload's signedDate. */
const APPLE_STATUS: Readonly<Record<number, StoreStatus>> = {
  1: 'active',
  2: 'expired',
  3: 'on_hold',
  4: 'grace',
  5: 'revoked',
};

function appleStatus(
  type: string,
  subtype: string | undefined,
  dataStatus: unknown,
  autoRenewing: boolean | null,
): StoreStatus {
  if (APPLE_STANDING.has(type)) {
    const standing = typeof dataStatus === 'number' ? APPLE_STATUS[dataStatus] : undefined;
    if (standing !== undefined && standing !== 'active') return standing;
    // canceled = auto-renew off, still paid until expires_at.
    return autoRenewing === false ? 'canceled' : 'active';
  }
  if (type === 'DID_FAIL_TO_RENEW') return subtype === 'GRACE_PERIOD' ? 'grace' : 'on_hold';
  if (type === 'GRACE_PERIOD_EXPIRED') return 'on_hold';
  if (type === 'EXPIRED') return 'expired';
  return 'revoked'; // REFUND, REVOKE
}

async function appleNotification(
  signedPayload: string,
  config: Config,
  ctx: StoreRpcContext,
  verify: (jws: string) => Promise<AppleJwsResult>,
): Promise<Handled> {
  const verified = await verify(signedPayload);
  if (!verified.ok) {
    note(`apple payload ${verified.reason}`);
    throw invalidAuth();
  }
  const payload = verified.payload;
  const { notificationType: type, subtype, data } = payload;
  const id = text(payload.notificationUUID);
  if (typeof type !== 'string' || id === null || (subtype !== undefined && typeof subtype !== 'string')) {
    throw invalidNotification();
  }
  const handled = (outcome: Outcome): Handled => ({ source: 'apple', id, outcome });
  if (type !== 'TEST' && !APPLE_TYPES.has(type)) return handled('ignored');
  if (!isRecord(data) || data.bundleId !== config.appleBundleId) {
    note('apple: foreign bundle');
    throw invalidNotification();
  }
  if (type === 'TEST') return handled('test');

  const environment = typeof data.environment === 'string' ? APPLE_ENVIRONMENTS[data.environment] : undefined;
  if (environment === undefined || typeof data.signedTransactionInfo !== 'string') throw invalidNotification();
  const transaction = await verify(data.signedTransactionInfo);
  if (!transaction.ok) {
    note(`apple transaction ${transaction.reason}`);
    throw invalidAuth();
  }
  let renewal: Record<string, unknown> | null = null;
  if (data.signedRenewalInfo !== undefined) {
    if (typeof data.signedRenewalInfo !== 'string') throw invalidNotification();
    const renewalJws = await verify(data.signedRenewalInfo);
    if (!renewalJws.ok) {
      note(`apple renewal ${renewalJws.reason}`);
      throw invalidAuth();
    }
    renewal = renewalJws.payload;
  }

  const tx = transaction.payload;
  const storeKey = text(tx.originalTransactionId);
  const expiresMs = millis(tx.expiresDate);
  if (
    tx.bundleId !== config.appleBundleId || storeKey === null || expiresMs === null ||
    (tx.environment !== undefined && tx.environment !== data.environment) ||
    (renewal !== null && renewal.originalTransactionId !== tx.originalTransactionId)
  ) {
    throw invalidNotification();
  }
  // Authentic, but nothing Premium grants: answered 200, so Apple does not retry it.
  if (
    tx.type !== 'Auto-Renewable Subscription' || typeof tx.productId !== 'string' ||
    !config.productIds.has(tx.productId) || tx.inAppOwnershipType !== 'PURCHASED'
  ) {
    note('apple: not a Premium purchase');
    return handled('ignored');
  }

  const autoRenewing = renewal?.autoRenewStatus === 1 ? true : renewal?.autoRenewStatus === 0 ? false : null;
  const status: StoreStatus = millis(tx.revocationDate) !== null
    ? 'revoked'
    : appleStatus(type, subtype, data.status, autoRenewing);
  const graceMs = millis(renewal?.gracePeriodExpiresDate);
  const expiresAtMs = status === 'grace' && graceMs !== null && graceMs > expiresMs ? graceMs : expiresMs;

  const owner = await ownerOf(ctx, 'apple', storeKey, tx.appAccountToken);
  if (owner === null) {
    note('apple: unknown owner');
    return handled('unknown_owner');
  }
  const purchaseMs = millis(tx.purchaseDate);
  return handled(
    await apply(ctx, {
      userId: owner.userId,
      platform: 'apple',
      storeKey,
      productId: tx.productId,
      basePlanId: null,
      status,
      expiresAt: new Date(expiresAtMs).toISOString(),
      autoRenewing,
      environment,
      ownership: 'PURCHASED',
      acknowledged: null,
      linkedStoreKey: null,
      lastTransactionId: text(tx.transactionId),
      eventAt: new Date(verified.signedDateMs).toISOString(),
      rebind: owner.viaToken,
      purchaseAt: purchaseMs === null ? null : new Date(purchaseMs).toISOString(),
    }),
  );
}

// ---------------------------------------------------------------------------
// Google

async function googleNotification(
  request: Request,
  body: Record<string, unknown>,
  config: Config,
  ctx: StoreRpcContext,
  total: AbortSignal,
  now: () => number,
): Promise<Handled> {
  const token = request.headers.get('authorization')?.match(/^Bearer\s+(\S+)\s*$/i)?.[1] ?? null;
  // Not even shaped like a Google ID token (none, the anon key, a Supabase JWT):
  // 401 before the configuration check, so the boot probe gets the handler's 401.
  const shape = token !== null && token !== config.anonKey ? parseCompactJws(token, OIDC_TOKEN_MAX_LENGTH) : null;
  if (token === null || shape === null || shape.header.alg !== 'RS256' || typeof shape.header.kid !== 'string') {
    throw invalidAuth();
  }
  if (!config.pushAudience || !config.pushEmail || !config.playServiceAccount) throw notConfigured();
  const verified = await verifyGoogleOidcToken(token, {
    audience: config.pushAudience,
    email: config.pushEmail,
    signal: step(total),
    nowMs: now(),
  });
  if (!verified.ok) {
    if (verified.reason === 'jwks_unavailable') throw storeUnavailable();
    note(`google token ${verified.reason}`);
    throw invalidAuth();
  }

  const message = body.message;
  const id = isRecord(message) ? text(message.messageId ?? message.message_id) : null;
  const bytes = isRecord(message) && typeof message.data === 'string' ? base64ToBytes(message.data) : null;
  const notification = bytes === null ? null : jsonObjectFromBytes(bytes);
  if (id === null || notification === null) throw invalidNotification();
  const handled = (outcome: Outcome): Handled => ({ source: 'google', id, outcome });
  if (notification.packageName !== config.playPackageName) {
    note('google: foreign package');
    throw invalidNotification();
  }
  if (isRecord(notification.testNotification)) return handled('test');

  const subscription = notification.subscriptionNotification;
  const voided = notification.voidedPurchaseNotification;
  let purchaseToken: unknown;
  if (isRecord(subscription)) {
    purchaseToken = subscription.purchaseToken;
  } else if (isRecord(voided)) {
    // productType 1 is a subscription; one-time products are not Premium.
    if (voided.productType !== 1) return handled('ignored');
    purchaseToken = voided.purchaseToken;
  } else {
    return handled('ignored');
  }
  const eventTime = notification.eventTimeMillis;
  const eventMs = typeof eventTime === 'string' && /^[1-9]\d{0,15}$/.test(eventTime) ? Number(eventTime) : null;
  if (eventMs === null || !isPlayPurchaseToken(purchaseToken)) throw invalidNotification();

  const access = await googleAccessToken(config.playServiceAccount, { signal: step(total), nowMs: now() });
  if (!access.ok) {
    note(`google access token ${access.reason}`);
    throw access.reason === 'invalid_key' ? notConfigured() : storeUnavailable();
  }
  const fetched = await getSubscriptionV2(config.playPackageName, purchaseToken, {
    accessToken: access.accessToken,
    signal: step(total, PLAY_STEP_MS),
  });
  if (fetched.kind === 'unavailable') {
    // A revoked access token stays cached otherwise.
    if (fetched.status === 401) clearGoogleAuthCaches();
    note(`google subscriptionsv2 ${fetched.status ?? 'unreachable'}`);
    throw storeUnavailable();
  }
  if (fetched.kind === 'not_found') {
    note('google: purchase unknown to Play');
    return handled('ignored');
  }
  // No account check here: the owner comes from the binding or from this very id.
  const mapped = mapPlayPurchase(fetched.purchase, { productAllowlist: config.productIds, accountToken: null });
  if (!mapped.ok) {
    note(`google purchase ${mapped.reason}`);
    return handled('ignored');
  }
  const row = mapped.row;
  const owner = await ownerOf(ctx, 'google', purchaseToken, row.obfuscatedAccountId);
  if (owner === null) {
    note('google: unknown owner');
    return handled('unknown_owner');
  }
  return handled(
    await apply(ctx, {
      userId: owner.userId,
      platform: 'google',
      storeKey: purchaseToken,
      productId: row.productId,
      basePlanId: row.basePlanId,
      status: isRecord(subscription) ? row.status : 'revoked',
      expiresAt: row.expiresAt,
      autoRenewing: row.autoRenewing,
      environment: row.environment,
      ownership: null,
      acknowledged: row.acknowledged,
      linkedStoreKey: row.linkedStoreKey,
      lastTransactionId: row.lastTransactionId,
      eventAt: new Date(eventMs).toISOString(),
    }),
  );
}

// ---------------------------------------------------------------------------

export function createHandler(options: StoreNotificationOptions = {}): (request: Request) => Promise<Response> {
  const now = options.now ?? Date.now;
  const verifyApple = (jws: string) => verifyAppleJws(jws, { nowMs: now(), rootSha256: options.appleRootSha256 });

  return async function handleRequest(request: Request): Promise<Response> {
    if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers: headers(request) });
    if (request.method !== 'POST') return json(request, { error: 'method_not_allowed' }, 405);
    const total = AbortSignal.any([request.signal, AbortSignal.timeout(REQUEST_BUDGET_MS)]);
    try {
      const config = readConfig();
      const ctx: StoreRpcContext = { supabaseUrl: config.supabaseUrl, serviceKey: config.serviceKey, signal: total };
      await ipGate(request, config, total, now());
      const body = await readBody(request, total);
      const handled = typeof body.signedPayload === 'string'
        ? await appleNotification(body.signedPayload, config, ctx, verifyApple)
        : await googleNotification(request, body, config, ctx, total, now);
      let outcome = handled.outcome;
      if (outcome !== 'test') {
        const receipt = await recordStoreNotification(ctx, handled.source, handled.id);
        if (receipt.kind === 'ok' && !receipt.value) outcome = 'duplicate';
      }
      return json(request, { outcome }, 200);
    } catch (error) {
      if (error instanceof NotificationError) {
        return json(request, { error: error.code }, error.status, error.retryAfter);
      }
      if (total.aborted || error instanceof DOMException && ['TimeoutError', 'AbortError'].includes(error.name)) {
        return json(request, { error: 'store_unavailable' }, 503);
      }
      // Exceptions may hold payload fragments; never log them.
      console.error('store-notifications request failed');
      return json(request, { error: 'internal_error' }, 500);
    }
  };
}

export const handleRequest = createHandler();
