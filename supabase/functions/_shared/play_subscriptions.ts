// Google Play Developer API v3 for subscriptions: purchases.subscriptionsv2.get,
// purchases.subscriptions.acknowledge, and the mapping of a
// SubscriptionPurchaseV2 to the fields record_store_subscription stores
// (docs/PREMIUM.md 2.5, 3.4). The caller brings the access token
// (google_auth.ts). Never log the purchase token, the access token or a body.

import { readProviderBody } from './provider_body.ts';

export const ANDROID_PUBLISHER_APPLICATIONS =
  'https://androidpublisher.googleapis.com/androidpublisher/v3/applications';
/** Matches the store_key bound of store_subscriptions. */
export const PURCHASE_TOKEN_MAX_LENGTH = 4096;
const PURCHASE_MAX_BYTES = 64 * 1024;
const TEXT_FIELD_MAX_LENGTH = 200;

const PACKAGE_NAME = /^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$/;
// Play product ids: lowercase letters, digits, underscores and periods.
const PRODUCT_ID = /^[a-z0-9][a-z0-9._]{0,199}$/;
const PRINTABLE = /^[\x21-\x7e]+$/;

/** The JSON body of subscriptionsv2.get; validated by mapPlayPurchase. */
export type SubscriptionPurchaseV2 = Readonly<Record<string, unknown>>;

/** not_found: 404/410, the token does not exist (or no longer); unavailable:
 *  everything else (5xx, 429, 401/403, timeouts, unreadable bodies), retry. */
export type PlayFetchOutcome =
  | { kind: 'ok'; purchase: SubscriptionPurchaseV2 }
  | { kind: 'not_found' }
  | { kind: 'unavailable'; status: number | null };

export type PlayAcknowledgeOutcome =
  | { kind: 'ok' }
  | { kind: 'not_found' }
  | { kind: 'unavailable'; status: number | null };

export interface PlayRequestOptions {
  accessToken: string;
  signal: AbortSignal;
}

export function isPlayPurchaseToken(value: unknown): value is string {
  return typeof value === 'string' && value.length <= PURCHASE_TOKEN_MAX_LENGTH && PRINTABLE.test(value);
}

export function isPlayProductId(value: unknown): value is string {
  return typeof value === 'string' && PRODUCT_ID.test(value);
}

export async function getSubscriptionV2(
  packageName: string,
  purchaseToken: string,
  options: PlayRequestOptions,
): Promise<PlayFetchOutcome> {
  if (!PACKAGE_NAME.test(packageName) || !options.accessToken) return { kind: 'unavailable', status: null };
  if (!isPlayPurchaseToken(purchaseToken)) return { kind: 'not_found' };
  const url = `${ANDROID_PUBLISHER_APPLICATIONS}/${packageName}/purchases/subscriptionsv2/tokens/` +
    encodeURIComponent(purchaseToken);
  const response = await send(url, 'GET', options);
  if (!(response instanceof Response)) return response;
  let purchase: unknown = null;
  try {
    const text = await readProviderBody(response, PURCHASE_MAX_BYTES, options.signal);
    purchase = text === null ? null : JSON.parse(text);
  } catch {
    purchase = null;
  }
  if (purchase === null || typeof purchase !== 'object' || Array.isArray(purchase)) {
    return { kind: 'unavailable', status: response.status };
  }
  return { kind: 'ok', purchase: purchase as SubscriptionPurchaseV2 };
}

/** There is no v2 acknowledge; the v1 endpoint takes the product id. */
export async function acknowledgeSubscription(
  packageName: string,
  productId: string,
  purchaseToken: string,
  options: PlayRequestOptions,
): Promise<PlayAcknowledgeOutcome> {
  if (!PACKAGE_NAME.test(packageName) || !options.accessToken) return { kind: 'unavailable', status: null };
  if (!isPlayProductId(productId) || !isPlayPurchaseToken(purchaseToken)) return { kind: 'not_found' };
  const url = `${ANDROID_PUBLISHER_APPLICATIONS}/${packageName}/purchases/subscriptions/${productId}/tokens/` +
    `${encodeURIComponent(purchaseToken)}:acknowledge`;
  const response = await send(url, 'POST', options);
  if (!(response instanceof Response)) return response;
  void response.body?.cancel().catch(() => {});
  return { kind: 'ok' };
}

async function send(
  url: string,
  method: 'GET' | 'POST',
  options: PlayRequestOptions,
): Promise<Response | { kind: 'not_found' } | { kind: 'unavailable'; status: number | null }> {
  let response: Response;
  try {
    response = await fetch(url, {
      method,
      headers: {
        authorization: `Bearer ${options.accessToken}`,
        accept: 'application/json',
        ...(method === 'POST' ? { 'content-type': 'application/json' } : {}),
      },
      body: method === 'POST' ? '{}' : undefined,
      redirect: 'error',
      signal: options.signal,
    });
  } catch {
    return { kind: 'unavailable', status: null };
  }
  if (response.ok) return response;
  void response.body?.cancel().catch(() => {});
  if (response.status === 404 || response.status === 410) return { kind: 'not_found' };
  return { kind: 'unavailable', status: response.status };
}

// ---------------------------------------------------------------------------
// Mapping to a store_subscriptions row

export type PlayRowStatus = 'active' | 'grace' | 'canceled' | 'on_hold' | 'paused' | 'expired';

/** The Google fields of record_store_subscription. The caller adds the user,
 *  `store_key` (the purchase token) and `event_at`. */
export interface PlaySubscriptionRow {
  platform: 'google';
  productId: string;
  basePlanId: string | null;
  status: PlayRowStatus;
  /** ISO 8601; the latest expiryTime of the allowlisted line items. */
  expiresAt: string;
  expiresAtMs: number;
  autoRenewing: boolean | null;
  environment: 'production' | 'test';
  ownership: null;
  acknowledged: boolean;
  /** Active or grace with ACKNOWLEDGEMENT_STATE_PENDING: acknowledge after storing. */
  needsAcknowledge: boolean;
  /** linkedPurchaseToken: the row it supersedes. */
  linkedStoreKey: string | null;
  lastTransactionId: string | null;
  /** externalAccountIdentifiers.obfuscatedExternalAccountId, the Eatova account token. */
  obfuscatedAccountId: string | null;
}

export type PlayMapFailure =
  | 'product' // no line item with an allowlisted product
  | 'account' // bound to another account token
  | 'pending' // SUBSCRIPTION_STATE_PENDING: payment not completed, grant nothing
  | 'malformed'; // unknown state, or an entitling state without an expiry

export type PlayMapResult =
  | { ok: true; row: PlaySubscriptionRow }
  | { ok: false; reason: PlayMapFailure };

export interface PlayMapOptions {
  productAllowlist: ReadonlySet<string>;
  /** The caller's account token. Pass null only when the owner is already
   *  established by a stored binding (store notifications). */
  accountToken: string | null;
}

const STATES = new Map<string, PlayRowStatus | 'pending'>([
  ['SUBSCRIPTION_STATE_ACTIVE', 'active'],
  ['SUBSCRIPTION_STATE_IN_GRACE_PERIOD', 'grace'],
  ['SUBSCRIPTION_STATE_CANCELED', 'canceled'],
  ['SUBSCRIPTION_STATE_ON_HOLD', 'on_hold'],
  ['SUBSCRIPTION_STATE_PAUSED', 'paused'],
  ['SUBSCRIPTION_STATE_EXPIRED', 'expired'],
  ['SUBSCRIPTION_STATE_PENDING_PURCHASE_CANCELED', 'expired'],
  ['SUBSCRIPTION_STATE_PENDING', 'pending'],
]);

const ENTITLING: ReadonlySet<PlayRowStatus> = new Set(['active', 'grace', 'canceled']);

export function mapPlayPurchase(purchase: unknown, options: PlayMapOptions): PlayMapResult {
  if (!isRecord(purchase)) return mapFail('malformed');
  const lineItems = Array.isArray(purchase.lineItems) ? purchase.lineItems.filter(isRecord) : [];
  const allowed = lineItems.filter((item) =>
    typeof item.productId === 'string' && options.productAllowlist.has(item.productId)
  );
  if (allowed.length === 0) return mapFail('product');

  // Absent for purchases made outside the app: then the first presenter binds.
  const identifiers = purchase.externalAccountIdentifiers;
  const rawAccountId = isRecord(identifiers) ? identifiers.obfuscatedExternalAccountId : undefined;
  const accountIdPresent = rawAccountId !== undefined && rawAccountId !== null && rawAccountId !== '';
  const obfuscatedAccountId = accountIdPresent ? boundedText(rawAccountId, 64) : null;
  if (
    accountIdPresent && options.accountToken !== null &&
    obfuscatedAccountId?.toLowerCase() !== options.accountToken.toLowerCase()
  ) {
    return mapFail('account');
  }

  const state = typeof purchase.subscriptionState === 'string' ? STATES.get(purchase.subscriptionState) : undefined;
  if (!state) return mapFail('malformed');
  if (state === 'pending') return mapFail('pending');

  // The line item that runs longest decides product, plan and renewal.
  let chosen = allowed[0];
  let expiresAtMs: number | null = null;
  for (const item of allowed) {
    const expiry = rfc3339Ms(item.expiryTime);
    if (expiry !== null && (expiresAtMs === null || expiry > expiresAtMs)) {
      expiresAtMs = expiry;
      chosen = item;
    }
  }
  if (expiresAtMs === null) {
    // Never grant without an expiry; an ended purchase falls back to its start.
    if (ENTITLING.has(state)) return mapFail('malformed');
    expiresAtMs = rfc3339Ms(purchase.startTime) ?? 0;
  }

  const offer = chosen.offerDetails;
  const autoRenewingPlan = chosen.autoRenewingPlan;
  const acknowledgementState = purchase.acknowledgementState;
  return {
    ok: true,
    row: {
      platform: 'google',
      productId: chosen.productId as string,
      basePlanId: isRecord(offer) ? boundedText(offer.basePlanId, TEXT_FIELD_MAX_LENGTH) : null,
      status: state,
      expiresAt: new Date(expiresAtMs).toISOString(),
      expiresAtMs,
      // JSON omits false booleans: a renewing plan without the flag is off.
      autoRenewing: isRecord(autoRenewingPlan)
        ? autoRenewingPlan.autoRenewEnabled === true
        : isRecord(chosen.prepaidPlan)
        ? false
        : null,
      environment: isRecord(purchase.testPurchase) ? 'test' : 'production',
      ownership: null,
      acknowledged: acknowledgementState === 'ACKNOWLEDGEMENT_STATE_ACKNOWLEDGED',
      needsAcknowledge: acknowledgementState === 'ACKNOWLEDGEMENT_STATE_PENDING' &&
        (state === 'active' || state === 'grace'),
      linkedStoreKey: isPlayPurchaseToken(purchase.linkedPurchaseToken) ? purchase.linkedPurchaseToken : null,
      lastTransactionId: boundedText(chosen.latestSuccessfulOrderId, TEXT_FIELD_MAX_LENGTH) ??
        boundedText(purchase.latestOrderId, TEXT_FIELD_MAX_LENGTH),
      obfuscatedAccountId,
    },
  };
}

function mapFail(reason: PlayMapFailure): PlayMapResult {
  return { ok: false, reason };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function boundedText(value: unknown, maxLength: number): string | null {
  return typeof value === 'string' && value.length > 0 && value.length <= maxLength && PRINTABLE.test(value)
    ? value
    : null;
}

/** Google emits Z-normalized RFC 3339 with 0, 3, 6 or 9 fractional digits. */
function rfc3339Ms(value: unknown): number | null {
  if (typeof value !== 'string') return null;
  const match = /^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(?:\.(\d{1,9}))?Z$/.exec(value);
  if (!match) return null;
  const ms = Date.parse(`${match[1]}.${(match[2] ?? '').padEnd(3, '0').slice(0, 3)}Z`);
  return Number.isFinite(ms) ? ms : null;
}
