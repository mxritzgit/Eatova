import { userToken } from '../_shared/auth_test_fixtures.ts';
import { handleRequest } from './handler.ts';

const USER = '11111111-1111-4111-8111-111111111111';
const TEXT = 'Pasta\n200 g Pasta\nPasta kochen.';
const VIDEO = 'https://www.tiktok.com/@cook/video/1234567890123456789';
const ENV = {
  SUPABASE_URL: 'https://supabase.test.invalid', SUPABASE_ANON_KEY: 'test-anon-key',
  SUPABASE_SERVICE_ROLE_KEY: 'test-service-key', OPENROUTER_API_KEY: 'test-provider-key',
  EATOVA_ALLOWED_ORIGINS: 'https://app.test.invalid',
};
const MODEL = {
  status: 'ready', candidates: [{ title: 'Pasta', ingredient_quotes: ['200 g Pasta'], preparation_quotes: ['Pasta kochen.'] }],
};
type Call = { url: string; body: Record<string, unknown>; headers: Headers; redirect?: RequestRedirect };
type Options = {
  authStatus?: number; authBody?: unknown; gate?: unknown; budget?: unknown;
  model?: unknown; providerStatus?: number; providerRaw?: string; finishReason?: string;
  metadataStatus?: number; metadata?: unknown;
};

function check(value: unknown, message: string): asserts value {
  if (!value) throw new Error(message);
}
function request(body: unknown = { text: TEXT, locale: 'de' }, auth: string | null = userToken(USER), contentType = 'application/json'): Request {
  return new Request('https://edge.test.invalid/recipe-import', {
    method: 'POST', headers: {
      'content-type': contentType, 'cf-connecting-ip': '203.0.113.1',
      ...(auth ? { authorization: `Bearer ${auth}` } : {}),
    }, body: JSON.stringify(body),
  });
}

async function stub(options: Options, run: (calls: Call[]) => Promise<void>): Promise<void> {
  const original = globalThis.fetch;
  const previous = new Map(Object.keys(ENV).map((key) => [key, Deno.env.get(key)]));
  for (const [key, value] of Object.entries(ENV)) Deno.env.set(key, value);
  const calls: Call[] = [];
  globalThis.fetch = ((url: string | URL | Request, init?: RequestInit) => {
    const target = String(url);
    const body = init?.body ? JSON.parse(String(init.body)) : {};
    calls.push({ url: target, body, headers: new Headers(init?.headers), redirect: init?.redirect });
    if (target.endsWith('/auth/v1/user')) return Promise.resolve(Response.json(options.authBody ?? { id: USER }, { status: options.authStatus ?? 200 }));
    if (target.endsWith('/consume_edge_rate_limit')) return Promise.resolve(Response.json({ allowed: true }));
    if (target.endsWith('/consume_edge_rate_limits')) return Promise.resolve(Response.json(options.gate ?? body.p_gates.map(() => ({ allowed: true }))));
    if (target.endsWith('/reserve_ai_provider_call')) return Promise.resolve(Response.json(options.budget ?? { allowed: true, reason: 'allowed' }));
    if (target.startsWith('https://www.tiktok.com/oembed?')) return Promise.resolve(Response.json(options.metadata ?? { title: TEXT, author_name: 'Cook' }, { status: options.metadataStatus ?? 200 }));
    if (target === 'https://openrouter.ai/api/v1/chat/completions') return Promise.resolve(new Response(options.providerRaw ?? JSON.stringify({ choices: [{ finish_reason: options.finishReason ?? 'stop', message: { content: JSON.stringify(options.model ?? MODEL) } }] }), { status: options.providerStatus ?? 200 }));
    throw new Error('Unexpected outbound request');
  }) as typeof fetch;
  try { await run(calls); }
  finally {
    globalThis.fetch = original;
    for (const [key, value] of previous) {
      if (value === undefined) Deno.env.delete(key); else Deno.env.set(key, value);
    }
  }
}

Deno.test('recipe-import authenticated text succeeds only after independent provider reservation', async () => {
  await stub({}, async (calls) => {
    const response = await handleRequest(request());
    const body = await response.json();
    check(response.status === 200 && body.status === 'ready' && body.candidates.length === 1, 'Successful preview');
    check(body.candidates[0].calories_kcal === null, 'Missing calories are not invented');
    check(calls.at(-2)?.url.endsWith('/reserve_ai_provider_call'), 'Budget immediately precedes provider');
    check(calls.at(-2)?.body.p_operation === 'coach_recipe' && calls.at(-2)?.body.p_user_id === USER, 'Existing shared budget bound to verified account');
    check(calls.every((call) => !/user_recipes|chat_messages|sessions/.test(call.url)), 'No saved-recipe or chat writes');
    check(calls.filter((call) => /auth\/v1\/user|consume_edge_rate_limits/.test(call.url)).every((call) => call.redirect === 'error'), 'Credential-bearing fetches cannot redirect');
    const provider = calls.at(-1)!;
    check(!JSON.stringify(provider.body).includes(ENV.SUPABASE_SERVICE_ROLE_KEY), 'No secret in prompt');
    check(provider.body.max_tokens === 12_000, 'Room for multiple complete recipes');
  });
});

Deno.test('recipe-import canonical video fetches public metadata without auth headers', async () => {
  await stub({}, async (calls) => {
    const response = await handleRequest(request({ text: VIDEO, locale: 'en' }));
    const body = await response.json();
    check(response.status === 200 && body.source.url === VIDEO && body.source.author === 'Cook', 'Caption import');
    const metadata = calls.find((call) => call.url.includes('/oembed?'))!;
    check(!metadata.headers.has('authorization') && !metadata.headers.has('apikey'), 'No app credentials to TikTok');
  });
});

Deno.test('recipe-import missing, anon and service-audience credentials cannot spend quotas or fetch source', async () => {
  for (const token of [null, ENV.SUPABASE_ANON_KEY, userToken(USER, { aud: 'service_role' }), userToken(USER, { sub: '22222222-2222-4222-8222-222222222222' })]) {
    await stub({}, async (calls) => {
      const response = await handleRequest(request({ text: VIDEO, locale: 'de' }, token));
      check(response.status === 401, 'User context required');
      check(calls.every((call) => call.url.endsWith('/auth/v1/user')), 'No protected side effects');
    });
  }
});

Deno.test('recipe-import auth server outage fails closed without masquerading as logout', async () => {
  await stub({ authStatus: 503 }, async (calls) => {
    const response = await handleRequest(request());
    check(response.status === 503 && (await response.json()).error === 'auth_unavailable', 'Transient auth failure');
    check(calls.length === 1, 'No provider or quota calls');
  });
});

Deno.test('recipe-import rejected authenticated lookup consumes only failed-auth gate', async () => {
  await stub({ authStatus: 401 }, async (calls) => {
    const response = await handleRequest(request());
    check(response.status === 401, 'Denied token');
    check(calls.length === 2 && calls[1].body.p_scope === 'recipe-import:auth-fail', 'Failure damper');
  });
});

Deno.test('recipe-import rate-limit denial or malformed batch prevents source fetch and model use', async () => {
  for (const [gate, expected] of [ [[{ allowed: false }], 429], [[{ allowed: true }], 503], [[{ allowed: 'yes' }], 503], [{ allowed: true }, 503] ] as const) {
    await stub({ gate }, async (calls) => {
      const response = await handleRequest(request({ text: VIDEO, locale: 'de' }));
      check(response.status === expected && calls.length === 2, 'Gate fails closed');
      if (expected === 429) check(response.headers.has('retry-after'), 'Retry delay');
    });
  }
});

Deno.test('recipe-import rejects invalid request fields, oversized text and wrong content type before paid work', async () => {
  const invalid = [
    { text: TEXT, locale: 'de', user_id: USER }, { text: TEXT, locale: 'fr' },
    { text: '', locale: 'de' }, { text: 'a'.repeat(20_001), locale: 'de' },
    { text: 'Pasta\u0000secret', locale: 'de' }, { text: 'Pasta\u007fsecret', locale: 'de' },
  ];
  for (const body of invalid) await stub({}, async (calls) => {
    const response = await handleRequest(request(body));
    check(response.status === 400 && calls.length === 2, 'Invalid shape rejected');
  });
  await stub({}, async (calls) => {
    const response = await handleRequest(request(undefined, userToken(USER), 'text/plain'));
    check(response.status === 415 && calls.length === 2, 'JSON required');
  });
});

Deno.test('recipe-import request stream limit rejects dishonest content-length', async () => {
  await stub({}, async (calls) => {
    const response = await handleRequest(request({ text: 'a'.repeat(90_001), locale: 'de' }));
    check(response.status === 413 && calls.length === 2, 'Byte cap enforced without header');
  });
});

Deno.test('recipe-import inaccessible or unsupported link asks for text without paid calls', async () => {
  for (const text of [VIDEO, 'https://private.invalid/recipe']) await stub({ metadataStatus: 403 }, async (calls) => {
    const response = await handleRequest(request({ text, locale: 'de' }));
    const body = await response.json();
    check(response.status === 200 && body.status === 'needs_text' && body.candidates.length === 0, 'Honest fallback');
    check(!calls.some((call) => call.url.includes('reserve_ai_provider_call') || call.url.includes('openrouter.ai')), 'No paid call for absent content');
  });
});

Deno.test('recipe-import provider budget exhaustion, disabled and outage all fail closed', async () => {
  for (const [budget, expected, error] of [
    [{ allowed: false, reason: 'budget_exhausted' }, 429, 'ai_budget_exhausted'],
    [{ allowed: false, reason: 'disabled' }, 503, 'ai_disabled'],
    [{ allowed: true }, 503, 'ai_budget_unavailable'],
  ] as const) await stub({ budget }, async (calls) => {
    const response = await handleRequest(request());
    check(response.status === expected && (await response.json()).error === error, 'Budget error preserved');
    check(!calls.some((call) => call.url.includes('openrouter.ai')), 'No unreserved provider call');
  });
});

Deno.test('recipe-import three recipes and vegan variant are all returned for explicit choice', async () => {
  const candidates = [MODEL.candidates[0],
    { title: 'Tofu', variant_label: 'Vegan', ingredient_quotes: ['200 g Tofu'], preparation_quotes: ['Tofu braten.'] },
    { title: 'Reis', ingredient_quotes: ['100 g Reis'], preparation_quotes: ['Reis kochen.'] },
  ];
  await stub({ model: { status: 'ready', candidates } }, async () => {
    const response = await handleRequest(request({ text: `${TEXT}\nVegan\n200 g Tofu\nTofu braten.\n100 g Reis\nReis kochen.`, locale: 'de' }));
    const result = await response.json();
    check(result.candidates.length === 3 && result.candidates[1].variant_label === 'Vegan', 'All alternatives returned');
  });
});

Deno.test('recipe-import upstream errors and truncated model answers expose no source or credentials', async () => {
  for (const options of [
    { providerStatus: 500, providerRaw: 'PRIVATE-RECIPE-CONTENT secret' },
    { providerRaw: 'PRIVATE-RECIPE-CONTENT secret' },
    { finishReason: 'length' }, { model: { status: 'ready', candidates: {} } },
  ]) await stub(options, async () => {
    const response = await handleRequest(request());
    const body = await response.text();
    check(response.status === 502 && !body.includes('PRIVATE') && !body.includes('secret'), 'Sanitized provider failure');
  });
});

Deno.test('recipe-import invented model steps fail source-proof validation', async () => {
  await stub({ model: { status: 'ready', candidates: [{ ...MODEL.candidates[0], preparation_quotes: ['Brate das Hähnchen.'] }] } }, async () => {
    const response = await handleRequest(request());
    const result = await response.json();
    check(result.status === 'needs_text' && result.candidates.length === 0, 'No fabricated cooking instructions');
  });
});

Deno.test('recipe-import exact CORS origin and no-store apply to preflight and rejected requests', async () => {
  await stub({}, async (calls) => {
    for (const origin of ['https://app.test.invalid', 'https://app.test.invalid.attacker.invalid']) {
      for (const method of ['OPTIONS', 'POST']) {
        const response = await handleRequest(new Request('https://edge.test.invalid/recipe-import', { method, headers: { origin } }));
        check(response.headers.get('access-control-allow-origin') === (origin === ENV.EATOVA_ALLOWED_ORIGINS ? origin : null), 'Exact origin');
        check(response.headers.get('cache-control') === 'no-store', 'No caching private recipes');
        check(response.status === (method === 'OPTIONS' ? 204 : 401), 'Preflight does not authorize');
      }
    }
    check(calls.length === 0, 'No side effects');
  });
});
