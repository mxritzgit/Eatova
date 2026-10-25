// resolvePlan reads resolve_plan strictly and falls back to Free on anything
// else; the limit helpers build the planLimit wire object. No network:
// fetch is stubbed and restored per test.
import {
  FREE_FALLBACK,
  limitFor,
  nextUtcMidnightIso,
  type PlanFeature,
  planLimitWire,
  premiumLimitFor,
  type ResolvedPlan,
  resolvePlan,
} from './plan.ts';

const USER = '11111111-1111-4111-8111-111111111111';
const options = { supabaseUrl: 'https://plan.invalid', serviceKey: 'test-service-key', userId: USER };

function assert(value: boolean, message: string): void {
  if (!value) throw new Error(message);
}

function assertJson(actual: unknown, expected: unknown, message: string): void {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a !== e) throw new Error(`${message}: expected ${e}, got ${a}`);
}

const LEGACY_ANSWER = {
  tier: 'free', legacy: true,
  coach_daily: 5, meal_analysis_daily: 100, recipe_import_daily: 20,
  provider_calls_daily: 150, recipe_picture: true,
  premium: { coach_daily: 20, meal_analysis_daily: 100, recipe_import_daily: 20, recipe_picture: true },
};

/** Runs `run` with fetch answering `respond` and console.error recorded. */
async function withFetch(
  respond: (input: string, init: RequestInit) => Response | Promise<Response>,
  run: (errors: string[]) => Promise<void>,
): Promise<void> {
  const savedFetch = globalThis.fetch;
  const savedError = console.error;
  const errors: string[] = [];
  globalThis.fetch = ((input: string | URL | Request, init?: RequestInit) =>
    Promise.resolve(respond(String(input), init ?? {}))) as typeof fetch;
  console.error = (...args: unknown[]) => { errors.push(args.map(String).join(' ')); };
  try {
    await run(errors);
  } finally {
    globalThis.fetch = savedFetch;
    console.error = savedError;
  }
}

Deno.test('resolvePlan reads the account plan with the service key, never following a redirect', async () => {
  let seen: { url: string; init: RequestInit } | undefined;
  await withFetch((url, init) => {
    seen = { url, init };
    return Response.json(LEGACY_ANSWER);
  }, async (errors) => {
    const plan = await resolvePlan({ ...options, signal: new AbortController().signal });
    assertJson(plan, {
      coachDaily: 5, mealAnalysisDaily: 100, recipeImportDaily: 20, recipePicture: true,
      tier: 'free', legacy: true, providerCallsDaily: 150,
      premium: { coachDaily: 20, mealAnalysisDaily: 100, recipeImportDaily: 20, recipePicture: true },
      fallback: false,
    }, 'mapped plan');
    assert(errors.length === 0, 'no log on success');
  });
  const headers = new Headers(seen?.init.headers);
  assert(seen?.url === 'https://plan.invalid/rest/v1/rpc/resolve_plan', 'resolve_plan RPC');
  assert(headers.get('authorization') === 'Bearer test-service-key' && headers.get('apikey') === 'test-service-key', 'service key');
  assert(seen?.init.redirect === 'error', 'no redirect with the service key');
  assert(seen?.init.signal instanceof AbortSignal, 'bounded call');
  assertJson(JSON.parse(String(seen?.init.body)), { p_user_id: USER }, 'only the user id is sent');
});

Deno.test('resolvePlan falls back to Free for every failed or malformed answer, logging no detail', async () => {
  const broken = (patch: Record<string, unknown>) => JSON.stringify({ ...LEGACY_ANSWER, ...patch });
  const cases: Array<[string, () => Response | Promise<Response>]> = [
    ['HTTP 500', () => new Response(`{"message":"secret ${USER}"}`, { status: 500 })],
    ['not JSON', () => new Response('<html>')],
    ['array', () => new Response('[]')],
    ['null', () => new Response('null')],
    ['oversized', () => new Response(' '.repeat(5000) + JSON.stringify(LEGACY_ANSWER))],
    ['unknown tier', () => new Response(broken({ tier: 'legacy' }))],
    ['zero limit', () => new Response(broken({ coach_daily: 0 }))],
    ['fractional limit', () => new Response(broken({ meal_analysis_daily: 4.5 }))],
    ['limit above the bound', () => new Response(broken({ recipe_import_daily: 10001 }))],
    ['numeric string', () => new Response(broken({ coach_daily: '3' }))],
    ['negative provider calls', () => new Response(broken({ provider_calls_daily: -1 }))],
    ['picture as string', () => new Response(broken({ recipe_picture: 'true' }))],
    ['legacy missing', () => new Response(broken({ legacy: undefined }))],
    ['premium missing', () => new Response(broken({ premium: undefined }))],
    ['premium incomplete', () => new Response(broken({ premium: { coach_daily: 20 } }))],
    ['transport error', () => Promise.reject(new TypeError('connection refused'))],
  ];
  for (const [label, respond] of cases) {
    await withFetch(respond, async (errors) => {
      const plan = await resolvePlan({ ...options, signal: new AbortController().signal });
      assert(plan === FREE_FALLBACK, `${label}: Free fallback`);
      assertJson(errors, ['resolve_plan unavailable'], `${label}: one sanitized log line`);
    });
  }
});

Deno.test('resolvePlan gives up on a stalled body at the caller deadline', async () => {
  let cancelled = false;
  await withFetch(() => new Response(new ReadableStream<Uint8Array>({
    start(controller) { controller.enqueue(new TextEncoder().encode('{"tier":')); },
    cancel() { cancelled = true; },
  })), async () => {
    const plan = await resolvePlan({ ...options, signal: AbortSignal.timeout(20) });
    assert(plan === FREE_FALLBACK, 'fallback after the deadline');
  });
  assert(cancelled, 'the stalled body is cancelled');
});

Deno.test('FREE_FALLBACK carries the decided Free and Premium values and cannot be changed', () => {
  assertJson(FREE_FALLBACK, {
    tier: 'free', legacy: false, coachDaily: 3, mealAnalysisDaily: 4, recipeImportDaily: 2,
    providerCallsDaily: 30, recipePicture: false,
    premium: { coachDaily: 20, mealAnalysisDaily: 30, recipeImportDaily: 10, recipePicture: true },
    fallback: true,
  }, 'decided defaults');
  assert(Object.isFrozen(FREE_FALLBACK) && Object.isFrozen(FREE_FALLBACK.premium), 'frozen');
});

Deno.test('planLimitWire offers the Premium limit only to Free accounts that would gain', () => {
  const free: ResolvedPlan = { ...FREE_FALLBACK, fallback: false };
  const premium: ResolvedPlan = {
    ...FREE_FALLBACK, tier: 'premium', coachDaily: 20, mealAnalysisDaily: 30, recipeImportDaily: 10,
    providerCallsDaily: 150, recipePicture: true, fallback: false,
  };
  const legacy: ResolvedPlan = {
    ...FREE_FALLBACK, legacy: true, coachDaily: 5, mealAnalysisDaily: 100, recipeImportDaily: 20,
    premium: { coachDaily: 20, mealAnalysisDaily: 100, recipeImportDaily: 20, recipePicture: true },
    fallback: false,
  };
  const resetAt = '2026-10-26T00:00:00.000Z';
  const cases: Array<[ResolvedPlan, PlanFeature, unknown]> = [
    [free, 'coach', { feature: 'coach', tier: 'free', limit: 3, resetAt, premiumLimit: 20 }],
    [free, 'meal_analysis', { feature: 'meal_analysis', tier: 'free', limit: 4, resetAt, premiumLimit: 30 }],
    [free, 'recipe_import', { feature: 'recipe_import', tier: 'free', limit: 2, resetAt, premiumLimit: 10 }],
    // A failed lookup says nothing about the account: no upgrade offer.
    [FREE_FALLBACK, 'coach', { feature: 'coach', tier: 'free', limit: 3, resetAt }],
    [premium, 'coach', { feature: 'coach', tier: 'premium', limit: 20, resetAt }],
    [legacy, 'coach', { feature: 'coach', tier: 'free', limit: 5, resetAt, premiumLimit: 20 }],
    // Premium would not raise a legacy account's analyses: no upgrade offer.
    [legacy, 'meal_analysis', { feature: 'meal_analysis', tier: 'free', limit: 100, resetAt }],
  ];
  for (const [plan, feature, expected] of cases) {
    assertJson(planLimitWire(plan, feature, resetAt), expected, `${plan.tier}/${plan.legacy}/${plan.fallback}/${feature}`);
  }
  assert(limitFor(legacy, 'recipe_import') === 20 && premiumLimitFor(FREE_FALLBACK, 'recipe_import') === 10, 'limit lookups');
});

Deno.test('nextUtcMidnightIso is the next 00:00 UTC, across month and year ends', () => {
  const cases: Array<[string, string]> = [
    ['2026-10-25T23:59:59.999Z', '2026-10-26T00:00:00.000Z'],
    ['2026-10-26T00:00:00.000Z', '2026-10-27T00:00:00.000Z'],
    ['2026-10-31T12:00:00.000Z', '2026-11-01T00:00:00.000Z'],
    ['2026-12-31T22:30:00.000Z', '2027-01-01T00:00:00.000Z'],
  ];
  for (const [now, expected] of cases) {
    assert(nextUtcMidnightIso(Date.parse(now)) === expected, `${now} -> ${expected}`);
  }
});
