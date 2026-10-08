import { resetAuthFailCacheForTests } from '../_shared/auth_fail_gate.ts';
import { userToken } from '../_shared/auth_test_fixtures.ts';
import { handleRequest, PROVIDER_TIMINGS_MS } from './handler.ts';
import { CLAUDE_URL, claudeResponse, isClaudeCall, outputSchema } from '../_shared/claude_test_fixtures.ts';
import { extractionPrompt } from './extraction.ts';
import { extractionSchema } from './schema.ts';

const USER = '11111111-1111-4111-8111-111111111111';
const TEXT = 'Pasta\n200 g Pasta\nPasta kochen.';
const VIDEO = 'https://www.tiktok.com/@cook/video/1234567890123456789';
const ENV = {
  SUPABASE_URL: 'https://supabase.test.invalid', SUPABASE_ANON_KEY: 'test-anon-key',
  SUPABASE_SERVICE_ROLE_KEY: 'test-service-key', ANTHROPIC_API_KEY: 'test-provider-key',
  EATOVA_ALLOWED_ORIGINS: 'https://app.test.invalid',
};
const MODEL = {
  status: 'ready', candidates: [{ title: 'Pasta', ingredient_quotes: ['200 g Pasta'], preparation_quotes: ['Pasta kochen.'] }],
};
type Call = { url: string; body: Record<string, unknown>; headers: Headers; redirect?: RequestRedirect };
type Options = {
  authStatus?: number; authBody?: unknown; gate?: unknown; budget?: unknown;
  authCancelStall?: boolean; gateCancelStall?: boolean; providerCancelStall?: boolean;
  // finishReason uses the handler's vocabulary ("stop", "length", ...);
  // claudeResponse turns it into the matching stop_reason.
  model?: unknown; providerStatus?: number; providerRaw?: string; finishReason?: string | null;
  // The provider never answers; the call ends only when its signal aborts.
  providerHang?: boolean;
  providerSequence?: Array<{ status?: number; raw?: string }>;
  budgetSequence?: unknown[];
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
    if (target.endsWith('/auth/v1/user')) {
      if (options.authCancelStall) return Promise.resolve(new Response(new ReadableStream<Uint8Array>({
        cancel() { return new Promise<void>(() => {}); },
      }), { status: 503 }));
      return Promise.resolve(Response.json(options.authBody ?? { id: USER }, { status: options.authStatus ?? 200 }));
    }
    if (target.endsWith('/consume_edge_rate_limit')) return Promise.resolve(Response.json({ allowed: true }));
    if (target.endsWith('/consume_edge_rate_limits')) {
      if (options.gateCancelStall) return Promise.resolve(new Response(new ReadableStream<Uint8Array>({
        cancel() { return new Promise<void>(() => {}); },
      }), { status: 503 }));
      return Promise.resolve(Response.json(options.gate ?? body.p_gates.map(() => ({ allowed: true }))));
    }
    if (target.endsWith('/reserve_ai_provider_call')) return Promise.resolve(Response.json(options.budgetSequence?.[calls.filter((c) => c.url.endsWith('/reserve_ai_provider_call')).length - 1] ?? options.budget ?? { allowed: true, reason: 'allowed' }));
    if (target.startsWith('https://www.tiktok.com/oembed?')) return Promise.resolve(Response.json(options.metadata ?? { title: TEXT, author_name: 'Cook' }, { status: options.metadataStatus ?? 200 }));
    if (isClaudeCall(target)) {
      if (options.providerHang) {
        return new Promise<Response>((_, reject) => {
          init?.signal?.addEventListener('abort', () => reject(init.signal!.reason), { once: true });
        });
      }
      if (options.providerCancelStall) return Promise.resolve(new Response(new ReadableStream<Uint8Array>({
        cancel() { return new Promise<void>(() => {}); },
      }), { status: 400 }));
      const next = options.providerSequence?.[calls.filter((c) => c.url === target).length - 1];
      const answer = claudeResponse(JSON.stringify(options.model ?? MODEL), options.finishReason === undefined ? 'stop' : options.finishReason);
      return Promise.resolve(new Response(next?.raw ?? options.providerRaw ?? JSON.stringify(answer), { status: next?.status ?? options.providerStatus ?? 200 }));
    }
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

Deno.test('recipe-import auth outage responds despite a stalled body cancellation', async () => {
  await stub({ authCancelStall: true }, async (calls) => {
    let timer: ReturnType<typeof setTimeout> | undefined;
    try {
      const response = await Promise.race([
        handleRequest(request()),
        new Promise<Response>((_resolve, reject) => {
          timer = setTimeout(() => reject(new Error('auth waited for stalled body.cancel()')), 1000);
        }),
      ]);
      check(response.status === 503 && (await response.json()).error === 'auth_unavailable', 'bounded auth outage');
      check(calls.length === 1, 'No provider or quota calls');
    } finally { clearTimeout(timer); }
  });
});

Deno.test('recipe-import limiter and provider errors do not wait for stalled body cancellation', async () => {
  for (const [options, expectedStatus, expectedCode, expectedCalls] of [
    [{ gateCancelStall: true }, 503, 'rate_limit_unavailable', 2],
    [{ providerCancelStall: true }, 502, 'provider_unavailable', 5],
  ] as const) {
    await stub(options, async (calls) => {
      let timer: ReturnType<typeof setTimeout> | undefined;
      try {
        const response = await Promise.race([
          handleRequest(request()),
          new Promise<Response>((_resolve, reject) => {
            timer = setTimeout(() => reject(new Error('error path waited for stalled body.cancel()')), 1000);
          }),
        ]);
        check(response.status === expectedStatus && (await response.json()).error === expectedCode, 'bounded upstream error');
        check(calls.length === expectedCalls, 'no excess provider call');
      } finally { clearTimeout(timer); }
    });
  }
});

Deno.test('recipe-import rejected authenticated lookup consumes only failed-auth gate', async () => {
  await stub({ authStatus: 401 }, async (calls) => {
    const response = await handleRequest(request());
    check(response.status === 401, 'Denied token');
    check(calls.length === 2 && calls[1].body.p_scope === 'recipe-import:auth-fail', 'Failure damper');
  });
});

Deno.test('recipe-import P7-02: a replayed revoked token costs at most two lookups', async () => {
  resetAuthFailCacheForTests();
  try {
    await stub({ authStatus: 401 }, async (calls) => {
      const token = userToken(USER);
      for (let i = 0; i < 10; i++) {
        const response = await handleRequest(request(undefined, token));
        check(response.status === 401, 'Still a denied token');
      }
      const lookups = calls.filter((call) => call.url.endsWith('/auth/v1/user')).length;
      const upserts = calls.filter((call) => call.url.endsWith('/consume_edge_rate_limit')).length;
      check(lookups <= 2, `GoTrue lookups: expected at most 2, got ${lookups}`);
      check(upserts <= 2, `Limiter upserts: expected at most 2, got ${upserts}`);
    });
  } finally {
    resetAuthFailCacheForTests();
  }
});

Deno.test('recipe-import P7-02: a valid token from the same address is still looked up', async () => {
  resetAuthFailCacheForTests();
  try {
    await stub({ authStatus: 401 }, async () => {
      for (let i = 0; i < 3; i++) await handleRequest(request(undefined, userToken(USER)));
    });
    const other = '22222222-2222-4222-8222-222222222222';
    await stub({ authBody: { id: other } }, async (calls) => {
      const response = await handleRequest(request(undefined, userToken(other)));
      check(response.status === 200, `Valid token: expected 200, got ${response.status}`);
      check(calls.some((call) => call.url.endsWith('/auth/v1/user')), 'A new token is looked up');
    });
  } finally {
    resetAuthFailCacheForTests();
  }
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
    check(!calls.some((call) => call.url.includes('reserve_ai_provider_call') || isClaudeCall(call.url)), 'No paid call for absent content');
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
    check(!calls.some((call) => isClaudeCall(call.url)), 'No unreserved provider call');
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

Deno.test('recipe-import retries malformed or transient provider results with a fresh reservation', async () => {
  // A transient status, a broken envelope and a complete but unusable answer
  // may come out differently on a second, separately reserved attempt.
  for (const first of [{ status: 503, raw: 'unavailable' }, { raw: '{"broken":' },
    { raw: JSON.stringify(claudeResponse('{}', 'stop')) }]) {
    await stub({ providerSequence: [first, {}] }, async (calls) => {
      const response = await handleRequest(request());
      check(response.status === 200 && (await response.json()).status === 'ready', 'Retry recovered');
      const providers = calls.filter((c) => isClaudeCall(c.url));
      check(providers.length === 2 && calls.filter((c) => c.url.endsWith('/reserve_ai_provider_call')).length === 2, 'Each attempt reserved independently');
      for (const provider of providers) {
        // Claude structured outputs are always strict: the schema itself is the contract.
        const format = (provider.body.output_config as { format: { type: string } }).format;
        check(format.type === 'json_schema' && JSON.stringify(outputSchema(provider.body)) === JSON.stringify(extractionSchema), 'Structured schema requested');
        // Direct Messages API call: no gateway routing object any more.
        check(provider.url === CLAUDE_URL && !('provider' in provider.body), 'Direct provider route');
      }
    });
  }
});

Deno.test('recipe-import retry never bypasses a denied budget or a permanent provider error', async () => {
  await stub({ providerSequence: [{ raw: 'invalid JSON' }],
    budgetSequence: [{ allowed: true, reason: 'allowed' }, { allowed: false, reason: 'budget_exhausted' }],
  }, async (calls) => {
    const response = await handleRequest(request());
    check(response.status === 429, 'Second reservation fails closed');
    check(calls.filter((c) => isClaudeCall(c.url)).length === 1, 'No unreserved second request');
  });
  await stub({ providerStatus: 400 }, async (calls) => {
    check((await handleRequest(request())).status === 502, 'Permanent provider failure');
    check(calls.filter((c) => isClaudeCall(c.url)).length === 1, 'No futile permanent-error retries');
  });
});

Deno.test('recipe-import v2 explicitly supports ingredient-only and unqualified caption nutrition', async () => {
  const model = { status: 'ready', candidates: [{ ...MODEL.candidates[0],
    preparation_quotes: [], nutrition_basis: 'unspecified', nutrition_quote: '450 kcal, 30 g Protein.',
    calories_kcal: 450, protein_g: 30,
  }] };
  await stub({ model }, async () => {
    const response = await handleRequest(request({ text: TEXT + '\n450 kcal, 30 g Protein.', locale: 'de', version: 2 }));
    const body = await response.json();
    check(body.status === 'ready' && body.candidates[0].preparation === '', 'Missing steps stay empty');
    check(body.candidates[0].nutrition_basis === 'unspecified' && body.candidates[0].protein_g === 30, 'Basis retained, not guessed');
  });
  await stub({ model }, async () => {
    const response = await handleRequest(request({ text: TEXT + '\n450 kcal, 30 g Protein.', locale: 'de' }));
    check((await response.json()).status === 'needs_text', 'Older clients keep their compatible contract');
  });
});

Deno.test('recipe-import accepts only end_turn: a valid recipe cut at max_tokens, refused or unfinished is no result and no retry', async () => {
  // The model text below is a complete, source-proven recipe; only the
  // stop_reason says it is not final. A decline or a cut-off answer would
  // repeat, so a second paid attempt is never made for it.
  for (const finishReason of ['length', 'content_filter', 'model_context_window_exceeded', 'pause_turn', 'tool_calls', null]) {
    await stub({ finishReason }, async (calls) => {
      const response = await handleRequest(request());
      const body = await response.text();
      check(response.status === 502 && JSON.parse(body).error === 'provider_invalid_response', `${finishReason}: ${response.status} ${body}`);
      check(!body.includes('Pasta kochen'), `${finishReason}: no partial recipe leaks`);
      check(calls.filter((c) => isClaudeCall(c.url)).length === 1, `${finishReason}: no second attempt`);
      check(calls.filter((c) => c.url.endsWith('/reserve_ai_provider_call')).length === 1, `${finishReason}: one reservation`);
    });
  }
  // Even when a second answer would be complete, a cut-off one is not retried.
  await stub({ providerSequence: [{ raw: JSON.stringify(claudeResponse(JSON.stringify(MODEL), 'length')) }, {}] }, async (calls) => {
    const response = await handleRequest(request());
    check(response.status === 502, 'max_tokens is final');
    check(calls.filter((c) => isClaudeCall(c.url)).length === 1, 'no retry after max_tokens');
  });
});

Deno.test('recipe-import never pays for a second attempt that cannot finish in time', async () => {
  const saved = { ...PROVIDER_TIMINGS_MS };
  try {
    // A timeout uses up the window: 504 after one paid attempt.
    PROVIDER_TIMINGS_MS.window = 60;
    PROVIDER_TIMINGS_MS.retryMin = 10;
    await stub({ providerHang: true }, async (calls) => {
      const response = await handleRequest(request());
      check(response.status === 504 && (await response.json()).error === 'request_timeout', 'timeout');
      check(calls.filter((c) => isClaudeCall(c.url)).length === 1, 'no retry after a timeout');
      check(calls.filter((c) => c.url.endsWith('/reserve_ai_provider_call')).length === 1, 'one reservation');
    });
    // A retryable failure with too little window left is not retried either.
    PROVIDER_TIMINGS_MS.window = 5_000;
    PROVIDER_TIMINGS_MS.retryMin = 10_000;
    await stub({ providerSequence: [{ status: 503, raw: 'unavailable' }, {}] }, async (calls) => {
      const response = await handleRequest(request());
      check(response.status === 502, 'outage reported');
      check(calls.filter((c) => isClaudeCall(c.url)).length === 1, 'no retry without enough time');
    });
  } finally {
    Object.assign(PROVIDER_TIMINGS_MS, saved);
  }
});

Deno.test('recipe-import without ANTHROPIC_API_KEY is not configured, whatever former provider key remains', async () => {
  await stub({}, async (calls) => {
    const previous = Deno.env.get('OPENROUTER_API_KEY');
    Deno.env.delete('ANTHROPIC_API_KEY');
    Deno.env.set('OPENROUTER_API_KEY', 'stale-former-provider-key');
    try {
      const response = await handleRequest(request());
      check(response.status === 503 && (await response.json()).error === 'not_configured', 'Claude key required');
      check(calls.length === 0, 'No auth, quota or provider call');
    } finally {
      if (previous === undefined) Deno.env.delete('OPENROUTER_API_KEY');
      else Deno.env.set('OPENROUTER_API_KEY', previous);
    }
  });
});

Deno.test('recipe-import request carries extractionSchema, the cached extraction prompt and no sampling', async () => {
  for (const locale of ['de', 'en'] as const) {
    await stub({}, async (calls) => {
      const response = await handleRequest(request({ text: TEXT, locale }));
      check(response.status === 200, `${locale}: status ${response.status}`);
      const provider = calls.find((c) => isClaudeCall(c.url))!;
      check(provider.url === CLAUDE_URL && provider.redirect === 'error', 'Messages API, no redirects');
      check(provider.headers.get('x-api-key') === ENV.ANTHROPIC_API_KEY && provider.headers.get('anthropic-version') === '2023-06-01', 'Claude headers');
      check(!provider.headers.has('authorization'), 'No bearer credential');
      const body = provider.body;
      check(Object.keys(body).sort().join(',') === 'max_tokens,messages,model,output_config,system,thinking', `request fields: ${Object.keys(body)}`);
      check(body.model === 'claude-sonnet-5-5' && body.max_tokens === 12_000, 'model and output cap');
      check(JSON.stringify(body.thinking) === '{"type":"adaptive"}', 'adaptive thinking');
      check(JSON.stringify(body.output_config) === JSON.stringify({ effort: 'medium', format: { type: 'json_schema', schema: extractionSchema } }),
        'effort medium and extractionSchema');
      // The whole prompt is one cached block; the source text is user data.
      check(JSON.stringify(body.system) === JSON.stringify([{ type: 'text', text: extractionPrompt(locale), cache_control: { type: 'ephemeral' } }]),
        `${locale}: cached extraction prompt`);
      check(JSON.stringify(body.messages) === JSON.stringify([{ role: 'user', content: JSON.stringify({ source_text: TEXT }) }]), 'source as user data');
      check(!JSON.stringify(body.system).includes('200 g Pasta'), 'source never in the system prompt');
    });
  }
});
