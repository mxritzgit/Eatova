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

import { clientIpSubject } from '../_shared/client_ip.ts';
import { positiveIntFromEnv } from '../_shared/env.ts';
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
const IP_LIMIT = positiveIntFromEnv('SEARCH_KEY_IP_LIMIT', 120);
const IP_WINDOW_SECONDS = positiveIntFromEnv('SEARCH_KEY_IP_WINDOW_SECONDS', 600);
// 20/h/user: a healthy client fetches the key ~2x daily (TTL 12 h) plus once
// per rotation. Anything above that is a loop.
const USER_LIMIT = positiveIntFromEnv('SEARCH_KEY_USER_LIMIT', 20);
const USER_WINDOW_SECONDS = positiveIntFromEnv('SEARCH_KEY_USER_WINDOW_SECONDS', 3600);

type AuthUser = { id: string; email?: string };
type RateLimitResult = {
  allowed: boolean;
  limit: number;
  remaining: number;
  resetAt: string;
  windowSeconds: number;
};

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

    const user = await authenticateUser(request);
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
    // NEVER log the key. Only whether one was issued.
    console.log('search-key issued', { requestId, disabled, ttlSeconds: TTL_SECONDS });

    return jsonResponse(
      request,
      {
        mirrorBaseUrl: disabled ? '' : MIRROR_BASE_URL,
        searchKey: disabled ? '' : MIRROR_SEARCH_KEY,
        ttlSeconds: TTL_SECONDS,
        requestId,
      },
      200,
      {
        // Deliberate exception from the house 'no-store': this is shared
        // CONFIGURATION, identical for every signed-in client. The body carries
        // a credential though, so it must never reach a shared cache —
        // 'private' allows the browser/client cache only. max-age == ttlSeconds
        // keeps HTTP cache and client TTL in step.
        'cache-control': `private, max-age=${TTL_SECONDS}`,
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
}

function clampTtl(raw: string | undefined): number {
  const parsed = Number(raw ?? DEFAULT_TTL_SECONDS);
  if (!Number.isFinite(parsed) || parsed <= 0) return DEFAULT_TTL_SECONDS;
  return Math.round(Math.min(MAX_TTL_SECONDS, Math.max(MIN_TTL_SECONDS, parsed)));
}

async function authenticateUser(request: Request): Promise<AuthUser> {
  const authorization = request.headers.get('authorization') ?? '';
  const match = authorization.match(/^Bearer\s+(.+)$/i);
  if (!match) {
    throw new HttpError(401, 'missing_bearer_token', 'Bitte erneut anmelden.');
  }

  const token = match[1].trim();
  // The anon key is NOT a user token — without this anyone holding the public
  // anon key could fetch the search key.
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
    throw new HttpError(401, 'invalid_user_token', 'Bitte erneut anmelden.');
  }

  const user = await response.json() as Partial<AuthUser>;
  if (typeof user.id !== 'string' || user.id.length < 10) {
    throw new HttpError(401, 'invalid_user_token', 'Bitte erneut anmelden.');
  }
  return { id: user.id, email: typeof user.email === 'string' ? user.email : undefined };
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
