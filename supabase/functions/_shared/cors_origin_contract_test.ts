const allowed = 'https://synthetic-app.invalid';
const originalServe = Object.getOwnPropertyDescriptor(Deno, 'serve')!;
const originalFetch = globalThis.fetch;
const originalOrigins = Deno.env.get('EATOVA_ALLOWED_ORIGINS');
type Handler = (request: Request) => Response | Promise<Response>;
function check(value: boolean, label: string): asserts value {
  if (!value) throw new Error(label);
}

Deno.test('CORS: exact origins on preflight and auth denials; no cookie credentials', async () => {
  const config = {
    SUPABASE_URL: 'https://supabase.test.invalid',
    SUPABASE_ANON_KEY: 'test-anon-key',
    SUPABASE_SERVICE_ROLE_KEY: 'test-service-key',
    OPENROUTER_API_KEY: 'test-provider-key',
    EATOVA_MIRROR_SEARCH_KEY: 'synthetic-search-key',
  };
  const previous = new Map(Object.keys(config).map((key) => [key, Deno.env.get(key)]));
  for (const [key, value] of Object.entries(config)) Deno.env.set(key, value);
  const intercepted: Handler[] = [];
  let requests = 0;
  globalThis.fetch = (() => { requests++; throw new Error('No outbound request permitted'); }) as typeof fetch;
  Deno.env.set('EATOVA_ALLOWED_ORIGINS', ` ${allowed} , https://second.invalid `);
  Object.defineProperty(Deno, 'serve', {
    configurable: true,
    value: (...args: unknown[]) => {
      const handler = args.find((arg) => typeof arg === 'function');
      check(typeof handler === 'function', 'Missing server callback');
      intercepted.push(handler as Handler);
      return { finished: Promise.resolve(), shutdown: () => Promise.resolve(), ref() {}, unref() {} };
    },
  });
  try {
    const coach = await import('../coach-chat/handler.ts?cors_origin_contract');
    const analyze = await import('../analyze-meal/handler.ts?cors_origin_contract');
    await import('../search-key/index.ts?cors_origin_contract');
    check(intercepted.length === 1, 'Search handler registration');
    const handlers: Array<[string, Handler, string]> = [
      ['coach', coach.handleRequest, 'POST'],
      ['analyze', analyze.handleRequest, 'POST'],
      ['search', intercepted[0], 'GET'],
    ];
    for (const [name, handler, method] of handlers) {
      for (const origin of [allowed, 'https://second.invalid', undefined, 'null', 'https://synthetic-app.invalid.attacker.invalid', 'https://sub.synthetic-app.invalid', 'http://synthetic-app.invalid', 'https://synthetic-app.invalid:444']) {
        for (const verb of ['OPTIONS', method]) {
          const response = await handler(new Request(`https://edge.test.invalid/${name}`, {
            method: verb, headers: origin ? { origin } : {},
          }));
          const permitted = origin === allowed || origin === 'https://second.invalid';
          check(response.headers.get('access-control-allow-origin') === (permitted ? origin : null), `${name} ${verb}: exact origin`);
          check(!response.headers.has('access-control-allow-credentials'), `${name}: no cookie credentials`);
          check(response.headers.get('cache-control') === 'no-store', `${name}: no response caching`);
          if (permitted) check(response.headers.get('vary')?.toLowerCase().includes('origin') === true, `${name}: vary by origin`);
          if (verb !== 'OPTIONS') check(response.status === 401, `${name}: CORS does not authorize a request`);
          await response.body?.cancel();
        }
      }
    }
    check(requests === 0, 'No network side effect');
  } finally {
    for (const [key, value] of previous) {
      if (value === undefined) Deno.env.delete(key);
      else Deno.env.set(key, value);
    }
    globalThis.fetch = originalFetch;
    Object.defineProperty(Deno, 'serve', originalServe);
    if (originalOrigins === undefined) Deno.env.delete('EATOVA_ALLOWED_ORIGINS');
    else Deno.env.set('EATOVA_ALLOWED_ORIGINS', originalOrigins);
  }
});
