// Server clients for the store tables of 20261025100000: the record RPCs,
// the acknowledgement mark, the owner lookups, the caller's account token
// and plan_snapshot. Every call carries the service key, so none follows a
// redirect, every answer is read under a byte cap and every call is bounded
// by a timeout.
//
// Three outcomes, never an exception: `ok` with the typed value; `invalid`
// when the database refused the input with 22023 (retrying cannot help; a
// webhook answers 200 and drops it); `unavailable` for everything else
// (transport, timeout, non-2xx, oversized or unexpected answer; a webhook
// answers 503 so the store retries). Log lines name the RPC and the status,
// never a body, a token or an id.

import { readProviderBody } from './provider_body.ts';

export interface StoreRpcContext {
  supabaseUrl: string;
  serviceKey: string;
  /** The caller's deadline; the call is additionally capped at `timeoutMs`. */
  signal?: AbortSignal;
  timeoutMs?: number;
}

export type StoreRpcResult<T> =
  | { kind: 'ok'; value: T }
  | { kind: 'invalid' }
  | { kind: 'unavailable' };

export type StorePlatform = 'google' | 'apple';
export type StoreStatus =
  | 'active'
  | 'grace'
  | 'canceled'
  | 'on_hold'
  | 'paused'
  | 'pending'
  | 'expired'
  | 'revoked';
export type StoreEnvironment = 'production' | 'sandbox' | 'test';
export type RecordOutcome = 'stored' | 'stale' | 'owned_by_other';

/** One verified purchase, the arguments of record_store_subscription. */
export interface StoreSubscriptionRecord {
  userId: string;
  platform: StorePlatform;
  /** Google purchaseToken or Apple originalTransactionId. */
  storeKey: string;
  productId: string;
  basePlanId: string | null;
  status: StoreStatus;
  /** ISO 8601 timestamp. */
  expiresAt: string;
  /** Null keeps the stored value. */
  autoRenewing: boolean | null;
  environment: StoreEnvironment;
  ownership: string | null;
  acknowledged: boolean | null;
  /** Google linkedPurchaseToken: the purchase this one replaces. */
  linkedStoreKey: string | null;
  lastTransactionId: string | null;
  /** Event time for out-of-order notifications (ISO 8601), or null. */
  eventAt: string | null;
  /**
   * Apple only: the transaction carries `userId`'s own appAccountToken, so a
   * newer purchase may move a row bound to another account (2.5). Default false.
   */
  rebind?: boolean;
  /** Apple purchaseDate (ISO 8601); orders rebinds. Default null. */
  purchaseAt?: string | null;
}

export interface RecordResult {
  outcome: RecordOutcome;
  tier: 'free' | 'premium';
}

/** plan_snapshot / get_my_plan (docs/PREMIUM.md 2.4), passed on to the app. */
export type PlanSnapshot = Record<string, unknown> & { tier: 'free' | 'premium' };

const DEFAULT_TIMEOUT_MS = 5000;
const MAX_TIMEOUT_MS = 10_000;
/** Scalar and small object answers. */
const SMALL_ANSWER_BYTES = 1024;
/** The snapshot is well under 2 KiB; the cap leaves room, nothing more. */
const SNAPSHOT_BYTES = 16 * 1024;
/** PostgREST error bodies are a few hundred bytes. */
const ERROR_BYTES = 2048;

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function isUuid(value: unknown): value is string {
  return typeof value === 'string' && UUID.test(value);
}

type RawResult = { kind: 'ok'; body: unknown } | { kind: 'invalid' } | { kind: 'unavailable' };

/** Sends one PostgREST request with the service key; never throws. */
async function request(
  ctx: StoreRpcContext,
  label: string,
  path: string,
  init: { method: 'GET' } | { method: 'POST'; body: unknown },
  maxBytes: number,
): Promise<RawResult> {
  const timeoutMs = Math.max(1, Math.min(ctx.timeoutMs ?? DEFAULT_TIMEOUT_MS, MAX_TIMEOUT_MS));
  const signal = AbortSignal.any([AbortSignal.timeout(timeoutMs), ...(ctx.signal ? [ctx.signal] : [])]);
  let response: Response;
  try {
    response = await fetch(`${ctx.supabaseUrl}${path}`, {
      method: init.method,
      headers: {
        apikey: ctx.serviceKey,
        authorization: `Bearer ${ctx.serviceKey}`,
        ...(init.method === 'POST' ? { 'content-type': 'application/json' } : {}),
        accept: 'application/json',
      },
      ...(init.method === 'POST' ? { body: JSON.stringify(init.body) } : {}),
      redirect: 'error',
      signal,
    });
  } catch {
    console.error(`${label} unavailable`);
    return { kind: 'unavailable' };
  }

  if (!response.ok) {
    // Only the SQLSTATE is read from the error body; it is never logged.
    let code: unknown;
    try {
      const raw = await readProviderBody(response, ERROR_BYTES, signal);
      code = raw === null ? undefined : (JSON.parse(raw) as { code?: unknown } | null)?.code;
    } catch {
      code = undefined;
    }
    if (code === '22023') return { kind: 'invalid' };
    console.error(`${label} failed: HTTP ${response.status}`);
    return { kind: 'unavailable' };
  }

  try {
    const raw = await readProviderBody(response, maxBytes, signal);
    if (raw === null) {
      console.error(`${label}: answer too large`);
      return { kind: 'unavailable' };
    }
    return { kind: 'ok', body: JSON.parse(raw) };
  } catch {
    console.error(`${label}: answer unreadable`);
    return { kind: 'unavailable' };
  }
}

function rpc(ctx: StoreRpcContext, name: string, args: Record<string, unknown>, maxBytes: number) {
  return request(ctx, name, `/rest/v1/rpc/${name}`, { method: 'POST', body: args }, maxBytes);
}

/** Maps a 2xx body through `read`; a body `read` rejects is an outage. */
function typed<T>(label: string, raw: RawResult, read: (body: unknown) => T | undefined): StoreRpcResult<T> {
  if (raw.kind !== 'ok') return raw;
  const value = read(raw.body);
  if (value === undefined) {
    console.error(`${label}: unexpected answer`);
    return { kind: 'unavailable' };
  }
  return { kind: 'ok', value };
}

const readOwner = (body: unknown): string | null | undefined =>
  body === null ? null : isUuid(body) ? body : undefined;

export async function recordStoreSubscription(
  ctx: StoreRpcContext,
  record: StoreSubscriptionRecord,
): Promise<StoreRpcResult<RecordResult>> {
  const raw = await rpc(ctx, 'record_store_subscription', {
    p_user_id: record.userId,
    p_platform: record.platform,
    p_store_key: record.storeKey,
    p_product_id: record.productId,
    p_base_plan_id: record.basePlanId,
    p_status: record.status,
    p_expires_at: record.expiresAt,
    p_auto_renewing: record.autoRenewing,
    p_environment: record.environment,
    p_ownership: record.ownership,
    p_acknowledged: record.acknowledged,
    p_linked_store_key: record.linkedStoreKey,
    p_last_transaction_id: record.lastTransactionId,
    p_event_at: record.eventAt,
    p_rebind: record.rebind ?? false,
    p_purchase_at: record.purchaseAt ?? null,
  }, SMALL_ANSWER_BYTES);
  return typed('record_store_subscription', raw, (body) => {
    if (!isRecord(body)) return undefined;
    const { outcome, tier } = body;
    if (outcome !== 'stored' && outcome !== 'stale' && outcome !== 'owned_by_other') return undefined;
    if (tier !== 'free' && tier !== 'premium') return undefined;
    return { outcome, tier };
  });
}

/**
 * Marks a stored purchase as acknowledged after the store confirmed it; true
 * when the flag changed. Touches only that flag (never a newer state).
 */
export async function markStoreSubscriptionAcknowledged(
  ctx: StoreRpcContext,
  platform: StorePlatform,
  storeKey: string,
): Promise<StoreRpcResult<boolean>> {
  if (storeKey.length < 1 || storeKey.length > 4096) return { kind: 'invalid' };
  const raw = await rpc(ctx, 'mark_store_subscription_acknowledged', {
    p_platform: platform,
    p_store_key: storeKey,
  }, SMALL_ANSWER_BYTES);
  return typed('mark_store_subscription_acknowledged', raw, (body) => typeof body === 'boolean' ? body : undefined);
}

/** True the first time `notificationId` is seen for `source`, false for a duplicate. */
export async function recordStoreNotification(
  ctx: StoreRpcContext,
  source: StorePlatform,
  notificationId: string,
): Promise<StoreRpcResult<boolean>> {
  const raw = await rpc(ctx, 'record_store_notification', {
    p_source: source,
    p_notification_id: notificationId,
  }, SMALL_ANSWER_BYTES);
  return typed('record_store_notification', raw, (body) => typeof body === 'boolean' ? body : undefined);
}

/** The account of a store account token, or null. A non-UUID token has none. */
export async function storeAccountOwner(
  ctx: StoreRpcContext,
  token: string,
): Promise<StoreRpcResult<string | null>> {
  if (!isUuid(token)) return { kind: 'ok', value: null };
  const raw = await rpc(ctx, 'store_account_owner', { p_token: token }, SMALL_ANSWER_BYTES);
  return typed('store_account_owner', raw, readOwner);
}

/** The account a stored purchase is bound to, or null. */
export async function storeSubscriptionOwner(
  ctx: StoreRpcContext,
  platform: StorePlatform,
  storeKey: string,
): Promise<StoreRpcResult<string | null>> {
  if (storeKey.length < 1 || storeKey.length > 4096) return { kind: 'ok', value: null };
  const raw = await rpc(ctx, 'store_subscription_owner', {
    p_platform: platform,
    p_store_key: storeKey,
  }, SMALL_ANSWER_BYTES);
  return typed('store_subscription_owner', raw, readOwner);
}

/**
 * The account token of `userId` (store_account_tokens), or null while the
 * app has not asked for one yet. Compared with Google's
 * obfuscatedExternalAccountId and Apple's appAccountToken.
 */
export async function storeAccountTokenOf(
  ctx: StoreRpcContext,
  userId: string,
): Promise<StoreRpcResult<string | null>> {
  if (!isUuid(userId)) return { kind: 'invalid' };
  const raw = await request(
    ctx,
    'store_account_tokens',
    `/rest/v1/store_account_tokens?select=token&user_id=eq.${userId}&limit=1`,
    { method: 'GET' },
    SMALL_ANSWER_BYTES,
  );
  return typed('store_account_tokens', raw, (body) => {
    if (!Array.isArray(body) || body.length > 1) return undefined;
    if (body.length === 0) return null;
    const token = isRecord(body[0]) ? body[0].token : undefined;
    return isUuid(token) ? token : undefined;
  });
}

/** plan_snapshot of `userId`, the `plan` of every subscription-verify answer. */
export async function planSnapshot(
  ctx: StoreRpcContext,
  userId: string,
): Promise<StoreRpcResult<PlanSnapshot>> {
  if (!isUuid(userId)) return { kind: 'invalid' };
  const raw = await rpc(ctx, 'plan_snapshot', { p_user_id: userId }, SNAPSHOT_BYTES);
  return typed('plan_snapshot', raw, (body) => {
    if (!isRecord(body) || (body.tier !== 'free' && body.tier !== 'premium')) return undefined;
    if (!isRecord(body.limits) || !isRecord(body.usage) || typeof body.reset_at !== 'string') return undefined;
    if (body.subscription !== null && !isRecord(body.subscription)) return undefined;
    return body as PlanSnapshot;
  });
}

/** A stored Google purchase that subscription-verify's refresh asks Google about again. */
export interface RefreshableGoogleSubscription {
  /** The purchase token. */
  storeKey: string;
  productId: string;
  environment: StoreEnvironment;
  /** As stored (ISO 8601). */
  expiresAt: string;
}

/** Three tokens of at most 4 KiB each, plus the row frame. */
const REFRESH_ROWS_BYTES = 32 * 1024;
/** The states a Google purchase can still leave; expired and revoked are final. */
const OPEN_STATES = 'in.(active,grace,canceled,on_hold,paused)';
const ENVIRONMENTS: ReadonlySet<unknown> = new Set(['production', 'sandbox', 'test']);

/**
 * The account's Google rows that are not final or superseded, expire before
 * `expiresBefore` and were last verified before `verifiedBefore`: the latest
 * expiry first, at most `limit` (1 to 10).
 */
export async function googleSubscriptionsToRefresh(
  ctx: StoreRpcContext,
  userId: string,
  window: { expiresBefore: string; verifiedBefore: string; limit: number },
): Promise<StoreRpcResult<RefreshableGoogleSubscription[]>> {
  if (!isUuid(userId)) return { kind: 'invalid' };
  const limit = Math.max(1, Math.min(10, Math.floor(window.limit)));
  const query = new URLSearchParams({
    select: 'store_key,product_id,environment,expires_at',
    user_id: `eq.${userId}`,
    platform: 'eq.google',
    status: OPEN_STATES,
    superseded_by: 'is.null',
    expires_at: `lt.${window.expiresBefore}`,
    last_verified_at: `lt.${window.verifiedBefore}`,
    order: 'expires_at.desc',
    limit: String(limit),
  });
  const raw = await request(
    ctx,
    'store_subscriptions',
    `/rest/v1/store_subscriptions?${query}`,
    { method: 'GET' },
    REFRESH_ROWS_BYTES,
  );
  return typed('store_subscriptions', raw, (body) => {
    if (!Array.isArray(body) || body.length > limit) return undefined;
    const rows: RefreshableGoogleSubscription[] = [];
    for (const row of body) {
      if (!isRecord(row)) return undefined;
      const { store_key: storeKey, product_id: productId, environment, expires_at: expiresAt } = row;
      if (typeof storeKey !== 'string' || storeKey.length < 1 || storeKey.length > 4096) return undefined;
      if (typeof productId !== 'string' || !ENVIRONMENTS.has(environment)) return undefined;
      if (typeof expiresAt !== 'string' || !Number.isFinite(Date.parse(expiresAt))) return undefined;
      rows.push({ storeKey, productId, environment: environment as StoreEnvironment, expiresAt });
    }
    return rows;
  });
}
