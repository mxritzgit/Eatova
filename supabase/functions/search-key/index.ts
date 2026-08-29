// Serves the app the credentials of our own Meilisearch mirror (base URL +
// search-only key) at RUNTIME.
//
// A compiled-in key cannot be rotated: a swap would cut every installed build
// off from search at once, silently, since FallbackProductService falls back to
// OpenFoodFacts. Via this endpoint the client refetches the current key and
// replaces it on the mirror's next 403 within a single search.
//
// URL and key travel TOGETHER, so moving the mirror is one secret update and
// can never hang in "new URL, old key".
//
// Requiring a JWT is fine: product search only runs post-login, behind the
// AuthGate. No config.toml is added — the platform default `verify_jwt = true`
// already applies.

import { authFailGate } from '../_shared/auth_fail_gate.ts';
import { clientIpSubject } from '../_shared/client_ip.ts';
import { EDGE_RATE_LIMIT_MAX_WINDOW_SECONDS, positiveIntFromEnv } from '../_shared/env.ts';
import { pruneRateLimits } from '../_shared/rate_limit_prune.ts';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? '';
const SUPABASE_ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY') ?? '';
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';

// Kill-switch sentinel. If the secret is exactly 'disabled', the client gets
// empty credentials and turns the mirror off (straight to OFF).
//
// A MISSING secret is explicitly NOT a kill switch but a misconfiguration
// (500): on 500 the client keeps its working compile-time default instead of
// silently losing mirror search to a forgotten `secrets set`.
const KILL_SWITCH = 'disabled';
const MIRROR_SEARCH_KEY = (Deno.env.get('EATOVA_MIRROR_SEARCH_KEY') ?? '').trim();
const MIRROR_BASE_URL = (Deno.env.get('EATOVA_MIRROR_BASE_URL') ?? 'https://eatova.de/meili').trim();

// Tenant-token mode (F9-02). The shared search key handed to every signed-in
// client had no expiry and could only be revoked by rotation. With
// EATOVA_MIRROR_KEY_UID set, `searchKey` becomes a Meilisearch tenant token
// instead: an HS256 JWT signed with the search key, scoped to the product
// index, expiring after ttlSeconds. The key itself never leaves the server.
//
// Operator setup:
//   1. `curl -H "Authorization: Bearer <MASTER_KEY>" https://<mirror>/keys`
//      and copy the `uid` of the search-only key whose `key` is stored in
//      EATOVA_MIRROR_SEARCH_KEY (the token is only valid for THAT key).
//   2. `supabase secrets set EATOVA_MIRROR_KEY_UID=<uid>`; optionally
//      EATOVA_MIRROR_SEARCH_INDEX if the client ever queries another index
//      (lib/src/services/meilisearch_product_service.dart uses `products`).
//   3. Unset the uid to fall back to the static key.
// The client treats the token like any key (`Authorization: Bearer`); an
// expired token yields 403, which is its existing refetch path.
const MIRROR_KEY_UID = (Deno.env.get('EATOVA_MIRROR_KEY_UID') ?? '').trim();
const MIRROR_SEARCH_INDEX = (Deno.env.get('EATOVA_MIRROR_SEARCH_INDEX') ?? '').trim() || 'products';
const TENANT_TOKEN_MODE = MIRROR_KEY_UID.length > 0;
// Token outlives the announced ttlSeconds by this much (see the issue site).
const TENANT_TOKEN_GRACE_SECONDS = 600;
// Meilisearch key uids are UUIDs, index uids are [a-zA-Z0-9_-]. Anything
// else would produce tokens the mirror rejects — a misconfiguration,
// surfaced as 500 like a missing key.
const KEY_UID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const INDEX_NAME_RE = /^[A-Za-z0-9_-]{1,64}$/;

// TTL bounds (the client clamps identically). The TTL is NOT the rotation
// mechanism — that is the client's 403 path. Its only job is to propagate a
// base-URL change, which causes connection errors instead of 403 and therefore
// cannot heal itself.
const MIN_TTL_SECONDS = 3_600;
const MAX_TTL_SECONDS = 604_800;
const DEFAULT_TTL_SECONDS = 43_200;
const TTL_SECONDS = clampTtl(Deno.env.get('EATOVA_SEARCH_KEY_TTL_SECONDS'));

const ALLOWED_ORIGINS = (Deno.env.get('EATOVA_ALLOWED_ORIGINS') ?? '')
  .split(',')
  .map((origin) => origin.trim())
  .filter(Boolean);

// Generous enough for app starts behind a carrier NAT, tight enough that nobody
// can use the endpoint as a key oracle. `positiveIntFromEnv` instead of bare
// `Number(...)`: a typo in the secret became NaN -> JSON `null` -> SQL guard
// throws -> every request `rate_limit_unavailable`.
//
// P6-03: WINDOWS pass EDGE_RATE_LIMIT_MAX_WINDOW_SECONDS explicitly. The
// default cap is the LIMIT bound (10000), so a window beyond ~2.8 h — a day
// window, say — silently fell back to the code default. Limits keep the
// default cap, which is their own RPC bound.
const IP_LIMIT = positiveIntFromEnv('SEARCH_KEY_IP_LIMIT', 120);
const IP_WINDOW_SECONDS = positiveIntFromEnv(
  'SEARCH_KEY_IP_WINDOW_SECONDS',
  600,
  EDGE_RATE_LIMIT_MAX_WINDOW_SECONDS,
);
// 20/h/user: a healthy client fetches the key ~2x daily (TTL 12 h) plus once
// per rotation. Anything above that is a loop.
const USER_LIMIT = positiveIntFromEnv('SEARCH_KEY_USER_LIMIT', 20);
const USER_WINDOW_SECONDS = positiveIntFromEnv(
  'SEARCH_KEY_USER_WINDOW_SECONDS',
  3600,
  EDGE_RATE_LIMIT_MAX_WINDOW_SECONDS,
);

type AuthUser = { id: string; email?: string };
type RateLimitResult = {
  allowed: boolean;
  limit: number;
  remaining: number;
  resetAt: string;
  windowSeconds: number;
};
/** authenticateUser either identifies the caller or, after too many failed
 *  introspections from one IP, asks for a 429 instead of the 401. */
type AuthOutcome = { user: AuthUser } | { rateLimited: RateLimitResult };

Deno.serve(async (request) => {
  const requestId = crypto.randomUUID();
  try {
    if (request.method === 'OPTIONS') {
      return new Response(null, { status: 204, headers: responseHeaders(request) });
    }

    if (request.method !== 'GET') {
      return jsonResponse(request, { error: 'method_not_allowed', requestId }, 405);
    }

    assertConfigured();

    const auth = await authenticateUser(request);
    if ('rateLimited' in auth) {
      return rateLimitedResponse(request, auth.rateLimited, requestId);
    }
    const user = auth.user;
    // Not `.split(',')[0]` of x-forwarded-for: Cloudflare APPENDS, so the
    // leftmost entry is client-controlled. See ../_shared/client_ip.ts.
    const ipSubject = clientIpSubject(request, user.id);

    const ipLimit = await consumeRateLimit('search-key:ip', ipSubject, IP_LIMIT, IP_WINDOW_SECONDS);
    if (!ipLimit.allowed) {
      return rateLimitedResponse(request, ipLimit, requestId);
    }

    const userLimit = await consumeRateLimit('search-key:user', user.id, USER_LIMIT, USER_WINDOW_SECONDS);
    if (!userLimit.allowed) {
      return rateLimitedResponse(request, userLimit, requestId);
    }

    // No await on purpose: cleanup must not hold up the request. Error handling
    // lives INSIDE the function (an unhandled rejection here would kill the
    // isolate) — see ../_shared/rate_limit_prune.ts.
    void pruneRateLimits({ supabaseUrl: SUPABASE_URL, serviceKey: SUPABASE_SERVICE_ROLE_KEY });

    const disabled = MIRROR_SEARCH_KEY === KILL_SWITCH;
    // NEVER log the key or token. Only whether one was issued and how.
    console.log('search-key issued', {
      requestId,
      disabled,
      ttlSeconds: TTL_SECONDS,
      tenantToken: TENANT_TOKEN_MODE,
    });

    // ttlSeconds stays the client's cache duration; the token itself lives
    // TENANT_TOKEN_GRACE_SECONDS longer, because the client keeps using an
    // expired entry while it refreshes in the background
    // (search_credentials.dart) — without the grace that search would 403.
    const searchKey = disabled
      ? ''
      : TENANT_TOKEN_MODE
      ? await issueTenantToken(Math.floor(Date.now() / 1000) + TTL_SECONDS + TENANT_TOKEN_GRACE_SECONDS)
      : MIRROR_SEARCH_KEY;

    return jsonResponse(
      request,
      {
        mirrorBaseUrl: disabled ? '' : MIRROR_BASE_URL,
        searchKey: searchKey,
        ttlSeconds: TTL_SECONDS,
        requestId,
      },
      200,
      {
        // Static mode: deliberate exception from the house 'no-store' — the
        // key is shared CONFIGURATION, identical for every signed-in client,
        // and 'private' keeps it out of shared caches while max-age ==
        // ttlSeconds keeps HTTP cache and client TTL in step.
        // Tenant mode: every response is a freshly minted, expiring token, so
        // nothing may be replayed from an HTTP cache.
        'cache-control': TENANT_TOKEN_MODE ? 'private, no-store' : `private, max-age=${TTL_SECONDS}`,
        // Authorization belongs in the cache key: another user must not inherit
        // a hit.
        'vary': 'Origin, Authorization',
      },
    );
  } catch (error) {
    console.error('search-key failed', {
      requestId,
      message: error instanceof Error ? error.message : String(error),
    });

    if (error instanceof HttpError) {
      return jsonResponse(request, { error: error.code, message: error.publicMessage, requestId }, error.status);
    }

    return jsonResponse(
      request,
      { error: 'internal_error', message: 'Suchkonfiguration gerade nicht verfügbar.', requestId },
      500,
    );
  }
});

function assertConfigured() {
  if (!SUPABASE_URL || !SUPABASE_ANON_KEY || !SUPABASE_SERVICE_ROLE_KEY) {
    throw new HttpError(500, 'server_misconfigured', 'Server-Konfiguration unvollständig.');
  }
  // Missing/empty = misconfiguration, NOT kill switch (see KILL_SWITCH).
  if (!MIRROR_SEARCH_KEY) {
    throw new HttpError(500, 'server_misconfigured', 'Suchkonfiguration unvollständig.');
  }
  if (!MIRROR_BASE_URL) {
    throw new HttpError(500, 'server_misconfigured', 'Suchkonfiguration unvollständig.');
  }
  if (TENANT_TOKEN_MODE && (!KEY_UID_RE.test(MIRROR_KEY_UID) || !INDEX_NAME_RE.test(MIRROR_SEARCH_INDEX))) {
    throw new HttpError(500, 'server_misconfigured', 'Suchkonfiguration unvollständig.');
  }
}

// Meilisearch tenant token: `header.payload.signature`, base64url without
// padding, HMAC-SHA256 over `header.payload` with the search key as secret
// (https://www.meilisearch.com/docs/learn/security/tenant_tokens). Web
// Crypto only — no dependency for three lines of JWT.
async function issueTenantToken(expUnixSeconds: number): Promise<string> {
  const header = base64url(new TextEncoder().encode(JSON.stringify({ alg: 'HS256', typ: 'JWT' })));
  const payload = base64url(new TextEncoder().encode(JSON.stringify({
    apiKeyUid: MIRROR_KEY_UID,
    searchRules: { [MIRROR_SEARCH_INDEX]: {} },
    exp: expUnixSeconds,
  })));
  const signingInput = `${header}.${payload}`;
  const key = await crypto.subtle.importKey(
    'raw',
    new TextEncoder().encode(MIRROR_SEARCH_KEY),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const signature = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(signingInput));
  return `${signingInput}.${base64url(new Uint8Array(signature))}`;
}

function base64url(bytes: Uint8Array): string {
  let binary = '';
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function clampTtl(raw: string | undefined): number {
  const parsed = Number(raw ?? DEFAULT_TTL_SECONDS);
  if (!Number.isFinite(parsed) || parsed <= 0) return DEFAULT_TTL_SECONDS;
  return Math.round(Math.min(MAX_TTL_SECONDS, Math.max(MIN_TTL_SECONDS, parsed)));
}

async function authenticateUser(request: Request): Promise<AuthOutcome> {
  const authorization = request.headers.get('authorization') ?? '';
  const match = authorization.match(/^Bearer\s+(.+)$/i);
  if (!match) {
    throw new HttpError(401, 'missing_bearer_token', 'Bitte erneut anmelden.');
  }

  const token = match[1].trim();
  // The anon key is NOT a user token — without this anyone holding the public
  // anon key could fetch the search key. Rejected LOCALLY: no roundtrip, no
  // fail bucket.
  if (!token || token === SUPABASE_ANON_KEY) {
    throw new HttpError(401, 'user_token_required', 'Bitte erneut anmelden.');
  }

  const response = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
    headers: {
      apikey: SUPABASE_ANON_KEY,
      authorization: `Bearer ${token}`,
    },
  });

  if (!response.ok) {
    // F-28-1: the lookup cost a GoTrue roundtrip, so failures are capped per
    // IP before the 401 — only here, never for the local rejections above or
    // the unusable-id case below. Rules in ../_shared/auth_fail_gate.ts.
    const gate = await authFailGate({
      supabaseUrl: SUPABASE_URL,
      serviceKey: SUPABASE_SERVICE_ROLE_KEY,
      scope: 'search-key:auth-fail',
      subject: clientIpSubject(request, 'anon'),
    });
    if (gate.limited) {
      return {
        rateLimited: {
          allowed: false,
          limit: gate.limit,
          remaining: gate.remaining,
          resetAt: gate.resetAt,
          windowSeconds: gate.windowSeconds,
        },
      };
    }
    throw new HttpError(401, 'invalid_user_token', 'Bitte erneut anmelden.');
  }

  const user = await response.json() as Partial<AuthUser>;
  if (typeof user.id !== 'string' || user.id.length < 10) {
    throw new HttpError(401, 'invalid_user_token', 'Bitte erneut anmelden.');
  }
  return { user: { id: user.id, email: typeof user.email === 'string' ? user.email : undefined } };
}

async function consumeRateLimit(
  scope: string,
  subject: string,
  limit: number,
  windowSeconds: number,
): Promise<RateLimitResult> {
  const response = await fetch(`${SUPABASE_URL}/rest/v1/rpc/consume_edge_rate_limit`, {
    method: 'POST',
    headers: {
      apikey: SUPABASE_SERVICE_ROLE_KEY,
      authorization: `Bearer ${SUPABASE_SERVICE_ROLE_KEY}`,
      'content-type': 'application/json',
    },
    body: JSON.stringify({
      p_scope: scope,
      p_subject: subject,
      p_limit: limit,
      p_window_seconds: windowSeconds,
    }),
  });

  if (!response.ok) {
    throw new HttpError(500, 'rate_limit_unavailable', 'Sicherheitslimit gerade nicht verfügbar.');
  }

  const data = await response.json() as Partial<RateLimitResult>;
  // E6: `data.allowed === true` turned a broken response shape (RPC signature
  // change, proxy body) into `allowed: false` — a 429 with invented numbers
  // although no limit was ever measured. A broken shape is a limiter outage,
  // not a limit.
  if (typeof data.allowed !== 'boolean') {
    console.error(`consume_edge_rate_limit: 200 ohne lesbares allowed (${JSON.stringify(data).slice(0, 120)})`);
    throw new HttpError(500, 'rate_limit_unavailable', 'Sicherheitslimit gerade nicht verfügbar.');
  }
  return {
    allowed: data.allowed,
    limit: Number(data.limit ?? limit),
    remaining: Number(data.remaining ?? 0),
    resetAt: String(data.resetAt ?? new Date(Date.now() + windowSeconds * 1000).toISOString()),
    windowSeconds: Number(data.windowSeconds ?? windowSeconds),
  };
}

function rateLimitedResponse(request: Request, limit: RateLimitResult, requestId: string): Response {
  const resetAt = new Date(limit.resetAt).getTime();
  const retryAfter = Number.isFinite(resetAt)
    ? Math.max(1, Math.ceil((resetAt - Date.now()) / 1000))
    : limit.windowSeconds;
  return jsonResponse(
    request,
    {
      error: 'rate_limited',
      message: 'Zu viele Anfragen. Bitte später erneut versuchen.',
      requestId,
      rateLimit: limit,
    },
    429,
    { 'retry-after': String(retryAfter) },
  );
}

function jsonResponse(
  request: Request,
  body: Record<string, unknown>,
  status: number,
  extraHeaders: HeadersInit = {},
): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...Object.fromEntries(responseHeaders(request)),
      'content-type': 'application/json; charset=utf-8',
      // Error responses keep the 'no-store' from responseHeaders(); only the
      // 200 overrides it deliberately above.
      ...extraHeaders,
    },
  });
}

function responseHeaders(request: Request): Headers {
  const headers = new Headers({
    'cache-control': 'no-store',
    'x-content-type-options': 'nosniff',
    'x-frame-options': 'DENY',
    'referrer-policy': 'no-referrer',
    'permissions-policy': 'camera=(), microphone=(), geolocation=()',
    'content-security-policy': "default-src 'none'; frame-ancestors 'none'; base-uri 'none'",
    'access-control-allow-methods': 'GET, OPTIONS',
    'access-control-allow-headers': 'authorization, apikey, content-type, x-client-info',
    'access-control-max-age': '86400',
  });

  const origin = request.headers.get('origin');
  if (origin && ALLOWED_ORIGINS.includes(origin)) {
    headers.set('access-control-allow-origin', origin);
    headers.set('vary', 'Origin');
  }

  return headers;
}

class HttpError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    readonly publicMessage: string,
  ) {
    super(code);
  }
}
