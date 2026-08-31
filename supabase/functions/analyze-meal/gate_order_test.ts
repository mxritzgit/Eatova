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
  /** Routes that answer 200 WITH HEADERS and then stall on the body (P6-07b). */
  stallBodyOn?: ('auth' | 'gate')[];
}

interface FetchStub {
  calls: RecordedCall[];
  callsTo(fragment: string): RecordedCall[];
  rateLimitScopes(): string[];
  /** Parameters of the consume_edge_rate_limit call for `scope`. */
  rateLimitParams(scope: string): JsonRecord | undefined;
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

/**
 * The other half of a hanging call: headers arrive at once, the BODY then
 * stalls — GoTrue and PostgREST both answer that way under load. The stream is
 * errored with the signal's OWN reason, exactly as a real fetch aborts a body
 * mid-read, so `await response.json()` sees the step signal's DOMException.
 */
function stallingBody(signal: AbortSignal | null | undefined, head: string): Response {
  const stream = new ReadableStream<Uint8Array>({
    start(controller) {
      controller.enqueue(new TextEncoder().encode(head));
      if (!signal) return;
      // try/catch: a body already cancelled by the reader cannot be errored.
      const fail = () => {
        try {
          controller.error(signal.reason);
        } catch { /* stream already closed */ }
      };
      if (signal.aborted) fail();
      else signal.addEventListener('abort', fail, { once: true });
    },
  });
  return new Response(stream, { status: 200, headers: { 'content-type': 'application/json' } });
}

function installFetch(options: StubOptions = {}): FetchStub {
  const calls: RecordedCall[] = [];
  const original = globalThis.fetch;
  const hangOn = new Set(options.hangOn ?? []);
  const stallBodyOn = new Set(options.stallBodyOn ?? []);

  function route(call: RecordedCall): Promise<Response> {
    const { url, body, signal } = call;
    if (url.includes('/auth/v1/user')) {
      if (hangOn.has('auth')) return hang(signal);
      if (options.authStatus !== undefined) {
        return Promise.resolve(jsonRes({ message: 'invalid token' }, options.authStatus));
      }
      // Opening of a valid identity, never completed.
      if (stallBodyOn.has('auth')) return Promise.resolve(stallingBody(signal, '{"id":"'));
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
      if (stallBodyOn.has('gate')) return Promise.resolve(stallingBody(signal, '{"allowed"'));
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

/**
 * A body the CLIENT paces: the chunks arrive `gapMs` apart, and with
 * `endless` the stream never closes at all — the slow-upload attack from
 * P6-01b. No content-length either, so the cheap 413 fast path cannot fire.
 *
 * `endless` deliberately schedules no timer of its own: the last read simply
 * never resolves, so nothing is left pending when the handler gives up.
 */
function makeStreamingRequest(chunks: string[], gapMs: number, endless = false): Request {
  const encoder = new TextEncoder();
  const body = new ReadableStream<Uint8Array>({
    async start(controller) {
      for (const [index, chunk] of chunks.entries()) {
        if (index > 0) await new Promise((resolve) => setTimeout(resolve, gapMs));
        controller.enqueue(encoder.encode(chunk));
      }
      if (!endless) controller.close();
    },
  });
  return new Request('https://edge.test.invalid/analyze-meal', {
    method: 'POST',
    headers: { authorization: `Bearer ${USER_JWT}`, 'content-type': 'application/json' },
    body,
    // Required for a streamed request body; not in Deno's RequestInit types.
    ...{ duplex: 'half' },
  } as RequestInit);
}

/**
 * A body the client paces, delivered ON DEMAND: every chunk arrives `gapMs`
 * after the reader asks for it, so an upload that is merely slow is
 * distinguishable from one that stopped. With `stall` the stream stays open
 * after the last chunk and schedules NOTHING — the hanging upload, and no
 * pending timer at the end of the test. `stop()` clears the one pull that may
 * still be in flight when the handler has given up.
 *
 * No content-length either, so the cheap 413 fast path cannot fire.
 */
function makePacedRequest(
  chunks: string[],
  gapMs: number,
  stall = false,
): { request: Request; stop: () => void } {
  const encoder = new TextEncoder();
  let index = 0;
  let timer: ReturnType<typeof setTimeout> | undefined;
  let stopped = false;
  const stop = () => {
    stopped = true;
    clearTimeout(timer);
  };
  const body = new ReadableStream<Uint8Array>({
    pull(controller) {
      if (stopped) return;
      if (index >= chunks.length) {
        if (stall) return new Promise<void>(() => {});
        controller.close();
        return;
      }
      const chunk = chunks[index++];
      return new Promise<void>((resolve) => {
        timer = setTimeout(() => {
          if (!stopped) controller.enqueue(encoder.encode(chunk));
          resolve();
        }, gapMs);
      });
    },
    cancel: stop,
  });
  const request = new Request('https://edge.test.invalid/analyze-meal', {
    method: 'POST',
    headers: { authorization: `Bearer ${USER_JWT}`, 'content-type': 'application/json' },
    body,
    // Required for a streamed request body; not in Deno's RequestInit types.
    ...{ duplex: 'half' },
  } as RequestInit);
  return { request, stop };
}

/** Splits a real request body into `parts` pieces — a chunked upload, not a
 *  concatenation of made-up fragments. */
function sliceBody(payload: JsonRecord, parts: number): string[] {
  const raw = JSON.stringify(payload);
  const size = Math.ceil(raw.length / parts);
  const out: string[] = [];
  for (let offset = 0; offset < raw.length; offset += size) out.push(raw.slice(offset, offset + size));
  return out;
}

/** Collects console.warn messages: some of the findings below are ABOUT the
 *  operator line, not only about the status code. */
function captureWarnings(): { messages: string[]; restore: () => void } {
  const original = console.warn;
  const messages: string[] = [];
  console.warn = (...args: unknown[]) => {
    messages.push(String(args[0]));
  };
  return { messages, restore: () => { console.warn = original; } };
}

// One module instance per timing profile. Specifiers must be string literals.
const LOADERS: Record<string, () => Promise<{ handleRequest: Handler }>> = {
  'quick-steps': () => import('./handler.ts?p6=quick-steps'),
  'tiny-budget': () => import('./handler.ts?p6=tiny-budget'),
  'slow-body': () => import('./handler.ts?p6=slow-body'),
  'day-window': () => import('./handler.ts?p6=day-window'),
  'slow-supabase': () => import('./handler.ts?p6=slow-supabase'),
  'tight-budget': () => import('./handler.ts?p6=tight-budget'),
  'tight-drip': () => import('./handler.ts?p6=tight-drip'),
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
  // Two layers bound this call: the signal aborts the RPC, withDeadline bounds
  // the wait. Falling back to "nicht limitiert" is the helper's own outage
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

Deno.test('F-31: der Fail-Bucket-Aufruf traegt ein Abbruchsignal', async () => {
  // withDeadline alone only stops the WAITING - its own doc says "the
  // underlying request keeps running". A stalled PostgREST would then outlive
  // the response and keep the isolate alive. The signal is what actually ends
  // the RPC, so it is the thing worth pinning; the same guarantee is pinned on
  // the coach-chat and search-key side of the shared helper.
  const handler = await loadHandler('quick-steps', QUICK_STEPS);
  const stub = installFetch({ authStatus: 401 });
  try {
    await handleWithGuard(handler, makeRequest({ imageBase64: IMAGE_BASE64 }));
    const gateCalls = stub.calls.filter((call) => call.body.includes('analyze-meal:auth-fail'));
    assertEquals(gateCalls.length, 1, 'genau ein Fail-Bucket-Aufruf');
    assert(
      gateCalls[0].signal instanceof AbortSignal,
      'der Fail-Bucket-fetch lief ohne AbortSignal - ein stockendes PostgREST ueberlebt die Antwort',
    );
    assertEquals(gateCalls[0].signal?.aborted, false, 'das Signal war beim Absenden noch nicht ausgeloest');
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

// ---------------------------------------------------------------------------
// P6-01b: the body read is the one stage the CLIENT paces, so it needs a
// budget of its own. Without it, uploading slowly until REQUEST_BUDGET_MS was
// nearly gone passed the fast day gates and left the provider milliseconds:
// a burnt slot in the shared bill cap at no model cost — the very class P6-01
// closed for junk bodies, reopened through the timing side.
// ---------------------------------------------------------------------------

/** 400 ms body ceiling: the tests must fail fast, the production default
 *  (15 s) is in handler.ts. */
const SLOW_BODY = { ANALYZE_MEAL_BODY_READ_TIMEOUT_MS: '400' };
/** Head of a valid request body — enough for the reader to have something,
 *  never enough to be complete JSON. */
const BODY_HEAD = `{"imageBase64":"${IMAGE_BASE64}"`;

Deno.test('P6-01b: ein tropfender Upload endet mit 408 VOR den Tagesgates', async () => {
  const handler = await loadHandler('slow-body', SLOW_BODY);
  const stub = installFetch();
  const started = Date.now();
  try {
    const res = await handleWithGuard(handler, makeStreamingRequest([BODY_HEAD], 0, true));
    const elapsed = Date.now() - started;
    assertEquals(res.status, 408, 'Status');
    assertEquals((await res.json() as JsonRecord).error, 'request_timeout', 'Fehlercode');
    // THE assertion of this finding: both day buckets snap to 00:00 UTC, so a
    // slot burnt there stays burnt. A client that only uploads slowly must not
    // be able to reach them — the two rolling attempt gates are its whole cost.
    assertEquals(stub.rateLimitScopes().join(','), ATTEMPT_GATES, 'Gate-Reihenfolge');
    assertEquals(stub.callsTo('openrouter.ai').length, 0, 'Provider-Calls');
    // The body ceiling governs, NOT the request budget (55 s): what is left
    // for the stages behind it is a server-side number again.
    assert(elapsed < 3_000, `Abbruch dauerte ${elapsed} ms — es greift nicht die Body-Grenze`);
    assert(elapsed >= 200, `Abbruch nach ${elapsed} ms — das Zeitlimit greift gar nicht`);
  } finally {
    stub.restore();
  }
});

Deno.test('P6-01b: ein langsamer, aber vollstaendiger Upload kommt normal durch', async () => {
  // The guard must slow honest clients down, not reject them: same instance,
  // same streaming body, only complete within the ceiling.
  const handler = await loadHandler('slow-body', SLOW_BODY);
  const stub = installFetch();
  try {
    const request = makeStreamingRequest([BODY_HEAD, ',"portionHint":"large"', '}'], 10);
    const res = await handleWithGuard(handler, request);
    assertEquals(res.status, 200, 'Status');
    assertEquals(stub.rateLimitScopes().join(','), GATE_ORDER, 'Gate-Reihenfolge');
    assertEquals(stub.callsTo('openrouter.ai').length, 1, 'Provider-Calls');
  } finally {
    stub.restore();
  }
});

// ---------------------------------------------------------------------------
// P6-03: a window value an operator sets must reach the RPC. Without an
// explicit max, positiveIntFromEnv capped at the LIMIT bound (10000) and a day
// window fell back to the code default — 24x looser, silently, at a paid cap.
// ---------------------------------------------------------------------------

Deno.test('P6-03: ANALYZE_MEAL_USER_WINDOW_SECONDS=86400 kommt bei der RPC an', async () => {
  const handler = await loadHandler('day-window', {
    ANALYZE_MEAL_USER_WINDOW_SECONDS: '86400',
    ANALYZE_MEAL_IP_WINDOW_SECONDS: '86400',
  });
  const stub = installFetch();
  try {
    const res = await handler(makeRequest({ imageBase64: IMAGE_BASE64 }));
    assertEquals(res.status, 200, 'Status');
    assertEquals(stub.rateLimitParams('analyze-meal:user')?.p_window_seconds, 86400, 'Nutzer-Fenster');
    assertEquals(stub.rateLimitParams('analyze-meal:ip')?.p_window_seconds, 86400, 'IP-Fenster');
  } finally {
    stub.restore();
  }
});

// ---------------------------------------------------------------------------
// P6-01b/2 (review 2026-08-31, D1): the body ceiling is an IDLE ceiling.
// One setTimeout for the whole read, never restarted, capped the UPLOAD at
// 15 s wall clock although the client waits 60 s for this stage. 300 kbit/s
// with a 0.6 MB photo (~0.8 MB base64, inside the client's own 5 MB cap) is
// ~21 s on the wire: the honest uplink got a 408 while the hourly IP and user
// buckets were already spent — consume_edge_rate_limit has no refund, so every
// retry failed identically. What must be capped is a HANGING upload; the
// endless one is now stopped by the separate total instead.
// ---------------------------------------------------------------------------

/** Budget 3000 ms -> the body window lands on MIN_BODY_READ_MS (2 s), the
 *  smallest total the code allows. */
const TIGHT_BUDGET = { ANALYZE_MEAL_REQUEST_BUDGET_MS: '3000' };

Deno.test('D1: ein langsamer, aber stetig liefernder Upload laeuft durch', async () => {
  // 10 chunks 80 ms apart: every GAP stays far below the 400 ms ceiling while
  // the upload as a whole is twice as long as it. This is the finding — a
  // single wall-clock timer answered 408 to exactly this client.
  const handler = await loadHandler('slow-body', SLOW_BODY);
  const stub = installFetch();
  const started = Date.now();
  const paced = makePacedRequest(sliceBody({ imageBase64: IMAGE_BASE64 }, 10), 80);
  try {
    const res = await handleWithGuard(handler, paced.request);
    const elapsed = Date.now() - started;
    assertEquals(res.status, 200, 'Status');
    assert(
      elapsed > 600,
      `Upload dauerte nur ${elapsed} ms — er hat die Leerlaufgrenze gar nicht ueberschritten`,
    );
    assertEquals(stub.rateLimitScopes().join(','), GATE_ORDER, 'Gate-Reihenfolge');
    assertEquals(stub.callsTo('openrouter.ai').length, 1, 'Provider-Calls');
  } finally {
    paced.stop();
    stub.restore();
  }
});

Deno.test('D1: ein Upload, der nach Fortschritt stehen bleibt, endet weiterhin in 408', async () => {
  // The other half of the same rule: three chunks, then nothing. The clock now
  // starts over per chunk, so it fires 400 ms after the LAST byte instead of
  // 400 ms after the first — later, but it still fires.
  const handler = await loadHandler('slow-body', SLOW_BODY);
  const stub = installFetch();
  const started = Date.now();
  const paced = makePacedRequest(sliceBody({ imageBase64: IMAGE_BASE64 }, 10).slice(0, 3), 80, true);
  try {
    const res = await handleWithGuard(handler, paced.request);
    const elapsed = Date.now() - started;
    assertEquals(res.status, 408, 'Status');
    assertEquals((await res.json() as JsonRecord).error, 'request_timeout', 'Fehlercode');
    assert(elapsed >= 400, `Abbruch nach ${elapsed} ms — die Leerlaufuhr laeuft gar nicht`);
    assert(elapsed < 3_000, `Abbruch dauerte ${elapsed} ms — der haengende Upload wird nicht gedeckelt`);
    assertEquals(stub.rateLimitScopes().join(','), ATTEMPT_GATES, 'Gate-Reihenfolge');
    assertEquals(stub.callsTo('openrouter.ai').length, 0, 'Provider-Calls');
  } finally {
    paced.stop();
    stub.restore();
  }
});

Deno.test('D1: ein endlos tropfender Upload laeuft in die Gesamtgrenze', async () => {
  // Counter-check to the idle clock, and the reason it may not stand alone:
  // 150 ms gaps stay inside the 400 ms idle ceiling forever, so ONLY the
  // second clock can end this. Without it the slow-chunk route around the
  // budget from P6-01b would be open again and this would never answer — the
  // 2 s window here against a drip that would need 4.35 s.
  const handler = await loadHandler('tight-drip', { ...TIGHT_BUDGET, ...SLOW_BODY });
  const stub = installFetch();
  const started = Date.now();
  const paced = makePacedRequest(sliceBody({ imageBase64: IMAGE_BASE64 }, 30).slice(0, 29), 150, true);
  try {
    const res = await handleWithGuard(handler, paced.request);
    const elapsed = Date.now() - started;
    assertEquals(res.status, 408, 'Status');
    assertEquals((await res.json() as JsonRecord).error, 'request_timeout', 'Fehlercode');
    assert(elapsed >= 1_800, `Abbruch nach ${elapsed} ms — die Gesamtgrenze greift zu frueh`);
    assertEquals(stub.rateLimitScopes().join(','), ATTEMPT_GATES, 'Gate-Reihenfolge');
    assertEquals(stub.callsTo('openrouter.ai').length, 0, 'Provider-Calls');
  } finally {
    paced.stop();
    stub.restore();
  }
});

// ---------------------------------------------------------------------------
// P6-07b (review 2026-08-31, D2): the step signal covers the response BODY,
// and `await response.json()` used to sit OUTSIDE the try that maps its
// DOMException. GoTrue and PostgREST send their headers fast and can stall on
// the body afterwards; the abort then landed in the outer catch as a bare
// 500 internal_error — not the designed outage answer, and without the
// operator line naming the stage.
// ---------------------------------------------------------------------------

Deno.test('D2: stockender Auth-Body ergibt 503 auth_unavailable, nicht 500', async () => {
  const handler = await loadHandler('quick-steps', QUICK_STEPS);
  const stub = installFetch({ stallBodyOn: ['auth'] });
  const started = Date.now();
  try {
    const res = await handleWithGuard(handler, makeRequest({ imageBase64: IMAGE_BASE64 }));
    assert(Date.now() - started < 5_000, 'Auth-Body lief in kein Zeitlimit');
    // Never a 401 and never a 500: the token was never judged, and the client
    // signs the user out on 401/403 (lib/src/services/meal_analyzer.dart).
    assertEquals(res.status, 503, 'Status');
    assertEquals((await res.json() as JsonRecord).error, 'auth_unavailable', 'Fehlercode');
    assertEquals(stub.callsTo('openrouter.ai').length, 0, 'Provider-Calls');
  } finally {
    stub.restore();
  }
});

Deno.test('D2: stockender Limiter-Body ergibt rate_limit_unavailable, nicht internal_error', async () => {
  const handler = await loadHandler('quick-steps', QUICK_STEPS);
  const stub = installFetch({ stallBodyOn: ['gate'] });
  const started = Date.now();
  try {
    const res = await handleWithGuard(handler, makeRequest({ imageBase64: IMAGE_BASE64 }));
    assert(Date.now() - started < 5_000, 'Limiter-Body lief in kein Zeitlimit');
    // Same STATUS as the generic failure on purpose (the limiter outage has
    // always been a 500) — what the finding is about is the CODE the client
    // maps and the operator line that names the limiter.
    assertEquals(res.status, 500, 'Status');
    assertEquals((await res.json() as JsonRecord).error, 'rate_limit_unavailable', 'Fehlercode');
    assertEquals(stub.callsTo('openrouter.ai').length, 0, 'Provider-Calls');
  } finally {
    stub.restore();
  }
});

// ---------------------------------------------------------------------------
// P6-01c (review 2026-08-31, D3): bodyReadBudget reserves TWO Supabase
// roundtrips plus MIN_PROVIDER_MS, so every second of
// ANALYZE_MEAL_SUPABASE_TIMEOUT_MS costs the upload two. At the old flat
// ceiling of 120 s any value from ~19 s up — a plausible reaction to a slow
// PostgREST — silently collapsed the window onto the 2 s floor and answered
// 408 to every photo of more than a few hundred kB, for every user, with the
// gates spent. A floor that rejects every upload is not a floor.
// ---------------------------------------------------------------------------

const SLOW_SUPABASE = { ANALYZE_MEAL_SUPABASE_TIMEOUT_MS: '20000' };

Deno.test('D3: grosser ANALYZE_MEAL_SUPABASE_TIMEOUT_MS laesst das Upload-Fenster brauchbar', async () => {
  // The operator value from the finding. 8 chunks 300 ms apart = 2.4 s of
  // upload: over the 2 s floor the old reserve collapsed onto, far under the
  // ~30 s the budget really has left. No handleWithGuard — the read is timed
  // either way, and the pacing alone is longer than its 4 s ceiling allows for.
  const handler = await loadHandler('slow-supabase', SLOW_SUPABASE);
  const stub = installFetch();
  const started = Date.now();
  const paced = makePacedRequest(sliceBody({ imageBase64: IMAGE_BASE64 }, 8), 300);
  try {
    const res = await handler(paced.request);
    const elapsed = Date.now() - started;
    assertEquals(res.status, 200, 'Status');
    assert(elapsed >= 2_100, `Upload dauerte nur ${elapsed} ms — er blieb unter dem alten 2-s-Boden`);
    assertEquals(stub.rateLimitScopes().join(','), GATE_ORDER, 'Gate-Reihenfolge');
    assertEquals(stub.callsTo('openrouter.ai').length, 1, 'Provider-Calls');
  } finally {
    paced.stop();
    stub.restore();
  }
});

Deno.test('D3: ein geschrumpftes Upload-Fenster wird fuer den Betreiber protokolliert', async () => {
  // The second half of the finding: the collapse was SILENT. A window under
  // the honest minimum may still happen (a budget an operator shortened, or
  // stages in front that are slower than their share) — it must not be quiet.
  const handler = await loadHandler('tight-budget', TIGHT_BUDGET);
  const stub = installFetch();
  const warnings = captureWarnings();
  try {
    const res = await handler(makeRequest({ imageBase64: IMAGE_BASE64 }));
    assertEquals(res.status, 200, 'Status');
    assert(
      warnings.messages.some((line) => line.includes('upload window below minimum')),
      `keine Betreiber-Zeile zum geschrumpften Upload-Fenster: ${warnings.messages.join(' | ')}`,
    );
  } finally {
    warnings.restore();
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
