// Eatova subscription verification (docs/PREMIUM.md 3.4). The app hands in a
// store proof after a purchase, a restore or on start; this function checks it
// with the store, binds it to the calling account, records it and answers with
// the account's plan_snapshot. Only this server grants Premium.
//
//   {action: 'verify', platform: 'google', productId, purchaseToken}
//   {action: 'verify', platform: 'apple', signedTransaction}
//   {action: 'refresh'}
//
// verify_jwt stays on; authentication, the auth-fail gate and the 401 codes
// are analyze-meal's. Configuration is read per request so tests can set it.
// The Apple root pin is not configuration: production always uses the
// embedded Apple Root CA - G3, and only createHandler() takes another one.
// Never log a token, a JWS, a user id or a body.

import { authFailGate, forgetAuthFailure, knownAuthFailure } from '../_shared/auth_fail_gate.ts';
import type { AuthFailGateResult } from '../_shared/auth_fail_gate.ts';
import { clientIpSubject } from '../_shared/client_ip.ts';
import { clearGoogleAuthCaches, googleAccessToken } from '../_shared/google_auth.ts';
import { allowedOriginsFromEnv, jsonResponse, responseHeaders } from '../_shared/http.ts';
import { APPLE_ROOT_CA_G3_SHA256, verifyAppleJws } from '../_shared/jws_apple.ts';
import {
  acknowledgeSubscription,
  getSubscriptionV2,
  isPlayProductId,
  isPlayPurchaseToken,
  mapPlayPurchase,
} from '../_shared/play_subscriptions.ts';
import type { PlaySubscriptionRow } from '../_shared/play_subscriptions.ts';
import { readProviderBody } from '../_shared/provider_body.ts';
import { consumeRateLimits, retryAfterSeconds } from '../_shared/rate_limit.ts';
import type { RateLimitGate } from '../_shared/rate_limit.ts';
import {
  googleSubscriptionsToRefresh,
  markStoreSubscriptionAcknowledged,
  planSnapshot,
  recordStoreSubscription,
  storeAccountTokenOf,
} from '../_shared/store_records.ts';
import type {
  PlanSnapshot,
  RecordResult,
  RefreshableGoogleSubscription,
  StoreEnvironment,
  StoreRpcContext,
  StoreStatus,
  StoreSubscriptionRecord,
} from '../_shared/store_records.ts';
import { hasExpectedUserTokenContext } from '../_shared/user_token_context.ts';

const MAX_BODY_BYTES = 64 * 1024;
// The app gives up after 30 s (kSubscriptionVerifyDeadline); answer before.
const REQUEST_BUDGET_MS = 25_000;
const SUPABASE_TIMEOUT_MS = 5_000;
const GOOGLE_TIMEOUT_MS = 8_000;
const IP_GATE = { limit: 60, windowSeconds: 600 };
const USER_GATE = { limit: 30, windowSeconds: 3600 };
const AUTH_FAIL_SCOPE = 'subscription-verify:auth-fail';
const REFRESH_MAX_ROWS = 3;
const REFRESH_HORIZON_MS = 48 * 3_600_000;
const REFRESH_MIN_AGE_MS = 10 * 60_000;
const DEFAULT_PACKAGE_NAME = 'com.eatova.app';
const DEFAULT_BUNDLE_ID = 'com.eatova.app';
const DEFAULT_PRODUCT_IDS = 'eatova_premium,eatova_premium_monthly,eatova_premium_yearly';
const ENTITLING: ReadonlySet<StoreStatus> = new Set(['active', 'grace', 'canceled']);
const APPLE_ENVIRONMENTS = new Map<unknown, StoreEnvironment>([['Production', 'production'], ['Sandbox', 'sandbox']]);
const TRANSACTION_ID = /^[\x21-\x7e]{1,200}$/;
// mapPlayPurchase skips the account check for a null token (webhooks that
// already know the owner). A caller without a token owns no bound purchase,
// so it compares against a value no obfuscatedExternalAccountId equals.
const NO_ACCOUNT_TOKEN = '';

type InvalidReason = 'signature' | 'bundle' | 'product' | 'environment' | 'ownership' | 'account';

class VerifyError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    readonly extra: { reason?: InvalidReason; retryAfter?: number } = {},
  ) {
    super(code);
  }
}

const invalid = (reason: InvalidReason) => new VerifyError(422, 'purchase_invalid', { reason });
const storeUnavailable = () => new VerifyError(503, 'store_unavailable');

type Config = {
  supabaseUrl: string;
  anonKey: string;
  serviceKey: string;
  /** The whole service-account key JSON; empty means Google is not configured. */
  playServiceAccount: string;
  packageName: string;
  bundleId: string;
  productIds: ReadonlySet<string>;
};

type VerifyBody =
  | { action: 'verify'; platform: 'google'; productId: string; purchaseToken: string }
  | { action: 'verify'; platform: 'apple'; signedTransaction: string }
  | { action: 'refresh' };

/** What one request carries through the stages. */
type Call = { config: Config; userId: string; now: () => number; total: AbortSignal; store: StoreRpcContext };

type Answer = { status: 200 | 202; body: Record<string, unknown> };

type StoreFields = Omit<StoreSubscriptionRecord, 'userId'>;

export interface SubscriptionVerifyOptions {
  /** SHA-256 of the trusted Apple root; tests pass the root they generated. */
  appleRootSha256?: string;
  /** Clock for Apple validity, expiry and the refresh window. */
  now?: () => number;
}

export function createHandler(options: SubscriptionVerifyOptions = {}): (request: Request) => Promise<Response> {
  const rootSha256 = options.appleRootSha256 ?? APPLE_ROOT_CA_G3_SHA256;
  const now = options.now ?? (() => Date.now());
  return (request) => handle(request, rootSha256, now);
}

export const handleRequest = createHandler();

async function handle(request: Request, rootSha256: string, now: () => number): Promise<Response> {
  if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers: headers(request) });
  if (request.method !== 'POST') return json(request, { error: 'method_not_allowed' }, 405);
  const total = AbortSignal.any([request.signal, AbortSignal.timeout(REQUEST_BUDGET_MS)]);
  try {
    const config = readConfig();
    if (!config.supabaseUrl || !config.anonKey || !config.serviceKey) {
      throw new VerifyError(500, 'server_misconfigured');
    }
    const userId = await authenticate(request, config, total);
    // Both count attempts, before the body: junk costs its sender too.
    await consumeGates(config, [
      { scope: 'subscription-verify:ip', subject: clientIpSubject(request, userId), ...IP_GATE },
      { scope: 'subscription-verify:user', subject: userId, ...USER_GATE },
    ], total);
    const body = await parseBody(request, total);
    const call: Call = {
      config,
      userId,
      now,
      total,
      store: { supabaseUrl: config.supabaseUrl, serviceKey: config.serviceKey, signal: total },
    };
    const answer = body.action === 'refresh'
      ? await refresh(call)
      : body.platform === 'google'
      ? await verifyGoogle(call, body)
      : await verifyApple(call, body, rootSha256);
    return json(request, answer.body, answer.status);
  } catch (error) {
    if (error instanceof VerifyError) {
      const { reason, retryAfter } = error.extra;
      // A refused proof is the operator's signal for a wrong bundle id or
      // product list, a foreign binding one for a shared purchase.
      if (error.status === 409 || error.status === 422) {
        console.warn('subscription-verify purchase refused', { code: error.code, reason: reason ?? null });
      }
      return json(request, { error: error.code, ...(reason ? { reason } : {}) }, error.status, retryAfter);
    }
    if (request.signal.aborted) return json(request, { error: 'request_aborted' }, 499);
    // Every stage bounds itself; this is a stage that did not.
    console.error('subscription-verify request failed', { overBudget: total.aborted });
    return total.aborted
      ? json(request, { error: 'store_unavailable' }, 503)
      : json(request, { error: 'internal_error' }, 500);
  }
}

// ---------------------------------------------------------------------------
// Google Play

async function verifyGoogle(call: Call, body: { productId: string; purchaseToken: string }): Promise<Answer> {
  if (!call.config.productIds.has(body.productId)) throw invalid('product');
  if (!call.config.playServiceAccount) throw new VerifyError(503, 'store_not_configured');
  const [accountToken, accessToken] = await Promise.all([accountTokenOf(call), playAccessToken(call)]);
  const fetched = await getSubscriptionV2(call.config.packageName, body.purchaseToken, {
    accessToken,
    signal: step(call.total, GOOGLE_TIMEOUT_MS),
  });
  // Google does not know the token for this package: not a proof of ours.
  if (fetched.kind === 'not_found') throw invalid('signature');
  if (fetched.kind === 'unavailable') throw playUnavailable(fetched.status);

  const mapped = mapPlayPurchase(fetched.purchase, {
    productAllowlist: call.config.productIds,
    accountToken: accountToken ?? NO_ACCOUNT_TOKEN,
  });
  if (!mapped.ok) {
    // Payment not completed: nothing is stored or granted. The app shows the
    // pending state and verifies again once the store reports the payment.
    if (mapped.reason === 'pending') {
      return { status: 202, body: { error: 'purchase_pending', plan: await planOf(call) } };
    }
    if (mapped.reason === 'malformed') {
      console.error('subscription-verify google purchase unreadable');
      throw storeUnavailable();
    }
    throw invalid(mapped.reason);
  }

  const row = mapped.row;
  const stored = await record(call, googleFields(body.purchaseToken, row));
  // Only after the row is stored: an unacknowledged purchase is refunded after
  // three days, so a failed write leaves the acknowledgement to the next
  // verify instead of keeping Google's money for a grant that never happened.
  if (stored.outcome === 'stored' && row.needsAcknowledge) {
    await acknowledge(call, accessToken, row.productId, body.purchaseToken);
  }
  return verified(call, outcomeOf(stored, ENTITLING.has(row.status) && row.expiresAtMs > call.now()));
}

/** No event time: subscriptionsv2 is Google's current state, never stale. */
function googleFields(purchaseToken: string, row: PlaySubscriptionRow): StoreFields {
  return {
    platform: 'google',
    storeKey: purchaseToken,
    productId: row.productId,
    basePlanId: row.basePlanId,
    status: row.status,
    expiresAt: row.expiresAt,
    autoRenewing: row.autoRenewing,
    environment: row.environment,
    ownership: null,
    acknowledged: row.acknowledged,
    linkedStoreKey: row.linkedStoreKey,
    lastTransactionId: row.lastTransactionId,
    eventAt: null,
  };
}

async function playAccessToken(call: Call): Promise<string> {
  if (!call.config.playServiceAccount) throw new VerifyError(503, 'store_not_configured');
  const token = await googleAccessToken(call.config.playServiceAccount, {
    signal: step(call.total, GOOGLE_TIMEOUT_MS),
    nowMs: call.now(),
  });
  if (token.ok) return token.accessToken;
  console.error('subscription-verify google auth failed', { reason: token.reason });
  // An unusable or refused key needs the operator; anything else is an outage.
  throw token.reason === 'unavailable' ? storeUnavailable() : new VerifyError(503, 'store_not_configured');
}

function playUnavailable(status: number | null): VerifyError {
  // A revoked access token must not stay cached for its remaining hour.
  if (status === 401) clearGoogleAuthCaches();
  console.error('subscription-verify google purchase lookup failed', { status });
  return storeUnavailable();
}

async function acknowledge(call: Call, accessToken: string, productId: string, purchaseToken: string): Promise<void> {
  const ack = await acknowledgeSubscription(call.config.packageName, productId, purchaseToken, {
    accessToken,
    signal: step(call.total, GOOGLE_TIMEOUT_MS),
  });
  // Not fatal: the purchase is stored, the app's completePurchase also
  // acknowledges, and the next verify or refresh retries.
  if (ack.kind !== 'ok') {
    console.error('subscription-verify acknowledge failed', { status: ack.kind === 'unavailable' ? ack.status : 404 });
    return;
  }
  // The row holds Google's answer from before the acknowledgement (PENDING).
  // A failed mark is only a stale flag until the next verify.
  await markStoreSubscriptionAcknowledged(call.store, 'google', purchaseToken);
}

// ---------------------------------------------------------------------------
// App Store

async function verifyApple(call: Call, body: { signedTransaction: string }, rootSha256: string): Promise<Answer> {
  const proof = await verifyAppleJws(body.signedTransaction, { nowMs: call.now(), rootSha256 });
  if (!proof.ok) {
    // Which check failed (root, chain, validity, ...); the answer says only `signature`.
    console.warn('subscription-verify apple proof rejected', { check: proof.reason });
    throw invalid('signature');
  }
  const p = proof.payload;
  if (p.bundleId !== call.config.bundleId) throw invalid('bundle');
  if (typeof p.productId !== 'string' || !call.config.productIds.has(p.productId)) throw invalid('product');
  if (p.type !== 'Auto-Renewable Subscription') throw invalid('product');
  // App Review buys in the sandbox against the production build.
  const environment = APPLE_ENVIRONMENTS.get(p.environment);
  if (!environment) throw invalid('environment');
  // Family Sharing is off; a shared transaction belongs to someone else's purchase.
  if (p.inAppOwnershipType !== 'PURCHASED') throw invalid('ownership');
  const originalTransactionId = transactionId(p.originalTransactionId);
  const expiresMs = epochMs(p.expiresDate);
  // Authentic but no storable transaction: as unusable as a refused payload.
  if (originalTransactionId === null || expiresMs === null) throw invalid('signature');

  // Absent for purchases made outside the app: then the first presenter binds.
  const ownToken = isPresent(p.appAccountToken);
  if (ownToken && !sameToken(p.appAccountToken, await accountTokenOf(call))) {
    throw invalid('account');
  }
  const purchaseMs = epochMs(p.purchaseDate);

  const status: StoreStatus = isPresent(p.revocationDate) ? 'revoked' : expiresMs > call.now() ? 'active' : 'expired';
  const stored = await record(call, {
    platform: 'apple',
    storeKey: originalTransactionId,
    productId: p.productId,
    basePlanId: null,
    status,
    expiresAt: new Date(expiresMs).toISOString(),
    // Known only from signedRenewalInfo, which store-notifications brings.
    autoRenewing: null,
    environment,
    ownership: 'PURCHASED',
    acknowledged: null,
    linkedStoreKey: null,
    lastTransactionId: transactionId(p.transactionId),
    eventAt: new Date(proof.signedDateMs).toISOString(),
    // Apple keeps one originalTransactionId per Apple ID, so a resubscribe or
    // crossgrade from this account can arrive under a row bound to another
    // one. Signed by Apple with this account's own token, the newer purchase
    // moves it (record_store_subscription); a token-less one does not.
    rebind: ownToken,
    purchaseAt: purchaseMs === null ? null : new Date(purchaseMs).toISOString(),
  });
  return verified(call, outcomeOf(stored, status === 'active'));
}

function isPresent(value: unknown): boolean {
  return value !== undefined && value !== null && value !== '';
}

function sameToken(value: unknown, accountToken: string | null): boolean {
  return typeof value === 'string' && accountToken !== null && value.toLowerCase() === accountToken.toLowerCase();
}

function transactionId(value: unknown): string | null {
  return typeof value === 'string' && TRANSACTION_ID.test(value) ? value : null;
}

function epochMs(value: unknown): number | null {
  return typeof value === 'number' && Number.isSafeInteger(value) && value > 0 ? value : null;
}

// ---------------------------------------------------------------------------
// Refresh: renewals without a webhook

async function refresh(call: Call): Promise<Answer> {
  const nowMs = call.now();
  const due = await googleSubscriptionsToRefresh(call.store, call.userId, {
    expiresBefore: new Date(nowMs + REFRESH_HORIZON_MS).toISOString(),
    verifiedBefore: new Date(nowMs - REFRESH_MIN_AGE_MS).toISOString(),
    limit: REFRESH_MAX_ROWS,
  });
  if (due.kind !== 'ok') throw storeUnavailable();
  if (due.value.length > 0) {
    const accessToken = await playAccessToken(call);
    const done = await Promise.all(due.value.map((row) => recheck(call, accessToken, row)));
    // A recorded row waits ten minutes, so a retry asks only for the rest.
    if (done.includes(false)) throw storeUnavailable();
  }
  const plan = await planOf(call);
  return { status: 200, body: { outcome: plan.tier === 'premium' ? 'active' : 'inactive', plan } };
}

/** One stored row against Google; false when it has to be asked again later. */
async function recheck(call: Call, accessToken: string, row: RefreshableGoogleSubscription): Promise<boolean> {
  const fetched = await getSubscriptionV2(call.config.packageName, row.storeKey, {
    accessToken,
    signal: step(call.total, GOOGLE_TIMEOUT_MS),
  });
  if (fetched.kind === 'unavailable') {
    playUnavailable(fetched.status);
    return false;
  }
  let fields: StoreFields;
  let needsAcknowledge = false;
  if (fetched.kind === 'not_found') {
    // Google forgets long-ended purchases. Only a row that already ended is
    // closed, so a wrong package name can never end a running subscription.
    if (Date.parse(row.expiresAt) > call.now()) return true;
    fields = {
      platform: 'google',
      storeKey: row.storeKey,
      productId: row.productId,
      basePlanId: null,
      status: 'expired',
      expiresAt: row.expiresAt,
      autoRenewing: null,
      environment: row.environment,
      ownership: null,
      acknowledged: null,
      linkedStoreKey: null,
      lastTransactionId: null,
      eventAt: null,
    };
  } else {
    // The stored binding already names the owner; the account check is verify's.
    const mapped = mapPlayPurchase(fetched.purchase, { productAllowlist: call.config.productIds, accountToken: null });
    if (!mapped.ok) {
      console.warn('subscription-verify refresh left a purchase unchanged', { reason: mapped.reason });
      return true;
    }
    fields = googleFields(row.storeKey, mapped.row);
    needsAcknowledge = mapped.row.needsAcknowledge;
  }
  const stored = await recordStoreSubscription(call.store, { userId: call.userId, ...fields });
  if (stored.kind !== 'ok') return false;
  if (stored.value.outcome === 'stored' && needsAcknowledge) {
    await acknowledge(call, accessToken, fields.productId, row.storeKey);
  }
  return true;
}

// ---------------------------------------------------------------------------
// Shared stages

async function accountTokenOf(call: Call): Promise<string | null> {
  const token = await storeAccountTokenOf(call.store, call.userId);
  if (token.kind !== 'ok') throw storeUnavailable();
  return token.value;
}

async function record(call: Call, fields: StoreFields): Promise<RecordResult> {
  const result = await recordStoreSubscription(call.store, { userId: call.userId, ...fields });
  // `invalid` means the database refused what this function built; the app's
  // only move is the same as after an outage: keep the transaction, retry.
  if (result.kind !== 'ok') throw storeUnavailable();
  if (result.value.outcome === 'owned_by_other') throw new VerifyError(409, 'purchase_owned_by_other_account');
  return result.value;
}

/**
 * `active` only when the verified purchase entitles now and the account is
 * Premium after the write. A stale proof (older than the stored event) is
 * answered by the stored state alone.
 */
function outcomeOf(stored: RecordResult, entitles: boolean): 'active' | 'inactive' {
  const premium = stored.tier === 'premium';
  return (stored.outcome === 'stale' ? premium : premium && entitles) ? 'active' : 'inactive';
}

async function planOf(call: Call): Promise<PlanSnapshot> {
  const plan = await planSnapshot(call.store, call.userId);
  if (plan.kind !== 'ok') throw storeUnavailable();
  return plan.value;
}

async function verified(call: Call, outcome: 'active' | 'inactive'): Promise<Answer> {
  return { status: 200, body: { outcome, plan: await planOf(call) } };
}

function readConfig(): Config {
  const text = (name: string, fallback: string) => Deno.env.get(name)?.trim() || fallback;
  const productIds = text('EATOVA_PREMIUM_PRODUCT_IDS', DEFAULT_PRODUCT_IDS).split(',')
    .map((id) => id.trim())
    .filter(Boolean);
  return {
    supabaseUrl: Deno.env.get('SUPABASE_URL') ?? '',
    anonKey: Deno.env.get('SUPABASE_ANON_KEY') ?? '',
    serviceKey: Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '',
    playServiceAccount: Deno.env.get('EATOVA_PLAY_SERVICE_ACCOUNT_JSON')?.trim() ?? '',
    packageName: text('EATOVA_PLAY_PACKAGE_NAME', DEFAULT_PACKAGE_NAME),
    bundleId: text('EATOVA_APPLE_BUNDLE_ID', DEFAULT_BUNDLE_ID),
    productIds: new Set(productIds.length > 0 ? productIds : DEFAULT_PRODUCT_IDS.split(',')),
  };
}

// ---------------------------------------------------------------------------
// Authentication and gates, as in analyze-meal

async function authenticate(request: Request, config: Config, total: AbortSignal): Promise<string> {
  const match = (request.headers.get('authorization') ?? '').match(/^Bearer\s+(.+)$/i);
  if (!match) throw new VerifyError(401, 'missing_bearer_token');
  // Rejected locally: the anon key is public and no user token.
  const token = match[1].trim();
  if (!token || token === config.anonKey) throw new VerifyError(401, 'user_token_required');

  // P7-02: a token GoTrue already rejected twice is answered without a lookup.
  const failSubject = clientIpSubject(request, 'anon');
  const known = await knownAuthFailure({ scope: AUTH_FAIL_SCOPE, subject: failSubject, token });
  if (known !== null) throw authFailure(known);

  const signal = step(total, SUPABASE_TIMEOUT_MS);
  let response: Response;
  try {
    response = await fetch(`${config.supabaseUrl}/auth/v1/user`, {
      headers: { apikey: config.anonKey, authorization: `Bearer ${token}` },
      redirect: 'error',
      signal,
    });
  } catch {
    // A hanging GoTrue is an outage, not a rejected token.
    throw new VerifyError(503, 'auth_unavailable');
  }
  if (response.status === 429 || response.status >= 500) {
    void response.body?.cancel().catch(() => {});
    throw new VerifyError(503, 'auth_unavailable');
  }
  if (!response.ok) {
    void response.body?.cancel().catch(() => {});
    // F-28-1: only a failed lookup costs a slot of the per-IP fail bucket.
    const gate = await authFailGate({
      supabaseUrl: config.supabaseUrl,
      serviceKey: config.serviceKey,
      scope: AUTH_FAIL_SCOPE,
      subject: failSubject,
      signal: step(total, SUPABASE_TIMEOUT_MS),
      rejection: { token, status: response.status },
    });
    throw authFailure(gate);
  }
  let user: unknown;
  try {
    const raw = await readProviderBody(response, 32_000, signal);
    user = raw === null ? null : JSON.parse(raw);
  } catch {
    throw new VerifyError(503, 'auth_unavailable');
  }
  const id = user !== null && typeof user === 'object' ? (user as { id?: unknown }).id : undefined;
  if (typeof id !== 'string' || !hasExpectedUserTokenContext(token, id)) {
    throw new VerifyError(401, 'invalid_user_token');
  }
  await forgetAuthFailure(AUTH_FAIL_SCOPE, token);
  return id;
}

function authFailure(gate: AuthFailGateResult): VerifyError {
  return gate.limited
    ? new VerifyError(429, 'rate_limited', { retryAfter: gate.retryAfterSeconds })
    : new VerifyError(401, 'invalid_user_token');
}

async function consumeGates(config: Config, gates: RateLimitGate[], total: AbortSignal): Promise<void> {
  const outcome = await consumeRateLimits({
    supabaseUrl: config.supabaseUrl,
    serviceKey: config.serviceKey,
    gates,
    signal: step(total, SUPABASE_TIMEOUT_MS),
  });
  if (outcome.kind === 'unavailable') throw new VerifyError(503, 'rate_limit_unavailable');
  if (outcome.kind === 'denied') {
    const retryAfter = retryAfterSeconds(outcome.denied.resetAt, gates[outcome.deniedIndex].windowSeconds);
    throw new VerifyError(429, 'rate_limited', { retryAfter });
  }
}

// ---------------------------------------------------------------------------
// Body

async function parseBody(request: Request, total: AbortSignal): Promise<VerifyBody> {
  const bad = () => new VerifyError(400, 'invalid_request');
  if (!/^application\/json(?:\s*;|$)/i.test(request.headers.get('content-type') ?? '')) throw bad();
  if (Number(request.headers.get('content-length')) > MAX_BODY_BYTES) throw bad();
  let body: unknown;
  try {
    const raw = await readProviderBody(new Response(request.body), MAX_BODY_BYTES, step(total, SUPABASE_TIMEOUT_MS));
    body = raw === null ? null : JSON.parse(raw);
  } catch {
    throw bad();
  }
  if (body === null || typeof body !== 'object' || Array.isArray(body)) throw bad();
  const fields = body as Record<string, unknown>;
  const keys = Object.keys(fields).sort().join(',');
  if (fields.action === 'refresh' && keys === 'action') return { action: 'refresh' };
  if (fields.action !== 'verify') throw bad();
  if (
    fields.platform === 'google' && keys === 'action,platform,productId,purchaseToken' &&
    isPlayProductId(fields.productId) && isPlayPurchaseToken(fields.purchaseToken)
  ) {
    return { action: 'verify', platform: 'google', productId: fields.productId, purchaseToken: fields.purchaseToken };
  }
  if (
    fields.platform === 'apple' && keys === 'action,platform,signedTransaction' &&
    typeof fields.signedTransaction === 'string' && fields.signedTransaction.length > 0
  ) {
    return { action: 'verify', platform: 'apple', signedTransaction: fields.signedTransaction };
  }
  throw bad();
}

// ---------------------------------------------------------------------------
// HTTP

function step(total: AbortSignal, ms: number): AbortSignal {
  return AbortSignal.any([total, AbortSignal.timeout(ms)]);
}

function headers(request: Request): Headers {
  return responseHeaders(request, { methods: 'POST, OPTIONS', origins: allowedOriginsFromEnv() });
}

function json(request: Request, body: Record<string, unknown>, status: number, retryAfter?: number): Response {
  return jsonResponse(body, status, headers(request), retryAfter ? { 'retry-after': String(retryAfter) } : {});
}
