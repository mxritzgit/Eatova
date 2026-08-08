// Liefert der App die Zugangsdaten des eigenen Meilisearch-Mirrors
// (Basis-URL + Search-only-Key) zur LAUFZEIT.
//
// Warum es diese Function gibt: der Key steckte bis 2026-08-07 als
// `String.fromEnvironment`-Default im Binary. Ein einkompilierter Key laesst
// sich nicht rotieren — beim Wechsel waere jeder bereits installierte Build
// auf einen Schlag von der Suche abgeschnitten (still, weil der
// FallbackProductService klaglos auf OpenFoodFacts umschwenkt). Ueber diesen
// Endpunkt holt der Client den aktuellen Key nach und ersetzt ihn beim
// naechsten 403 des Mirrors innerhalb einer einzigen Suche.
//
// URL und Key reisen ZUSAMMEN: ein Umzug des Mirrors ist damit ein einziges
// Secret-Update und kann nie im Zustand "neue URL, alter Key" haengen.
//
// JWT-Pflicht ist unproblematisch: die Produktsuche laeuft ausschliesslich
// post-login (main.dart initialisiert Supabase vor runApp, der gesamte
// App-Body haengt hinter dem AuthGate). Einen anonymen Suchpfad gibt es nicht.
// Es wird KEINE config.toml angelegt — der Plattform-Default
// `verify_jwt = true` gilt bereits.

import { clientIpSubject } from '../_shared/client_ip.ts';
import { positiveIntFromEnv } from '../_shared/env.ts';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? '';
const SUPABASE_ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY') ?? '';
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';

// Kill-Switch-Sentinel. Steht das Secret exakt auf 'disabled', bekommt der
// Client leere Credentials und schaltet den Mirror hart ab (direkt OFF).
//
// Ein FEHLENDES Secret ist ausdruecklich KEIN Kill-Switch, sondern eine
// Fehlkonfiguration (500). Der Unterschied ist wichtig: bei 500 behaelt der
// Client seinen funktionierenden Compile-Time-Default, statt die Mirror-Suche
// wegen eines vergessenen `secrets set` still zu verlieren.
const KILL_SWITCH = 'disabled';
const MIRROR_SEARCH_KEY = (Deno.env.get('EATOVA_MIRROR_SEARCH_KEY') ?? '').trim();
const MIRROR_BASE_URL = (Deno.env.get('EATOVA_MIRROR_BASE_URL') ?? 'https://eatova.de/meili').trim();

// TTL-Grenzen (der Client klemmt identisch nach). Die TTL ist NICHT der
// Rotations-Mechanismus — das ist der 403-Pfad im Client. Ihr einziger Job
// ist, einen Wechsel der Basis-URL zu verbreiten: der erzeugt
// Verbindungsfehler statt 403 und kann sich deshalb nicht selbst heilen.
const MIN_TTL_SECONDS = 3_600;
const MAX_TTL_SECONDS = 604_800;
const DEFAULT_TTL_SECONDS = 43_200;
const TTL_SECONDS = clampTtl(Deno.env.get('EATOVA_SEARCH_KEY_TTL_SECONDS'));

const ALLOWED_ORIGINS = (Deno.env.get('EATOVA_ALLOWED_ORIGINS') ?? '')
  .split(',')
  .map((origin) => origin.trim())
  .filter(Boolean);

// Grosszuegig genug fuer App-Starts hinter einem Carrier-NAT, eng genug, dass
// niemand den Endpunkt als Key-Orakel durchprobiert.
//
// Sentinel-Rest E8: als einzige Function nutzte search-key hier noch das
// nackte `Number(...)`-Muster — ein Tippfehler im Secret wurde zu NaN ->
// JSON `null` -> SQL-Guard wirft -> jeder Request `rate_limit_unavailable`
// (genau die Klasse, die _shared/env.ts fuer die anderen schon schliesst).
const IP_LIMIT = positiveIntFromEnv('SEARCH_KEY_IP_LIMIT', 120);
const IP_WINDOW_SECONDS = positiveIntFromEnv('SEARCH_KEY_IP_WINDOW_SECONDS', 600);
// 20/h/User: ein gesunder Client holt den Key ~2x taeglich (TTL 12 h) plus
// einmal pro Rotation. Alles darueber ist eine Schleife.
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
    // Nicht `.split(',')[0]` des x-forwarded-for: Cloudflare HAENGT an, der
    // linkeste Eintrag ist also der vom Client selbst gesetzte. Begruendung,
    // Normalisierung und der uid-Fallback: ../_shared/client_ip.ts.
    const ipSubject = clientIpSubject(request, user.id);

    const ipLimit = await consumeRateLimit('search-key:ip', ipSubject, IP_LIMIT, IP_WINDOW_SECONDS);
    if (!ipLimit.allowed) {
      return rateLimitedResponse(request, ipLimit, requestId);
    }

    const userLimit = await consumeRateLimit('search-key:user', user.id, USER_LIMIT, USER_WINDOW_SECONDS);
    if (!userLimit.allowed) {
      return rateLimitedResponse(request, userLimit, requestId);
    }

    // Opportunistic cleanup; ignore failures so user requests are not blocked.
    void pruneRateLimits();

    const disabled = MIRROR_SEARCH_KEY === KILL_SWITCH;
    // NIEMALS den Key loggen. Nur, ob ausgeliefert wurde.
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
        // Bewusste Ausnahme vom Haus-'no-store': das hier ist geteilte
        // KONFIGURATION, kein nutzerspezifischer Inhalt — jeder angemeldete
        // Client bekommt exakt dieselbe Antwort. Der Body traegt aber einen
        // Credential, also darf er NIE in einen geteilten Cache: 'private'
        // erlaubt ausschliesslich den Browser-/Client-Cache.
        // max-age == ttlSeconds, damit HTTP-Cache und Client-TTL nicht
        // auseinanderlaufen.
        'cache-control': `private, max-age=${TTL_SECONDS}`,
        // Authorization gehoert in den Cache-Key: die Antwort haengt an einem
        // gueltigen Token, ein anderer Nutzer darf keinen Treffer erben.
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
  // Fehlend/leer = Fehlkonfiguration, NICHT Kill-Switch (siehe KILL_SWITCH).
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
  // Der Anon-Key ist KEIN Nutzer-Token. Ohne diese Zeile koennte jeder mit dem
  // (oeffentlichen) Anon-Key den Search-Key abholen.
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
  // Sentinel-Rest E6: `data.allowed === true` machte aus einem kaputten
  // Antwort-Shape (RPC-Signaturaenderung, Proxy-Body) ein `allowed: false` —
  // ein 429 samt erfundener rateLimit-Zahlen, obwohl nie ein Limit gemessen
  // wurde. Ein kaputter Shape ist ein Ausfall des Limiters, kein Limit.
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

async function pruneRateLimits() {
  await fetch(`${SUPABASE_URL}/rest/v1/rpc/prune_edge_rate_limits`, {
    method: 'POST',
    headers: {
      apikey: SUPABASE_SERVICE_ROLE_KEY,
      authorization: `Bearer ${SUPABASE_SERVICE_ROLE_KEY}`,
      'content-type': 'application/json',
    },
    body: '{}',
  });
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
      // Fehler-Antworten behalten damit das 'no-store' aus responseHeaders();
      // nur der 200er ueberschreibt es oben bewusst.
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
