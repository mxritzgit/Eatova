// HTTP plumbing every edge function shares: security headers, the exact-origin
// CORS rule, JSON responses and the public error type. The CORS contract is
// pinned for all handlers by cors_origin_contract_test.ts.

/** Response headers of every answer, error or not. */
const SECURITY_HEADERS: Readonly<Record<string, string>> = {
  'cache-control': 'no-store',
  'x-content-type-options': 'nosniff',
  'x-frame-options': 'DENY',
  'referrer-policy': 'no-referrer',
  'permissions-policy': 'camera=(), microphone=(), geolocation=()',
  'content-security-policy': "default-src 'none'; frame-ancestors 'none'; base-uri 'none'",
};

export const CORS_ALLOW_HEADERS = 'authorization, apikey, content-type, x-client-info';

/**
 * EATOVA_ALLOWED_ORIGINS as a list of exact origins. Unset means no browser
 * origin is allowed; the native app sends none.
 */
export function allowedOriginsFromEnv(): string[] {
  return (Deno.env.get('EATOVA_ALLOWED_ORIGINS') ?? '')
    .split(',')
    .map((origin) => origin.trim())
    .filter(Boolean);
}

/**
 * The request's Origin if it is on the list, else null. Exact match only: no
 * suffix, scheme or port tolerance, no `null` origin, no wildcard.
 */
export function allowedOrigin(request: Request | undefined, origins: readonly string[]): string | null {
  const origin = request?.headers.get('origin');
  return origin && origins.includes(origin) ? origin : null;
}

export interface ResponseHeaderOptions {
  /** Access-Control-Allow-Methods, e.g. 'POST, OPTIONS'. */
  methods: string;
  origins: readonly string[];
}

/**
 * Security and CORS headers for one response. Without a request (or with a
 * foreign origin) no Allow-Origin is set. Never sets Allow-Credentials:
 * authentication is a bearer token, not a cookie.
 */
export function responseHeaders(request: Request | undefined, options: ResponseHeaderOptions): Headers {
  const headers = new Headers(SECURITY_HEADERS);
  headers.set('access-control-allow-methods', options.methods);
  headers.set('access-control-allow-headers', CORS_ALLOW_HEADERS);
  headers.set('access-control-max-age', '86400');
  const origin = allowedOrigin(request, options.origins);
  if (origin) {
    headers.set('access-control-allow-origin', origin);
    headers.set('vary', 'Origin');
  }
  return headers;
}

/** JSON body on `headers`; `extraHeaders` win over both. */
export function jsonResponse(
  body: unknown,
  status: number,
  headers: Headers,
  extraHeaders: HeadersInit = {},
): Response {
  const merged = new Headers(headers);
  merged.set('content-type', 'application/json; charset=utf-8');
  new Headers(extraHeaders).forEach((value, key) => merged.set(key, value));
  return new Response(JSON.stringify(body), { status, headers: merged });
}

/** An answer the client may see: status, stable code, user-facing text. */
export class HttpError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    readonly publicMessage: string,
  ) {
    super(code);
  }
}
