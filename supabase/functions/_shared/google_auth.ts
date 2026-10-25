// Google credentials for the store functions, dependency-free (WebCrypto):
// (a) a service-account access token for the Play Developer API (RS256 JWT
//     bearer grant, cached per isolate until 60 s before it expires);
// (b) verification of the Google-signed OIDC token a Pub/Sub push carries,
//     against Google's JWKS (cached per Cache-Control max-age, bounded).
// Nothing here logs; never log the key JSON, an assertion or a token.

import { readProviderBody } from './provider_body.ts';
import {
  base64ToBytes,
  base64UrlToBytes,
  type Bytes,
  bytesToBase64Url,
  decodeJwsPayload,
  parseCompactJws,
} from './jose.ts';

export const ANDROID_PUBLISHER_SCOPE = 'https://www.googleapis.com/auth/androidpublisher';
export const GOOGLE_TOKEN_URI = 'https://oauth2.googleapis.com/token';
export const GOOGLE_OIDC_CERTS_URL = 'https://www.googleapis.com/oauth2/v3/certs';
export const GOOGLE_OIDC_ISSUERS: readonly string[] = ['accounts.google.com', 'https://accounts.google.com'];

const TOKEN_RESPONSE_MAX_BYTES = 16 * 1024;
const ACCESS_TOKEN_MAX_LENGTH = 4096;
const ACCESS_TOKEN_REFRESH_MARGIN_MS = 60_000;
const ASSERTION_LIFETIME_S = 3600;
const ACCESS_TOKEN_CACHE_MAX_ENTRIES = 8;

const OIDC_TOKEN_MAX_LENGTH = 8 * 1024;
const OIDC_CLOCK_SKEW_S = 60;
const JWKS_MAX_BYTES = 64 * 1024;
const JWKS_MAX_KEYS = 16;
const JWKS_TTL_DEFAULT_S = 300;
const JWKS_TTL_MIN_S = 60;
const JWKS_TTL_MAX_S = 6 * 3600;
/** An unknown kid refetches the JWKS (key rotation), at most once a minute. */
const JWKS_REFETCH_ON_MISS_AFTER_MS = 60_000;

const RS256 = { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' } as const;
const PEM_BEGIN = '-----BEGIN PRIVATE KEY-----';
const PEM_END = '-----END PRIVATE KEY-----';

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function encodeJson(value: unknown): string {
  return bytesToBase64Url(new TextEncoder().encode(JSON.stringify(value)));
}

function discard(response: Response): void {
  void response.body?.cancel().catch(() => {});
}

// ---------------------------------------------------------------------------
// (a) Service-account access token

export interface ServiceAccountKey {
  clientEmail: string;
  privateKeyId: string | null;
  privateKeyPem: string;
  tokenUri: string;
}

/** The fields of a Google service-account key JSON; null when unusable. */
export function parseServiceAccountKey(json: string): ServiceAccountKey | null {
  let value: unknown;
  try {
    value = JSON.parse(json);
  } catch {
    return null;
  }
  if (!isRecord(value)) return null;
  const { client_email: clientEmail, private_key: privateKey, private_key_id: keyId } = value;
  const tokenUri = value.token_uri ?? GOOGLE_TOKEN_URI;
  if (typeof clientEmail !== 'string' || !/^[^\s@]{1,200}@[^\s@]{1,200}$/.test(clientEmail)) return null;
  if (typeof privateKey !== 'string' || privateKey.length > 16_384 || !privateKey.includes(PEM_BEGIN)) return null;
  if (typeof tokenUri !== 'string' || !isGoogleApiUrl(tokenUri)) return null;
  return {
    clientEmail,
    privateKeyId: typeof keyId === 'string' && /^[A-Za-z0-9_-]{1,100}$/.test(keyId) ? keyId : null,
    privateKeyPem: privateKey,
    tokenUri,
  };
}

/** The assertion is a bearer credential: only send it to Google over https. */
function isGoogleApiUrl(text: string): boolean {
  try {
    const url = new URL(text);
    return url.protocol === 'https:' && !url.username && !url.password &&
      (url.hostname === 'oauth2.googleapis.com' || url.hostname.endsWith('.googleapis.com'));
  } catch {
    return false;
  }
}

function pkcs8FromPem(pem: string): Bytes | null {
  const start = pem.indexOf(PEM_BEGIN);
  const end = pem.indexOf(PEM_END);
  if (start < 0 || end <= start) return null;
  // Tolerates a key pasted with literal "\n" escapes.
  const body = pem.slice(start + PEM_BEGIN.length, end).replace(/\\n/g, '').replace(/\s+/g, '');
  return base64ToBytes(body);
}

export type GoogleAccessTokenResult =
  | { ok: true; accessToken: string }
  /** invalid_key: the key JSON or PEM is unusable (configuration);
   *  rejected: the token endpoint refused the grant (4xx);
   *  unavailable: network, timeout, 5xx/429 or an unreadable answer. */
  | { ok: false; reason: 'invalid_key' | 'rejected' | 'unavailable' };

export interface GoogleAccessTokenOptions {
  signal: AbortSignal;
  scope?: string;
  /** Defaults to Date.now(); tests pass a fixed instant. */
  nowMs?: number;
}

const accessTokens = new Map<string, { token: string; refreshAtMs: number }>();

export async function googleAccessToken(
  serviceAccountJson: string,
  options: GoogleAccessTokenOptions,
): Promise<GoogleAccessTokenResult> {
  const nowMs = options.nowMs ?? Date.now();
  const scope = options.scope ?? ANDROID_PUBLISHER_SCOPE;
  const key = parseServiceAccountKey(serviceAccountJson);
  if (!key) return { ok: false, reason: 'invalid_key' };
  const cacheKey = [key.clientEmail, key.privateKeyId ?? '', key.tokenUri, scope].join('\n');
  const cached = accessTokens.get(cacheKey);
  if (cached && nowMs < cached.refreshAtMs) return { ok: true, accessToken: cached.token };

  let assertion: string;
  try {
    const pkcs8 = pkcs8FromPem(key.privateKeyPem);
    if (!pkcs8) return { ok: false, reason: 'invalid_key' };
    const signingKey = await crypto.subtle.importKey('pkcs8', pkcs8, RS256, false, ['sign']);
    const iat = Math.floor(nowMs / 1000);
    const header = key.privateKeyId
      ? { alg: 'RS256', typ: 'JWT', kid: key.privateKeyId }
      : { alg: 'RS256', typ: 'JWT' };
    const claims = { iss: key.clientEmail, scope, aud: key.tokenUri, iat, exp: iat + ASSERTION_LIFETIME_S };
    const signingInput = `${encodeJson(header)}.${encodeJson(claims)}`;
    const signature = await crypto.subtle.sign(RS256, signingKey, new TextEncoder().encode(signingInput));
    assertion = `${signingInput}.${bytesToBase64Url(new Uint8Array(signature))}`;
  } catch {
    return { ok: false, reason: 'invalid_key' };
  }

  let response: Response;
  try {
    response = await fetch(key.tokenUri, {
      method: 'POST',
      headers: { 'content-type': 'application/x-www-form-urlencoded', accept: 'application/json' },
      body: new URLSearchParams({ grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer', assertion }).toString(),
      redirect: 'error',
      signal: options.signal,
    });
  } catch {
    return { ok: false, reason: 'unavailable' };
  }
  if (!response.ok) {
    discard(response);
    const rejected = response.status === 400 || response.status === 401 || response.status === 403;
    return { ok: false, reason: rejected ? 'rejected' : 'unavailable' };
  }
  let text: string | null;
  try {
    text = await readProviderBody(response, TOKEN_RESPONSE_MAX_BYTES, options.signal);
  } catch {
    return { ok: false, reason: 'unavailable' };
  }
  let body: unknown;
  try {
    body = text === null ? null : JSON.parse(text);
  } catch {
    body = null;
  }
  if (!isRecord(body)) return { ok: false, reason: 'unavailable' };
  const { access_token: accessToken, expires_in: expiresIn, token_type: tokenType } = body;
  if (
    typeof accessToken !== 'string' || accessToken.length === 0 || accessToken.length > ACCESS_TOKEN_MAX_LENGTH ||
    !/^[\x21-\x7e]+$/.test(accessToken) ||
    typeof expiresIn !== 'number' || !Number.isFinite(expiresIn) || expiresIn <= 0 || expiresIn > 86_400 ||
    (tokenType !== undefined && (typeof tokenType !== 'string' || tokenType.toLowerCase() !== 'bearer'))
  ) {
    return { ok: false, reason: 'unavailable' };
  }
  if (accessTokens.size >= ACCESS_TOKEN_CACHE_MAX_ENTRIES) accessTokens.clear();
  accessTokens.set(cacheKey, {
    token: accessToken,
    refreshAtMs: nowMs + expiresIn * 1000 - ACCESS_TOKEN_REFRESH_MARGIN_MS,
  });
  return { ok: true, accessToken };
}

// ---------------------------------------------------------------------------
// (b) Google OIDC token of a Pub/Sub push

export type GoogleOidcFailure =
  | 'not_configured' // expected audience or email is empty
  | 'malformed'
  | 'algorithm' // header alg is not RS256
  | 'jwks_unavailable'
  | 'key' // no JWKS key with the token's kid
  | 'signature'
  | 'issuer'
  | 'audience'
  | 'email' // email differs or email_verified is not true
  | 'expired'
  | 'issued_in_future';

export type GoogleOidcResult =
  | { ok: true; claims: Record<string, unknown> }
  | { ok: false; reason: GoogleOidcFailure };

export interface GoogleOidcOptions {
  /** The push subscription's audience (EATOVA_PUBSUB_PUSH_AUDIENCE). */
  audience: string;
  /** The push service account (EATOVA_PUBSUB_PUSH_SA_EMAIL). */
  email: string;
  signal: AbortSignal;
  /** Defaults to Date.now(); tests pass a fixed instant. */
  nowMs?: number;
}

interface JwksCache {
  keys: Map<string, CryptoKey>;
  fetchedAtMs: number;
  expiresAtMs: number;
}

let jwksCache: JwksCache | null = null;

export async function verifyGoogleOidcToken(token: string, options: GoogleOidcOptions): Promise<GoogleOidcResult> {
  const nowMs = options.nowMs ?? Date.now();
  if (!options.audience || !options.email) return oidcFail('not_configured');
  const jws = parseCompactJws(token, OIDC_TOKEN_MAX_LENGTH);
  if (!jws) return oidcFail('malformed');
  if (jws.header.alg !== 'RS256') return oidcFail('algorithm');
  const kid = jws.header.kid;
  if ('crit' in jws.header || typeof kid !== 'string' || kid.length === 0 || kid.length > 200) {
    return oidcFail('malformed');
  }
  const key = await jwksKey(kid, options.signal, nowMs);
  if (key === 'unavailable') return oidcFail('jwks_unavailable');
  if (key === 'missing') return oidcFail('key');
  let signatureOk = false;
  try {
    signatureOk = await crypto.subtle.verify(RS256, key, jws.signature, jws.signingInput);
  } catch {
    signatureOk = false;
  }
  if (!signatureOk) return oidcFail('signature');

  const claims = decodeJwsPayload(jws);
  if (!claims) return oidcFail('malformed');
  const { iss, aud, email, email_verified: emailVerified, exp, iat } = claims;
  if (typeof iss !== 'string' || !GOOGLE_OIDC_ISSUERS.includes(iss)) return oidcFail('issuer');
  if (aud !== options.audience) return oidcFail('audience');
  if (email !== options.email || emailVerified !== true) return oidcFail('email');
  if (typeof exp !== 'number' || typeof iat !== 'number' || !Number.isFinite(exp) || !Number.isFinite(iat)) {
    return oidcFail('malformed');
  }
  const nowS = nowMs / 1000;
  if (nowS >= exp + OIDC_CLOCK_SKEW_S) return oidcFail('expired');
  if (iat > nowS + OIDC_CLOCK_SKEW_S) return oidcFail('issued_in_future');
  return { ok: true, claims };
}

function oidcFail(reason: GoogleOidcFailure): GoogleOidcResult {
  return { ok: false, reason };
}

async function jwksKey(
  kid: string,
  signal: AbortSignal,
  nowMs: number,
): Promise<CryptoKey | 'missing' | 'unavailable'> {
  let cache = jwksCache && nowMs < jwksCache.expiresAtMs ? jwksCache : await fetchJwks(signal, nowMs);
  if (!cache) return 'unavailable';
  let key = cache.keys.get(kid);
  if (!key && nowMs - cache.fetchedAtMs >= JWKS_REFETCH_ON_MISS_AFTER_MS) {
    cache = await fetchJwks(signal, nowMs);
    key = cache?.keys.get(kid);
  }
  return key ?? 'missing';
}

async function fetchJwks(signal: AbortSignal, nowMs: number): Promise<JwksCache | null> {
  let response: Response;
  try {
    response = await fetch(GOOGLE_OIDC_CERTS_URL, {
      method: 'GET',
      headers: { accept: 'application/json' },
      redirect: 'error',
      signal,
    });
  } catch {
    return null;
  }
  if (!response.ok) {
    discard(response);
    return null;
  }
  let body: unknown = null;
  try {
    const text = await readProviderBody(response, JWKS_MAX_BYTES, signal);
    body = text === null ? null : JSON.parse(text);
  } catch {
    return null;
  }
  if (!isRecord(body) || !Array.isArray(body.keys)) return null;
  const keys = new Map<string, CryptoKey>();
  for (const jwk of body.keys.slice(0, JWKS_MAX_KEYS)) {
    const imported = await importRs256Jwk(jwk);
    if (imported && !keys.has(imported.kid)) keys.set(imported.kid, imported.key);
  }
  if (keys.size === 0) return null;
  const ttlS = cacheTtlSeconds(response.headers.get('cache-control'));
  jwksCache = { keys, fetchedAtMs: nowMs, expiresAtMs: nowMs + ttlS * 1000 };
  return jwksCache;
}

async function importRs256Jwk(jwk: unknown): Promise<{ kid: string; key: CryptoKey } | null> {
  if (!isRecord(jwk) || jwk.kty !== 'RSA') return null;
  const { kid, n, e, alg, use } = jwk;
  if (typeof kid !== 'string' || kid.length === 0 || kid.length > 200) return null;
  if ((alg !== undefined && alg !== 'RS256') || (use !== undefined && use !== 'sig')) return null;
  if (typeof n !== 'string' || n.length > 1024 || !base64UrlToBytes(n)) return null;
  if (typeof e !== 'string' || e.length > 16 || !base64UrlToBytes(e)) return null;
  try {
    const key = await crypto.subtle.importKey('jwk', { kty: 'RSA', n, e, alg: 'RS256', ext: true }, RS256, false, [
      'verify',
    ]);
    if ((key.algorithm as RsaHashedKeyAlgorithm).modulusLength < 2048) return null;
    return { kid, key };
  } catch {
    return null;
  }
}

function cacheTtlSeconds(cacheControl: string | null): number {
  if (!cacheControl) return JWKS_TTL_DEFAULT_S;
  if (/(?:^|,)\s*(?:no-store|no-cache)\s*(?:,|$)/i.test(cacheControl)) return JWKS_TTL_MIN_S;
  const match = /(?:^|,)\s*max-age\s*=\s*"?(\d{1,10})"?\s*(?:,|$)/i.exec(cacheControl);
  if (!match) return JWKS_TTL_DEFAULT_S;
  return Math.min(JWKS_TTL_MAX_S, Math.max(JWKS_TTL_MIN_S, Number(match[1])));
}

/** Drops the cached access tokens and JWKS (tests; a handler after a 401). */
export function clearGoogleAuthCaches(): void {
  accessTokens.clear();
  jwksCache = null;
}
