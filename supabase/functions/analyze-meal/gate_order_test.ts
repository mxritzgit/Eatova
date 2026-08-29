// Gate order and request budget of analyze-meal (review 2026-08-29,
// findings P6-01 / P6-02 / P6-07).
//
// Own file on purpose: handler_test.ts covers the request/response contract,
// this one covers WHEN a bucket is spent and WHEN an outbound call gives up.
//
//  P6-01  The global day bucket is the bill cap. Requests that never reach a
//         paid provider call (400/413/415) must not spend it.
//  P6-02  The per-user day bucket must count analyses, not attempts: a request
//         that already lost at the hourly gate must not cost a day slot.
//  P6-07  Every outbound call needs a deadline, and their sum must stay below
//         the 60 s client timeout (lib/src/services/eatova_http.dart).
//
// Works without a server because handler.ts reads its secrets PER REQUEST;
// the timing constants are module level, so the P6-07 tests load their own
// handler instance via a query-tagged specifier (string LITERAL — a computed
// one would need --allow-read, which CI does not grant).

import { handleRequest } from './handler.ts';
import { pruneRateLimits } from '../_shared/rate_limit_prune.ts';

const USER_ID = '11111111-1111-4111-8111-111111111111';
const BASE_URL = 'https://supabase.test.invalid';
const ANON_KEY = 'test-anon-key';
const USER_JWT = 'test-user-jwt';

// Must exceed MIN_IMAGE_BYTES (128 bytes = 171 base64 chars), otherwise
// image_too_small fires instead of the path under test.
const IMAGE_BASE64 = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ' + 'A'.repeat(200);
// Over MAX_IMAGE_BYTES (5 MB) but below MAX_CONTENT_LENGTH (7 MB), so the
// second 413 (image_too_large) fires — the one that sits behind the gates.
const OVERSIZED_IMAGE_BASE64 = 'A'.repeat(6_700_000);

const MODEL_RESULT = {
  mealName: 'Steak mit Kartoffeln',
  caloriesKcal: 780,
  estimatedGrams: 300,
  kcalPer100G: 260,
  confidence: 'high',
  explanation: 'Teller als Referenz.',
  items: [{ name: 'Steak', grams: 300, caloriesKcal: 780, kcalPer100G: 260 }],
};

Deno.env.set('SUPABASE_URL', BASE_URL);
Deno.env.set('SUPABASE_ANON_KEY', ANON_KEY);
Deno.env.set('SUPABASE_SERVICE_ROLE_KEY', 'test-service-key');
Deno.env.set('OPENROUTER_API_KEY', 'test-openrouter-key');

/** Gate order since the 2026-08-29 fix: the two attempt counters first, then
 *  body validation, then the two day buckets that must count analyses. */
const GATE_ORDER = 'analyze-meal:ip,analyze-meal:user,analyze-meal:user-day,analyze-meal:global';
/** What a request rejected by the body validation may spend. */
const ATTEMPT_GATES = 'analyze-meal:ip,analyze-meal:user';

type JsonRecord = Record<string, unknown>;
type Handler = (request: Request) => Promise<Response>;

function assert(condition: boolean, message: string): void {
  if (!condition) throw new Error(message);
}

function assertEquals(actual: unknown, expected: unknown, message: string): void {
  if (actual !== expected) {
    throw new Error(`${message}: erwartet ${JSON.stringify(expected)}, war ${JSON.stringify(actual)}`);
  }
}

function jsonRes(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), { status, headers: { 'content-type': 'application/json' } });
}

interface RecordedCall {
  url: string;
  body: string;
  signal: AbortSignal | null | undefined;
}

interface StubOptions {
  authStatus?: number;
  ipAllowed?: boolean;
  userAllowed?: boolean;
  userDayAllowed?: boolean;
  globalAllowed?: boolean;
  /** Substrings of URLs whose fetch never answers on its own. */
  hangOn?: ('auth' | 'gate' | 'auth-fail' | 'prune' | 'openrouter')[];
}

interface FetchStub {
  calls: RecordedCall[];
  callsTo(fragment: string): RecordedCall[];
  rateLimitScopes(): string[];
  restore(): void;
}

/**
 * A hanging call. With a signal it rejects exactly like a real fetch on abort
 * (DOMException TimeoutError), without one it never settles — that is the
 * authFailGate case, which has no signal of its own and must be bounded by the
 * caller.
 */
function hang(signal: AbortSignal | null | undefined): Promise<Response> {
  return new Promise<Response>((_resolve, reject) => {
    if (!signal) return;
    if (signal.aborted) {
      reject(signal.reason);
      return;
    }
    signal.addEventListener('abort', () => reject(signal.reason), { once: true });
  });
}

function installFetch(options: StubOptions = {}): FetchStub {
  const calls: RecordedCall[] = [];
  const original = globalThis.fetch;
  const hangOn = new Set(options.hangOn ?? []);

  function route(call: RecordedCall): Promise<Response> {
    const { url, body, signal } = call;
    if (url.includes('/auth/v1/user')) {
      if (hangOn.has('auth')) return hang(signal);
      if (options.authStatus !== undefined) {
        return Promise.resolve(jsonRes({ message: 'invalid token' }, options.authStatus));
      }
      return Promise.resolve(jsonRes({ id: USER_ID }));
    }
    if (url.includes('/rest/v1/rpc/consume_edge_rate_limit')) {
      const params = JSON.parse(body) as JsonRecord;
      const scope = String(params.p_scope);
      if (scope === 'analyze-meal:auth-fail') {
        if (hangOn.has('auth-fail')) return hang(signal);
        return Promise.resolve(jsonRes(limitBody(params, true)));
      }
      if (hangOn.has('gate')) return hang(signal);
      const allowedByScope: Record<string, boolean | undefined> = {
        'analyze-meal:ip': options.ipAllowed,
        'analyze-meal:user': options.userAllowed,
        'analyze-meal:user-day': options.userDayAllowed,
        'analyze-meal:global': options.globalAllowed,
      };
      if (!(scope in allowedByScope)) throw new Error(`Unbekannter Rate-Limit-Scope im Test: ${scope}`);
      return Promise.resolve(jsonRes(limitBody(params, allowedByScope[scope] ?? true)));
    }
    if (url.includes('/rest/v1/rpc/prune_edge_rate_limits')) {
      if (hangOn.has('prune')) return hang(signal);
      return Promise.resolve(new Response(null, { status: 204 }));
    }
    if (url.includes('openrouter.ai')) {
      if (hangOn.has('openrouter')) return hang(signal);
      return Promise.resolve(jsonRes({ choices: [{ message: { content: JSON.stringify(MODEL_RESULT) } }] }));
    }
    throw new Error(`Unerwarteter fetch im Test: ${url}`);
  }

  function limitBody(params: JsonRecord, allowed: boolean): JsonRecord {
    const limit = Number(params.p_limit);
    const windowSeconds = Number(params.p_window_seconds);
    return {
      allowed,
      limit,
      remaining: allowed ? limit - 1 : 0,
      resetAt: new Date(Date.now() + windowSeconds * 1000).toISOString(),
      windowSeconds,
    };
  }

  globalThis.fetch = ((input: string | URL | Request, init?: RequestInit): Promise<Response> => {
    const url = typeof input === 'string' ? input : input instanceof URL ? input.toString() : input.url;
    const call: RecordedCall = {
      url,
      body: typeof init?.body === 'string' ? init.body : '',
      signal: init?.signal,
    };
    calls.push(call);
    return route(call);
  }) as typeof globalThis.fetch;

  return {
    calls,
    callsTo: (fragment: string) => calls.filter((call) => call.url.includes(fragment)),
    rateLimitScopes: () =>
      calls
        .filter((call) => call.url.includes('/rpc/consume_edge_rate_limit'))
        .map((call) => String((JSON.parse(call.body) as JsonRecord).p_scope)),
    restore: () => {
      globalThis.fetch = original;
    },
  };
}

interface RequestOptions {
  contentType?: string | null;
  /** Raw body, bypassing JSON.stringify (invalid-JSON case). */
  raw?: string;
}

function makeRequest(payload: JsonRecord, options: RequestOptions = {}): Request {
  const headers: Record<string, string> = { authorization: `Bearer ${USER_JWT}` };
  const contentType = options.contentType === undefined ? 'application/json' : options.contentType;
  if (contentType !== null) headers['content-type'] = contentType;
  return new Request('https://edge.test.invalid/analyze-meal', {
    method: 'POST',
    headers,
    body: options.raw ?? JSON.stringify(payload),
  });
}

// One module instance per timing profile. Specifiers must be string literals.
const LOADERS: Record<string, () => Promise<{ handleRequest: Handler }>> = {
  'quick-steps': () => import('./handler.ts?p6=quick-steps'),
  'tiny-budget': () => import('./handler.ts?p6=tiny-budget'),
};

/** Loads a fresh handler instance with `env` applied for the duration of the
 *  import; the variables are removed again so the statically imported instance
 *  keeps the production defaults. */
async function loadHandler(tag: keyof typeof LOADERS, env: Record<string, string>): Promise<Handler> {
  const previous = new Map<string, string | undefined>();
  for (const [key, value] of Object.entries(env)) {
    previous.set(key, Deno.env.get(key));
    Deno.env.set(key, value);
  }
  try {
    return (await LOADERS[tag]()).handleRequest;
  } finally {
    for (const [key, value] of previous) {
      if (value === undefined) Deno.env.delete(key);
      else Deno.env.set(key, value);
    }
  }
}

// ---------------------------------------------------------------------------
// P6-01: the global day bucket is a bill cap, not an attempt counter.
// ---------------------------------------------------------------------------

Deno.test('P6-01: fehlendes Bild -> 400 ohne globalen Slot', async () => {
  const stub = installFetch();
  try {
    const res = await handleRequest(makeRequest({ x: 1 }));
    assertEquals(res.status, 400, 'Status');
    assertEquals((await res.json() as JsonRecord).error, 'missing_image', 'Fehlercode');
    // The decisive assertion: a few hundred bytes of junk must not be able to
    // empty the shared day cap for everyone until 00:00 UTC.
    assertEquals(stub.rateLimitScopes().join(','), ATTEMPT_GATES, 'Gate-Reihenfolge');
    assertEquals(stub.callsTo('openrouter.ai').length, 0, 'Provider-Calls');
  } finally {
    stub.restore();
  }
});

Deno.test('P6-01: kaputtes JSON -> 400 ohne globalen Slot', async () => {
  const stub = installFetch();
  try {
    const res = await handleRequest(makeRequest({}, { raw: '{nope' }));
    assertEquals(res.status, 400, 'Status');
    assertEquals((await res.json() as JsonRecord).error, 'invalid_json', 'Fehlercode');
    assertEquals(stub.rateLimitScopes().join(','), ATTEMPT_GATES, 'Gate-Reihenfolge');
  } finally {
    stub.restore();
  }
});

Deno.test('P6-01: falscher content-type -> 415 ohne globalen Slot', async () => {
  const stub = installFetch();
  try {
    const res = await handleRequest(makeRequest({ imageBase64: IMAGE_BASE64 }, { contentType: 'text/plain' }));
    assertEquals(res.status, 415, 'Status');
    assertEquals((await res.json() as JsonRecord).error, 'unsupported_content_type', 'Fehlercode');
    assertEquals(stub.rateLimitScopes().join(','), ATTEMPT_GATES, 'Gate-Reihenfolge');
  } finally {
    stub.restore();
  }
});

Deno.test('P6-01: zu grosses Bild -> 413 ohne globalen Slot', async () => {
  const stub = installFetch();
  try {
    const res = await handleRequest(makeRequest({ imageBase64: OVERSIZED_IMAGE_BASE64 }));
    assertEquals(res.status, 413, 'Status');
    assertEquals((await res.json() as JsonRecord).error, 'image_too_large', 'Fehlercode');
    assertEquals(stub.rateLimitScopes().join(','), ATTEMPT_GATES, 'Gate-Reihenfolge');
  } finally {
    stub.restore();
  }
});

Deno.test('P6-01: nur der bezahlte Weg verbraucht den globalen Slot', async () => {
  const stub = installFetch();
  try {
    const res = await handleRequest(makeRequest({ imageBase64: IMAGE_BASE64 }));
    assertEquals(res.status, 200, 'Status');
    assertEquals(stub.rateLimitScopes().join(','), GATE_ORDER, 'Gate-Reihenfolge');
    assertEquals(stub.callsTo('openrouter.ai').length, 1, 'Provider-Calls');
  } finally {
    stub.restore();
  }
});

// ---------------------------------------------------------------------------
// P6-02: the per-user day bucket counts analyses, not attempts.
// ---------------------------------------------------------------------------

Deno.test('P6-02: Stundenlimit erschoepft -> kein Tages-Slot verbraucht', async () => {
  const stub = installFetch({ userAllowed: false });
  try {
    const res = await handleRequest(makeRequest({ imageBase64: IMAGE_BASE64 }));
    assertEquals(res.status, 429, 'Status');
    assertEquals((await res.json() as JsonRecord).error, 'rate_limited', 'Fehlercode');
    // 100 rejected retries must not lock the user out until midnight when
    // only 20 analyses actually happened.
    assertEquals(stub.rateLimitScopes().join(','), ATTEMPT_GATES, 'Gate-Reihenfolge');
    assert(
      !stub.rateLimitScopes().includes('analyze-meal:user-day'),
      'abgewiesener Stundenversuch darf keinen Tages-Slot kosten',
    );
  } finally {
    stub.restore();
  }
});

Deno.test('P6-02: IP-Limit erschoepft -> weder Stunden- noch Tages-Slot', async () => {
  const stub = installFetch({ ipAllowed: false });
  try {
    const res = await handleRequest(makeRequest({ imageBase64: IMAGE_BASE64 }));
    assertEquals(res.status, 429, 'Status');
    assertEquals(stub.rateLimitScopes().join(','), 'analyze-meal:ip', 'Gate-Reihenfolge');
  } finally {
    stub.restore();
  }
});

Deno.test('P6-02: Tageslimit erschoepft -> 429 vor dem globalen Gate', async () => {
  const stub = installFetch({ userDayAllowed: false });
  try {
    const res = await handleRequest(makeRequest({ imageBase64: IMAGE_BASE64 }));
    assertEquals(res.status, 429, 'Status');
    assertEquals(
      stub.rateLimitScopes().join(','),
      'analyze-meal:ip,analyze-meal:user,analyze-meal:user-day',
      'Gate-Reihenfolge',
    );
    assertEquals(stub.callsTo('openrouter.ai').length, 0, 'Provider-Calls');
  } finally {
    stub.restore();
  }
});

// ---------------------------------------------------------------------------
// P6-07: every outbound call has a deadline, and their sum stays below the
// 60 s client timeout.
// ---------------------------------------------------------------------------

/** 60 ms step ceiling: the tests must fail fast, the production defaults are
 *  in handler.ts. */
const QUICK_STEPS = { ANALYZE_MEAL_SUPABASE_TIMEOUT_MS: '60' };

Deno.test('P6-07: haengender Auth-Lookup bricht ab statt zu blockieren', async () => {
  const handler = await loadHandler('quick-steps', QUICK_STEPS);
  const stub = installFetch({ hangOn: ['auth'] });
  const started = Date.now();
  try {
    const res = await handleWithGuard(handler, makeRequest({ imageBase64: IMAGE_BASE64 }));
    assert(Date.now() - started < 5_000, 'Auth-Lookup lief in kein Zeitlimit');
    // Never a 401: the token was never judged, and the client signs the user
    // out on 401/403 (lib/src/services/meal_analyzer.dart).
    assertEquals(res.status, 503, 'Status');
    assertEquals((await res.json() as JsonRecord).error, 'auth_unavailable', 'Fehlercode');
    assertEquals(stub.callsTo('openrouter.ai').length, 0, 'Provider-Calls');
  } finally {
    stub.restore();
  }
});

Deno.test('P6-07: haengendes Rate-Limit-RPC bricht ab statt zu blockieren', async () => {
  const handler = await loadHandler('quick-steps', QUICK_STEPS);
  const stub = installFetch({ hangOn: ['gate'] });
  const started = Date.now();
  try {
    const res = await handleWithGuard(handler, makeRequest({ imageBase64: IMAGE_BASE64 }));
    assert(Date.now() - started < 5_000, 'Rate-Limit-RPC lief in kein Zeitlimit');
    assertEquals(res.status, 500, 'Status');
    assertEquals((await res.json() as JsonRecord).error, 'rate_limit_unavailable', 'Fehlercode');
    assertEquals(stub.callsTo('openrouter.ai').length, 0, 'Provider-Calls');
  } finally {
    stub.restore();
  }
});

Deno.test('P6-07: haengendes Fail-Bucket blockiert die ehrliche 401 nicht', async () => {
  // authFailGate lives in _shared and has no signal of its own, so the caller
  // bounds it. Falling back to "nicht limitiert" is the helper's own outage
  // rule: a damper must never swallow the 401.
  const handler = await loadHandler('quick-steps', QUICK_STEPS);
  const stub = installFetch({ authStatus: 401, hangOn: ['auth-fail'] });
  const started = Date.now();
  try {
    const res = await handleWithGuard(handler, makeRequest({ imageBase64: IMAGE_BASE64 }));
    assert(Date.now() - started < 5_000, 'Fail-Bucket lief in kein Zeitlimit');
    assertEquals(res.status, 401, 'Status');
    assertEquals((await res.json() as JsonRecord).error, 'invalid_user_token', 'Fehlercode');
  } finally {
    stub.restore();
  }
});

Deno.test('P6-07: das Restbudget deckelt den Provider-Call', async () => {
  // Budget 80 ms: whatever the preliminary steps left over is what the
  // provider gets, never the full 45 s on top of them.
  const handler = await loadHandler('tiny-budget', { ANALYZE_MEAL_REQUEST_BUDGET_MS: '80' });
  const stub = installFetch({ hangOn: ['openrouter'] });
  const started = Date.now();
  try {
    const res = await handleWithGuard(handler, makeRequest({ imageBase64: IMAGE_BASE64 }));
    assert(Date.now() - started < 5_000, 'Provider-Call lief nicht ins Restbudget');
    assertEquals(res.status, 504, 'Status');
    assertEquals((await res.json() as JsonRecord).error, 'provider_timeout', 'Fehlercode');
  } finally {
    stub.restore();
  }
});

Deno.test('P6-07: pruneRateLimits haengt nicht unbegrenzt', async () => {
  const stub = installFetch({ hangOn: ['prune'] });
  try {
    // Fire-and-forget, so it may never reject — but it must RESOLVE.
    await pruneRateLimits({ supabaseUrl: BASE_URL, serviceKey: 'test-service-key', timeoutMs: 40 });
    const signal = stub.callsTo('prune_edge_rate_limits')[0]?.signal;
    assert(signal instanceof AbortSignal, 'Prune-Call ohne AbortSignal');
  } finally {
    stub.restore();
  }
});

Deno.test('P6-07: der Prune-Call im Erfolgsfall bekommt ein Zeitlimit', async () => {
  const stub = installFetch();
  try {
    const res = await handleRequest(makeRequest({ imageBase64: IMAGE_BASE64 }));
    assertEquals(res.status, 200, 'Status');
    const prune = stub.callsTo('prune_edge_rate_limits');
    assertEquals(prune.length, 1, 'Prune-Calls');
    assert(prune[0].signal instanceof AbortSignal, 'Prune-Call ohne AbortSignal');
  } finally {
    stub.restore();
  }
});

/** Fails loudly instead of hanging the whole suite when a stage has no
 *  deadline at all — the pre-fix state of P6-07. */
function handleWithGuard(handler: Handler, request: Request): Promise<Response> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const guard = new Promise<Response>((_resolve, reject) => {
    timer = setTimeout(() => reject(new Error('handleRequest antwortete nicht — die Stufe hat kein Zeitlimit')), 4_000);
  });
  return Promise.race([handler(request), guard]).finally(() => clearTimeout(timer));
}
