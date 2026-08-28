// End-to-end tests for handleRequest (handler.ts) with a stubbed fetch,
// covering the expensive paths: auth (401), both rate-limit gates (429 / 500
// on limiter failure) and the image size/type checks (413 / 415).
//
// This works without a server because handler.ts reads its secrets PER
// REQUEST, not at module load, so Deno.env.set in the test takes effect —
// hence `deno test --allow-env` (already in the workflow).
//
// No external test dependencies, same style as ../coach-chat/handler_test.ts.

import { handleRequest } from './handler.ts';

const USER_ID = '11111111-1111-4111-8111-111111111111';
const BASE_URL = 'https://supabase.test.invalid';
const ANON_KEY = 'test-anon-key';
const USER_JWT = 'test-user-jwt';

// Image payload of the tests. The function never DECODES the base64 — it
// forwards it as a data: URL and only checks the character set and estimated
// size. A PNG prefix plus padding suffices, but it must exceed
// MIN_IMAGE_BYTES (128 bytes = 171 base64 chars) or image_too_small fires
// instead of the path under test.
const IMAGE_BASE64 = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ' + 'A'.repeat(200);

// Over MAX_IMAGE_BYTES (5 MB): estimatedBytes = floor(len * 0.75), so more
// than 6,666,666 chars are needed while the JSON body stays under
// MAX_CONTENT_LENGTH (7 MB) — otherwise the body cap would fire first.
const OVERSIZED_IMAGE_BASE64 = 'A'.repeat(6_700_000);
// Over MAX_CONTENT_LENGTH (7 MB) including the JSON frame.
const OVERSIZED_BODY_IMAGE_BASE64 = 'A'.repeat(7_200_000);

// The model's response on success. The numbers are consistent
// (780 * 100 / 300 = 260) so the mismatch warner in normalize.ts stays quiet.
const MODEL_RESULT = {
  mealName: 'Steak mit Kartoffeln',
  caloriesKcal: 780,
  estimatedGrams: 300,
  kcalPer100G: 260,
  proteinG: 45,
  carbsG: 30,
  fatG: 40,
  confidence: 'high',
  explanation: 'Teller als Referenz.',
  items: [
    { name: 'Steak', grams: 180, caloriesKcal: 450, kcalPer100G: 250 },
    { name: 'Kartoffeln', grams: 120, caloriesKcal: 330, kcalPer100G: 275 },
  ],
};

Deno.env.set('SUPABASE_URL', BASE_URL);
Deno.env.set('SUPABASE_ANON_KEY', ANON_KEY);
Deno.env.set('SUPABASE_SERVICE_ROLE_KEY', 'test-service-key');
Deno.env.set('OPENROUTER_API_KEY', 'test-openrouter-key');

type JsonRecord = Record<string, unknown>;

interface RecordedCall {
  url: string;
  method: string;
  body: string;
  headers: Headers;
}

interface StubOptions {
  /** HTTP status of the /auth/v1/user lookup (auth failure simulation). */
  authStatus?: number;
  /**
   * Body of the /auth/v1/user lookup — for the 200-with-unusable-id case: an
   * auth server that answers but yields no usable identity.
   */
  authBody?: JsonRecord;
  /** Answer of the IP gate (default: allowed). */
  ipAllowed?: boolean;
  /** Answer of the global day gate (default: allowed). */
  globalAllowed?: boolean;
  /** Answer of the per-user day gate (default: allowed). */
  userDayAllowed?: boolean;
  /** Answer of the hourly user gate (default: allowed). */
  userAllowed?: boolean;
  /**
   * consume_edge_rate_limit answers 200 but without a readable `allowed`
   * (E6): a limiter outage, not a measured limit.
   */
  rateLimitBroken?: boolean;
  /**
   * Budget of the analyze-meal:auth-fail bucket (F-28-1). The stub mirrors
   * the real RPC's atomic check+increment: every consume counts up, then
   * allowed=false. Unset: allowed without counting.
   */
  authFailBudget?: number;
  /** HTTP status of the consume for the auth-fail scope (limiter outage). */
  authFailGateStatus?: number;
}

interface FetchStub {
  calls: RecordedCall[];
  openRouterBodies: JsonRecord[];
  callsTo(fragment: string): RecordedCall[];
  /** Scopes of the consume_edge_rate_limit calls, in call order. */
  rateLimitScopes(): string[];
  /** Parameters of the consume_edge_rate_limit call for `scope`. */
  rateLimitParams(scope: string): JsonRecord | undefined;
  restore(): void;
}

/** Gate order since F9-01: abuse hits its originator first; the global bill
 *  cap counts only requests that would actually trigger a paid call. */
const GATE_ORDER = 'analyze-meal:ip,analyze-meal:user-day,analyze-meal:user,analyze-meal:global';

function assert(condition: boolean, message: string): void {
  if (!condition) throw new Error(message);
}

function assertEquals(actual: unknown, expected: unknown, message: string): void {
  if (actual !== expected) {
    throw new Error(
      `${message}: erwartet ${JSON.stringify(expected)}, war ${JSON.stringify(actual)}`,
    );
  }
}

function jsonRes(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { 'content-type': 'application/json' },
  });
}

function installFetch(options: StubOptions = {}): FetchStub {
  const calls: RecordedCall[] = [];
  const openRouterBodies: JsonRecord[] = [];
  const original = globalThis.fetch;
  let authFailConsumes = 0;

  function route(url: string, body: string): Response {
    if (url.includes('/auth/v1/user')) {
      if (options.authStatus !== undefined) {
        return jsonRes({ message: 'invalid token' }, options.authStatus);
      }
      return jsonRes(options.authBody ?? { id: USER_ID });
    }
    if (url.includes('/rest/v1/rpc/consume_edge_rate_limit')) {
      const params = JSON.parse(body) as JsonRecord;
      if (params.p_scope === 'analyze-meal:auth-fail') {
        if (options.authFailGateStatus !== undefined) {
          return jsonRes({ message: 'limiter down' }, options.authFailGateStatus);
        }
        // Atomic check+increment like the real RPC (migration
        // 20260518000100): the consume itself decides allowed.
        authFailConsumes++;
        const budget = options.authFailBudget ?? Number.POSITIVE_INFINITY;
        const windowSeconds = Number(params.p_window_seconds);
        return jsonRes({
          allowed: authFailConsumes <= budget,
          limit: Number(params.p_limit),
          remaining: Math.max(Number(params.p_limit) - authFailConsumes, 0),
          resetAt: new Date(Date.now() + windowSeconds * 1000).toISOString(),
          windowSeconds,
        });
      }
      if (options.rateLimitBroken) return jsonRes({ ok: true });
      const allowedByScope: Record<string, boolean | undefined> = {
        'analyze-meal:ip': options.ipAllowed,
        'analyze-meal:global': options.globalAllowed,
        'analyze-meal:user-day': options.userDayAllowed,
        'analyze-meal:user': options.userAllowed,
      };
      if (!(String(params.p_scope) in allowedByScope)) {
        throw new Error(`Unbekannter Rate-Limit-Scope im Test: ${String(params.p_scope)}`);
      }
      const allowed = allowedByScope[String(params.p_scope)] ?? true;
      const limit = Number(params.p_limit);
      const windowSeconds = Number(params.p_window_seconds);
      // Mirror limit/window from the request instead of hardcoding the
      // defaults: those come from positiveIntFromEnv at module load and the
      // test could no longer set them.
      return jsonRes({
        allowed,
        limit,
        remaining: allowed ? limit - 1 : 0,
        resetAt: new Date(Date.now() + windowSeconds * 1000).toISOString(),
        windowSeconds,
      });
    }
    if (url.includes('/rest/v1/rpc/prune_edge_rate_limits')) {
      return new Response(null, { status: 204 });
    }
    if (url.includes('openrouter.ai')) {
      openRouterBodies.push(JSON.parse(body) as JsonRecord);
      return jsonRes({
        choices: [{ message: { content: JSON.stringify(MODEL_RESULT) } }],
      });
    }
    throw new Error(`Unerwarteter fetch im Test: ${url}`);
  }

  globalThis.fetch = ((
    input: string | URL | Request,
    init?: RequestInit,
  ): Promise<Response> => {
    const url = typeof input === 'string'
      ? input
      : input instanceof URL
      ? input.toString()
      : input.url;
    const method = (init?.method ?? 'GET').toUpperCase();
    const body = typeof init?.body === 'string' ? init.body : '';
    calls.push({ url, method, body, headers: new Headers(init?.headers) });
    return Promise.resolve(route(url, body));
  }) as typeof globalThis.fetch;

  return {
    calls,
    openRouterBodies,
    callsTo: (fragment: string) => calls.filter((call) => call.url.includes(fragment)),
    rateLimitScopes: () =>
      calls
        .filter((call) => call.url.includes('/rpc/consume_edge_rate_limit'))
        .map((call) => String((JSON.parse(call.body) as JsonRecord).p_scope)),
    rateLimitParams: (scope: string) =>
      calls
        .filter((call) => call.url.includes('/rpc/consume_edge_rate_limit'))
        .map((call) => JSON.parse(call.body) as JsonRecord)
        .find((params) => params.p_scope === scope),
    restore: () => {
      globalThis.fetch = original;
    },
  };
}

interface RequestOptions {
  method?: string;
  /** null = omit the header (missing bearer token). */
  authorization?: string | null;
  contentType?: string | null;
  /** Sets cf-connecting-ip, the subject source of the IP-keyed gates. */
  ip?: string;
}

function makeRequest(payload: JsonRecord, options: RequestOptions = {}): Request {
  const headers: Record<string, string> = {};
  if (options.ip !== undefined) headers['cf-connecting-ip'] = options.ip;
  const authorization = options.authorization === undefined
    ? `Bearer ${USER_JWT}`
    : options.authorization;
  if (authorization !== null) headers.authorization = authorization;
  const contentType = options.contentType === undefined ? 'application/json' : options.contentType;
  if (contentType !== null) headers['content-type'] = contentType;

  const method = options.method ?? 'POST';
  const hasBody = method !== 'GET' && method !== 'OPTIONS';
  return new Request('https://edge.test.invalid/analyze-meal', {
    method,
    headers,
    body: hasBody ? JSON.stringify(payload) : undefined,
  });
}

// ---------------------------------------------------------------------------

Deno.test('OPTIONS -> 204 ohne jeden Roundtrip', async () => {
  const stub = installFetch();
  try {
    const res = await handleRequest(makeRequest({}, { method: 'OPTIONS' }));
    assertEquals(res.status, 204, 'Status');
    assertEquals(await res.text(), '', 'kein Body');
    assertEquals(stub.calls.length, 0, 'Roundtrips');
  } finally {
    stub.restore();
  }
});

Deno.test('GET -> 405 method_not_allowed', async () => {
  const stub = installFetch();
  try {
    const res = await handleRequest(makeRequest({}, { method: 'GET' }));
    assertEquals(res.status, 405, 'Status');
    const body = await res.json() as JsonRecord;
    assertEquals(body.error, 'method_not_allowed', 'Fehlercode');
    assertEquals(stub.calls.length, 0, 'Roundtrips');
  } finally {
    stub.restore();
  }
});

Deno.test('fehlender Authorization-Header -> 401 ohne Auth-Roundtrip', async () => {
  const stub = installFetch();
  try {
    const res = await handleRequest(makeRequest({ imageBase64: IMAGE_BASE64 }, { authorization: null }));
    assertEquals(res.status, 401, 'Status');
    const body = await res.json() as JsonRecord;
    assertEquals(body.error, 'missing_bearer_token', 'Fehlercode');
    // A request without a bearer header is decidable locally and must not
    // cost an auth lookup.
    assertEquals(stub.callsTo('/auth/v1/user').length, 0, 'Auth-Lookups');
  } finally {
    stub.restore();
  }
});

Deno.test('Anon-Key als Token -> 401 user_token_required, ohne Auth-Roundtrip', async () => {
  const stub = installFetch();
  try {
    const res = await handleRequest(
      makeRequest({ imageBase64: IMAGE_BASE64 }, { authorization: `Bearer ${ANON_KEY}` }),
    );
    assertEquals(res.status, 401, 'Status');
    const body = await res.json() as JsonRecord;
    assertEquals(body.error, 'user_token_required', 'Fehlercode');
    // The public anon key ships in every app copy: it is known locally and
    // must not trigger an auth roundtrip, otherwise the function could be
    // loaded anonymously with a publicly known value.
    assertEquals(stub.callsTo('/auth/v1/user').length, 0, 'Auth-Lookups');
  } finally {
    stub.restore();
  }
});

Deno.test('abgelehnter Token -> 401 invalid_user_token', async () => {
  const stub = installFetch({ authStatus: 401 });
  try {
    const res = await handleRequest(makeRequest({ imageBase64: IMAGE_BASE64 }));
    assertEquals(res.status, 401, 'Status');
    const body = await res.json() as JsonRecord;
    assertEquals(body.error, 'invalid_user_token', 'Fehlercode');
    assertEquals(stub.callsTo('/auth/v1/user').length, 1, 'Auth-Lookups');
    // Since F-28-1 the failed lookup itself is metered (fail bucket), but no
    // application gate runs without a verified user.
    assertEquals(
      stub.rateLimitScopes().join(','),
      'analyze-meal:auth-fail',
      'nur das Fail-Bucket nach fehlgeschlagener Auth',
    );
  } finally {
    stub.restore();
  }
});

Deno.test('Auth-200 ohne brauchbare User-Id -> 401 invalid_user_token', async () => {
  // An auth server that answers 200 without a usable identity must not count
  // as logged in — the id would otherwise land in the DB as rate-limit
  // subject.
  const stub = installFetch({ authBody: { id: 'kurz' } });
  try {
    const res = await handleRequest(makeRequest({ imageBase64: IMAGE_BASE64 }));
    assertEquals(res.status, 401, 'Status');
    const body = await res.json() as JsonRecord;
    assertEquals(body.error, 'invalid_user_token', 'Fehlercode');
    assertEquals(stub.rateLimitScopes().length, 0, 'kein Gate nach fehlgeschlagener Auth');
  } finally {
    stub.restore();
  }
});

Deno.test('IP-Limit erschoepft -> 429 mit retry-after, ohne bezahlten Provider-Call', async () => {
  const stub = installFetch({ ipAllowed: false });
  try {
    const res = await handleRequest(makeRequest({ imageBase64: IMAGE_BASE64 }));
    assertEquals(res.status, 429, 'Status');
    const body = await res.json() as JsonRecord;
    assertEquals(body.error, 'rate_limited', 'Fehlercode');
    assertEquals((body.rateLimit as JsonRecord).allowed, false, 'rateLimit.allowed');

    const retryAfter = Number(res.headers.get('retry-after'));
    assert(
      Number.isFinite(retryAfter) && retryAfter >= 1,
      `retry-after muss eine positive Sekundenzahl sein, war: ${res.headers.get('retry-after')}`,
    );

    assertEquals(stub.callsTo('openrouter.ai').length, 0, 'Provider-Calls');
    // After a rejected IP gate the user gate must not consume anything, or a
    // blocked IP would burn other users' budgets.
    assertEquals(stub.rateLimitScopes().join(','), 'analyze-meal:ip', 'Gate-Reihenfolge');
  } finally {
    stub.restore();
  }
});

Deno.test('User-Limit erschoepft -> 429 vor dem globalen Gate', async () => {
  const stub = installFetch({ userAllowed: false });
  try {
    const res = await handleRequest(makeRequest({ imageBase64: IMAGE_BASE64 }));
    assertEquals(res.status, 429, 'Status');
    const body = await res.json() as JsonRecord;
    assertEquals(body.error, 'rate_limited', 'Fehlercode');
    // A user over their hourly budget must not consume the shared bill cap.
    assertEquals(
      stub.rateLimitScopes().join(','),
      'analyze-meal:ip,analyze-meal:user-day,analyze-meal:user',
      'Gate-Reihenfolge',
    );
    assertEquals(stub.callsTo('openrouter.ai').length, 0, 'Provider-Calls');
  } finally {
    stub.restore();
  }
});

Deno.test('F9-01: globales Tageslimit erschoepft -> 429 als letztes Gate, kein Provider-Call', async () => {
  const stub = installFetch({ globalAllowed: false });
  try {
    const res = await handleRequest(makeRequest({ imageBase64: IMAGE_BASE64 }));
    assertEquals(res.status, 429, 'Status');
    const body = await res.json() as JsonRecord;
    assertEquals(body.error, 'rate_limited', 'Fehlercode');
    const limit = body.rateLimit as JsonRecord;
    assertEquals(limit.allowed, false, 'rateLimit.allowed');
    assertEquals(typeof limit.resetAt, 'string', 'rateLimit.resetAt');
    assert(Number(res.headers.get('retry-after')) >= 1, 'retry-after');
    // The bill cap is the last gate: it only counts requests that passed
    // every per-user budget, i.e. those that would have paid for a call.
    assertEquals(stub.rateLimitScopes().join(','), GATE_ORDER, 'Gate-Reihenfolge');
    assertEquals(stub.callsTo('openrouter.ai').length, 0, 'Provider-Calls');

    const params = stub.rateLimitParams('analyze-meal:global')!;
    assertEquals(params.p_subject, 'all', 'ein Bucket fuer alle Nutzer');
    assertEquals(params.p_limit, 5000, 'Default 5000/Tag');
    assertEquals(params.p_window_seconds, 86400, 'Tagesfenster');
  } finally {
    stub.restore();
  }
});

Deno.test('F9-01: User-Tageslimit erschoepft -> 429 direkt nach dem IP-Gate', async () => {
  const stub = installFetch({ userDayAllowed: false });
  try {
    const res = await handleRequest(makeRequest({ imageBase64: IMAGE_BASE64 }));
    assertEquals(res.status, 429, 'Status');
    const body = await res.json() as JsonRecord;
    assertEquals(body.error, 'rate_limited', 'Fehlercode');
    assertEquals(
      stub.rateLimitScopes().join(','),
      'analyze-meal:ip,analyze-meal:user-day',
      'Gate-Reihenfolge',
    );
    assertEquals(stub.callsTo('openrouter.ai').length, 0, 'Provider-Calls');

    const params = stub.rateLimitParams('analyze-meal:user-day')!;
    assertEquals(params.p_subject, USER_ID, 'Subject ist der Nutzer');
    assertEquals(params.p_limit, 100, 'Default 100/Tag');
    assertEquals(params.p_window_seconds, 86400, 'Tagesfenster');
  } finally {
    stub.restore();
  }
});

Deno.test('Limiter antwortet 200 ohne allowed -> 500 rate_limit_unavailable', async () => {
  // E6: a broken response shape is a limiter OUTAGE, not a measured limit —
  // the request must not slip through.
  const stub = installFetch({ rateLimitBroken: true });
  try {
    const res = await handleRequest(makeRequest({ imageBase64: IMAGE_BASE64 }));
    assertEquals(res.status, 500, 'Status');
    const body = await res.json() as JsonRecord;
    assertEquals(body.error, 'rate_limit_unavailable', 'Fehlercode');
    assertEquals(stub.callsTo('openrouter.ai').length, 0, 'Provider-Calls');
  } finally {
    stub.restore();
  }
});

Deno.test('zu grosses Bild -> 413 image_too_large, ohne bezahlten Provider-Call', async () => {
  const stub = installFetch();
  try {
    const res = await handleRequest(makeRequest({ imageBase64: OVERSIZED_IMAGE_BASE64 }));
    assertEquals(res.status, 413, 'Status');
    const body = await res.json() as JsonRecord;
    assertEquals(body.error, 'image_too_large', 'Fehlercode');
    assertEquals(stub.callsTo('openrouter.ai').length, 0, 'Provider-Calls');
  } finally {
    stub.restore();
  }
});

Deno.test('Body ueber dem Cap -> 413 payload_too_large', async () => {
  // Deliberately silent about WHICH cap fires: whether the runtime supplies a
  // content-length (fast path) or not (hard cap in readBodyLimited) is
  // platform-dependent, and the answer is the same either way.
  const stub = installFetch();
  try {
    const res = await handleRequest(makeRequest({ imageBase64: OVERSIZED_BODY_IMAGE_BASE64 }));
    assertEquals(res.status, 413, 'Status');
    const body = await res.json() as JsonRecord;
    assertEquals(body.error, 'payload_too_large', 'Fehlercode');
    assertEquals(stub.callsTo('openrouter.ai').length, 0, 'Provider-Calls');
  } finally {
    stub.restore();
  }
});

Deno.test('falscher content-type -> 415 unsupported_content_type', async () => {
  const stub = installFetch();
  try {
    const res = await handleRequest(
      makeRequest({ imageBase64: IMAGE_BASE64 }, { contentType: 'text/plain' }),
    );
    assertEquals(res.status, 415, 'Status');
    const body = await res.json() as JsonRecord;
    assertEquals(body.error, 'unsupported_content_type', 'Fehlercode');
    assertEquals(stub.callsTo('openrouter.ai').length, 0, 'Provider-Calls');
  } finally {
    stub.restore();
  }
});

Deno.test('fehlendes Provider-Secret -> 500 provider_not_configured, ohne Roundtrip', async () => {
  // Also proves the secrets are read PER REQUEST: at module load the value
  // would be frozen and this delete would have no effect.
  const stub = installFetch();
  const previous = Deno.env.get('OPENROUTER_API_KEY') ?? '';
  Deno.env.delete('OPENROUTER_API_KEY');
  try {
    const res = await handleRequest(makeRequest({ imageBase64: IMAGE_BASE64 }));
    assertEquals(res.status, 500, 'Status');
    const body = await res.json() as JsonRecord;
    assertEquals(body.error, 'provider_not_configured', 'Fehlercode');
    assertEquals(stub.calls.length, 0, 'Roundtrips');
  } finally {
    Deno.env.set('OPENROUTER_API_KEY', previous);
    stub.restore();
  }
});

Deno.test('Erfolgsfall -> 200 mit normalisiertem Ergebnis und Rate-Limit-Stand', async () => {
  const stub = installFetch();
  try {
    const res = await handleRequest(makeRequest({
      imageBase64: `data:image/png;base64,${IMAGE_BASE64}`,
      portionHint: 'large',
      freeTextHint: 'mit extra Sauce',
      language: 'en',
    }));
    assertEquals(res.status, 200, 'Status');
    assertEquals(res.headers.get('content-type'), 'application/json; charset=utf-8', 'content-type');

    const body = await res.json() as JsonRecord;
    const result = body.result as JsonRecord;
    assertEquals(result.mealName, 'Steak mit Kartoffeln', 'mealName');
    assertEquals(result.caloriesKcal, 780, 'caloriesKcal');
    assertEquals(result.estimatedGrams, 300, 'estimatedGrams');
    assertEquals(result.kcalPer100G, 260, 'kcalPer100G');
    assertEquals(result.confidence, 'high', 'confidence');
    assertEquals((result.items as unknown[]).length, 2, 'items');
    assertEquals(typeof body.requestId, 'string', 'requestId');

    const rateLimit = body.rateLimit as JsonRecord;
    assertEquals((rateLimit.ip as JsonRecord).allowed, true, 'rateLimit.ip.allowed');
    assertEquals((rateLimit.user as JsonRecord).allowed, true, 'rateLimit.user.allowed');
    assertEquals((rateLimit.userDay as JsonRecord).allowed, true, 'rateLimit.userDay.allowed');
    // The global bucket is operator information, not client information.
    assertEquals('global' in rateLimit, false, 'rateLimit.global bleibt intern');
    assertEquals(stub.rateLimitScopes().join(','), GATE_ORDER, 'Gate-Reihenfolge');
    // Cosmetic: the referer names the real domain.
    assertEquals(
      stub.callsTo('openrouter.ai')[0].headers.get('http-referer'),
      'https://eatova.de',
      'HTTP-Referer',
    );
    // Table hygiene runs fire-and-forget and must not tear down the request.
    assertEquals(stub.callsTo('prune_edge_rate_limits').length, 1, 'Prune-Calls');

    // Shape of the provider request: this is what costs money.
    assertEquals(stub.openRouterBodies.length, 1, 'Provider-Calls');
    const providerBody = stub.openRouterBodies[0];
    assertEquals(providerBody.max_tokens, 4096, 'max_tokens');
    assertEquals((providerBody.response_format as JsonRecord).type, 'json_object', 'response_format');

    const content = (providerBody.messages as JsonRecord[])[0].content as JsonRecord[];
    assertEquals(content.length, 2, 'Prompt + Bild');
    assertEquals(
      (content[1].image_url as JsonRecord).url,
      `data:image/png;base64,${IMAGE_BASE64}`,
      'data:-URL mit dem aus dem Praefix geparsten MIME-Typ',
    );

    const promptText = String(content[0].text);
    assert(promptText.includes('ENGLISCH'), 'language "en" muss die Sprachregel umstellen');
    assert(promptText.includes('mit extra Sauce'), 'Freitext-Hinweis fehlt im Prompt');
    assert(promptText.includes('~50% mehr als Standardportion'), 'portionHint "large" fehlt im Prompt');
    // F9-10: text inside the photo is content, never an instruction.
    assert(
      /Text im Bild[\s\S]*Bildinhalt[\s\S]*Anweisung/i.test(promptText),
      'Schutzsatz gegen Anweisungen im Bild fehlt im BASE_PROMPT',
    );
  } finally {
    stub.restore();
  }
});

// ---------------------------------------------------------------------------
// F-28-1 (review 2026-08-28): auth failures are capped per IP BEFORE any
// further backend work, like coach-chat. Without this, every signature-valid
// but revoked token cost an uncapped /auth/v1/user introspection.
// ---------------------------------------------------------------------------

Deno.test('F-28-1: wiederholte Auth-Fehlschlaege verbrauchen das Fail-Bucket bis 429', async () => {
  // Budget 2: the first two failures answer 401 (and count), the third hits
  // the atomic check+increment and gets a 429.
  const stub = installFetch({ authStatus: 401, authFailBudget: 2 });
  try {
    const request = () => makeRequest({ imageBase64: IMAGE_BASE64 }, { ip: '203.0.113.7' });
    const first = await handleRequest(request());
    assertEquals(first.status, 401, '1. Fehlversuch: Status');
    const second = await handleRequest(request());
    assertEquals(second.status, 401, '2. Fehlversuch: Status');
    const third = await handleRequest(request());
    assertEquals(third.status, 429, '3. Fehlversuch: Status');
    const body = await third.json() as JsonRecord;
    assertEquals(body.error, 'rate_limited', 'Fehlercode');
    assert(third.headers.get('retry-after') !== null, 'retry-after fehlt');

    // Each failure costs exactly one lookup and one consume in the fail
    // bucket, with the numbers shared with coach-chat.
    assertEquals(stub.callsTo('/auth/v1/user').length, 3, 'Auth-Lookups');
    const scopes = stub.rateLimitScopes();
    assertEquals(scopes.length, 3, `nur das Fail-Bucket: ${scopes.join(',')}`);
    assert(scopes.every((scope) => scope === 'analyze-meal:auth-fail'), 'keine ip/user-Gates auf dem Fehlschlag-Pfad');
    const params = stub.rateLimitParams('analyze-meal:auth-fail');
    assertEquals(params?.p_limit, 30, 'konservatives Limit (30/h)');
    assertEquals(params?.p_window_seconds, 3600, 'Stunden-Fenster');
    // Keyed by the client IP, never by a token-derived value.
    assertEquals(params?.p_subject, 'ip:203.0.113.7', 'Subject');
    assertEquals(stub.openRouterBodies.length, 0, 'kein Provider-Call');
  } finally {
    stub.restore();
  }
});

Deno.test('F-28-1: ohne IP-Header landet der Fehlschlag im dokumentierten anon-Fallback', async () => {
  const stub = installFetch({ authStatus: 401, authFailBudget: 5 });
  try {
    const res = await handleRequest(makeRequest({ imageBase64: IMAGE_BASE64 }));
    assertEquals(res.status, 401, 'Status');
    // Unreachable behind Cloudflare; only failures land in this shared bucket.
    assertEquals(stub.rateLimitParams('analyze-meal:auth-fail')?.p_subject, 'uid:anon', 'Fallback-Subject');
  } finally {
    stub.restore();
  }
});

Deno.test('F-28-1: erfolgreiche Auth beruehrt das Fail-Bucket nicht', async () => {
  const stub = installFetch({ authFailBudget: 0 });
  try {
    const res = await handleRequest(makeRequest({ imageBase64: IMAGE_BASE64 }));
    assertEquals(res.status, 200, 'Status');
    assertEquals(stub.rateLimitScopes().join(','), GATE_ORDER, 'nur die vier Anwendungs-Gates');
  } finally {
    stub.restore();
  }
});

Deno.test('F-28-1: Auth-200 ohne brauchbare User-Id zaehlt nicht ins Fail-Bucket', async () => {
  // The lookup succeeded, so nothing was amplified; counting it would let a
  // broken auth server 429 whole IPs (same rule as coach-chat).
  const stub = installFetch({ authBody: { id: 'kurz' }, authFailBudget: 0 });
  try {
    const res = await handleRequest(makeRequest({ imageBase64: IMAGE_BASE64 }));
    assertEquals(res.status, 401, 'Status');
    assertEquals(stub.rateLimitScopes().length, 0, 'kein Consume');
  } finally {
    stub.restore();
  }
});

Deno.test('F-28-1: Limiter-Ausfall am Fail-Bucket blockiert die 401 nicht', async () => {
  // The gate is a damper, not an auth boundary: with the limiter down the
  // caller still gets its honest 401 instead of a 500.
  const stub = installFetch({ authStatus: 401, authFailGateStatus: 500 });
  try {
    const res = await handleRequest(makeRequest({ imageBase64: IMAGE_BASE64 }));
    assertEquals(res.status, 401, 'Status');
    const body = await res.json() as JsonRecord;
    assertEquals(body.error, 'invalid_user_token', 'Fehlercode');
    assertEquals(stub.rateLimitScopes().length, 1, 'der Consume wurde versucht');
  } finally {
    stub.restore();
  }
});
