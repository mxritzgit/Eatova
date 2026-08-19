// End-to-End-Tests fuer handleRequest (handler.ts) mit gestubbtem fetch.
//
// Bis zum Testbarkeits-Umbau (Komplettreview 2026-08-19) stand `Deno.serve`
// zusammen mit der ganzen Logik in index.ts auf Modulebene: die Datei liess
// sich nicht importieren, ohne einen Server zu starten. Fuer die teuersten
// Pfade dieser Function gab es deshalb keinen einzigen Test — Auth (401), die
// beiden Rate-Limit-Gates (429 / 500 bei Limiter-Ausfall) und die Groessen-
// bzw. Typpruefung des Bildes (413 / 415). Genau die deckt diese Datei ab.
//
// Warum das ohne Server geht: handler.ts liest die vier Request-Secrets PRO
// REQUEST (readSecrets() in handleRequest), nicht mehr beim Modul-Load —
// Deno.env.set im Test wirkt also. Deshalb braucht `deno test` hier
// --allow-env (steht bereits im Workflow).
//
// Bewusst ohne externe Test-Dependencies (gleicher Stil wie
// ../coach-chat/handler_test.ts).

import { handleRequest } from './handler.ts';

const USER_ID = '11111111-1111-4111-8111-111111111111';
const BASE_URL = 'https://supabase.test.invalid';
const ANON_KEY = 'test-anon-key';
const USER_JWT = 'test-user-jwt';

// Bild-Nutzlast der Tests. Die Function DECODIERT das Base64 nie — sie reicht
// es als data:-URL an den Provider weiter und prueft nur Zeichensatz
// (/^[A-Za-z0-9+/]+=*$/) und geschaetzte Groesse. Deshalb genuegt ein
// PNG-Praefix plus Fuellsequenz; sie muss nur ueber MIN_IMAGE_BYTES liegen
// (128 Byte, also >= 171 Base64-Zeichen), sonst kommt image_too_small statt
// des zu testenden Pfads.
const IMAGE_BASE64 = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ' + 'A'.repeat(200);

// Ueber MAX_IMAGE_BYTES (5 MB): estimatedBytes = floor(len * 0.75), also
// braucht es mehr als 6.666.666 Zeichen. Der JSON-Body bleibt damit noch
// unter MAX_CONTENT_LENGTH (7 MB) — sonst schluege der Body-Cap zu und der
// Bild-Cap bliebe ungetestet.
const OVERSIZED_IMAGE_BASE64 = 'A'.repeat(6_700_000);
// Ueber MAX_CONTENT_LENGTH (7 MB) inklusive JSON-Rahmen.
const OVERSIZED_BODY_IMAGE_BASE64 = 'A'.repeat(7_200_000);

// Antwort des Modells im Erfolgsfall. Die drei Zahlen sind bewusst
// widerspruchsfrei (780 * 100 / 300 = 260), damit der Mismatch-Warner aus
// normalize.ts hier nicht anspringt und das Log sauber bleibt.
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
}

interface StubOptions {
  /** HTTP-Status des /auth/v1/user-Lookups (Auth-Fehlschlag-Simulation). */
  authStatus?: number;
  /**
   * Body des /auth/v1/user-Lookups. Fuer den 200-mit-unbrauchbarer-Id-Fall:
   * ein Auth-Server, der antwortet, aber keine verwertbare Identitaet liefert.
   */
  authBody?: JsonRecord;
  /** Antwort des IP-Gates (Default: erlaubt). */
  ipAllowed?: boolean;
  /** Antwort des User-Gates (Default: erlaubt). */
  userAllowed?: boolean;
  /**
   * consume_edge_rate_limit antwortet mit 200, aber ohne lesbares `allowed`
   * (Sentinel-Rest E6): ein Limiter-Ausfall, kein gemessenes Limit.
   */
  rateLimitBroken?: boolean;
}

interface FetchStub {
  calls: RecordedCall[];
  openRouterBodies: JsonRecord[];
  callsTo(fragment: string): RecordedCall[];
  /** Scopes der consume_edge_rate_limit-Aufrufe, in Aufrufreihenfolge. */
  rateLimitScopes(): string[];
  restore(): void;
}

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

  function route(url: string, body: string): Response {
    if (url.includes('/auth/v1/user')) {
      if (options.authStatus !== undefined) {
        return jsonRes({ message: 'invalid token' }, options.authStatus);
      }
      return jsonRes(options.authBody ?? { id: USER_ID });
    }
    if (url.includes('/rest/v1/rpc/consume_edge_rate_limit')) {
      if (options.rateLimitBroken) return jsonRes({ ok: true });
      const params = JSON.parse(body) as JsonRecord;
      const allowed = params.p_scope === 'analyze-meal:ip'
        ? options.ipAllowed ?? true
        : options.userAllowed ?? true;
      const limit = Number(params.p_limit);
      const windowSeconds = Number(params.p_window_seconds);
      // Limit/Window aus dem Request spiegeln, statt die Defaults zu
      // verdrahten: die kommen aus positiveIntFromEnv beim Modul-Load und
      // liessen sich vom Test gar nicht mehr setzen.
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
    calls.push({ url, method, body });
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
    restore: () => {
      globalThis.fetch = original;
    },
  };
}

interface RequestOptions {
  method?: string;
  /** null = Header weglassen (fehlender Bearer-Token). */
  authorization?: string | null;
  contentType?: string | null;
}

function makeRequest(payload: JsonRecord, options: RequestOptions = {}): Request {
  const headers: Record<string, string> = {};
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
    // Ein Request ohne Bearer-Header ist lokal entscheidbar: er darf keinen
    // Auth-Lookup kosten.
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
    // Der oeffentliche Anon-Key steckt in jeder App-Kopie. Er ist lokal
    // bekannt und darf deshalb keinen Auth-Roundtrip ausloesen — sonst waere
    // die Function mit einem oeffentlich bekannten Wert beliebig oft
    // anonym belastbar.
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
    assertEquals(stub.rateLimitScopes().length, 0, 'kein Gate nach fehlgeschlagener Auth');
  } finally {
    stub.restore();
  }
});

Deno.test('Auth-200 ohne brauchbare User-Id -> 401 invalid_user_token', async () => {
  // Ein Auth-Server, der 200 antwortet, aber keine verwertbare Identitaet
  // liefert, darf nicht als "eingeloggt" durchgehen: die Id landet sonst als
  // Rate-Limit-Subjekt in der DB.
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
    // Nach einem abgelehnten IP-Gate darf das User-Gate gar nicht mehr
    // konsumieren — sonst verbraucht eine geblockte IP fremde User-Budgets.
    assertEquals(stub.rateLimitScopes().join(','), 'analyze-meal:ip', 'Gate-Reihenfolge');
  } finally {
    stub.restore();
  }
});

Deno.test('User-Limit erschoepft -> 429 nach beiden Gates', async () => {
  const stub = installFetch({ userAllowed: false });
  try {
    const res = await handleRequest(makeRequest({ imageBase64: IMAGE_BASE64 }));
    assertEquals(res.status, 429, 'Status');
    const body = await res.json() as JsonRecord;
    assertEquals(body.error, 'rate_limited', 'Fehlercode');
    assertEquals(
      stub.rateLimitScopes().join(','),
      'analyze-meal:ip,analyze-meal:user',
      'Gate-Reihenfolge',
    );
    assertEquals(stub.callsTo('openrouter.ai').length, 0, 'Provider-Calls');
  } finally {
    stub.restore();
  }
});

Deno.test('Limiter antwortet 200 ohne allowed -> 500 rate_limit_unavailable', async () => {
  // Sentinel-Rest E6: ein kaputter Antwort-Shape ist ein AUSFALL des
  // Limiters, kein gemessenes Limit — der Request darf nicht durchrutschen.
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
  // Bewusst ohne Aussage darueber, WELCHER der beiden Caps greift: ob die
  // Runtime dem Request ein content-length mitgibt (Fast-Path
  // enforceContentLength) oder nicht (harter Cap in readBodyLimited), ist
  // Plattformsache — die Antwort ist in beiden Faellen dieselbe.
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
  // Zugleich der Nachweis, dass die Secrets PRO REQUEST gelesen werden: beim
  // Modul-Load waere der Wert laengst eingefroren und dieses delete folgenlos.
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
    assertEquals(
      stub.rateLimitScopes().join(','),
      'analyze-meal:ip,analyze-meal:user',
      'Gate-Reihenfolge',
    );
    // Die Tabellen-Hygiene laeuft fire-and-forget mit (und darf den Request
    // nicht abreissen, s. ../_shared/rate_limit_prune.ts).
    assertEquals(stub.callsTo('prune_edge_rate_limits').length, 1, 'Prune-Calls');

    // Shape des Provider-Requests: hier haengt das Geld dran.
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
  } finally {
    stub.restore();
  }
});
