// ai_call telemetry of analyze-meal (../_shared/ai_telemetry.ts): one line per
// paid call, photo and describe mode, success and failure. Before this, usage
// reached the log only on the empty-answer path. No refund exists here, so
// `refunded` is always false. Offline stubs; `deno test --allow-env`.

import { handleRequest } from './handler.ts';
import { resetAuthFailCacheForTests } from '../_shared/auth_fail_gate.ts';
import { userToken } from '../_shared/auth_test_fixtures.ts';
import { claudeResponse, isClaudeCall } from '../_shared/claude_test_fixtures.ts';
import { PNG_BASE64 } from './image_fixtures.ts';

const USER_ID = '11111111-1111-4111-8111-111111111111';
const CLIENT_IP = '203.0.113.88';
/** Stands in for the user's words and hint; must never reach an ai_call line. */
const PROBE = 'PROBE-Mahlzeit-Diabetes-4711';

Deno.env.set('SUPABASE_URL', 'https://supabase.test.invalid');
Deno.env.set('SUPABASE_ANON_KEY', 'test-anon-key');
Deno.env.set('SUPABASE_SERVICE_ROLE_KEY', 'test-service-key');
Deno.env.set('ANTHROPIC_API_KEY', 'test-anthropic-key');

type JsonRecord = Record<string, unknown>;

const MEAL = {
  mealName: 'Steak mit Kartoffeln', caloriesKcal: 780, estimatedGrams: 300, kcalPer100G: 260,
  proteinG: 45, carbsG: 30, fatG: 40, confidence: 'high', explanation: 'Teller als Referenz.',
  slotHint: 'dinner',
  items: [{
    name: 'Steak', grams: 300, caloriesKcal: 780, kcalPer100G: 260, proteinG: 45, carbsG: 30, fatG: 40,
    searchQuery: 'Steak', brand: null, amountText: null, gramsSource: 'estimated',
  }],
};

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

function assertEquals(actual: unknown, expected: unknown, message: string): void {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(`${message}: erwartet ${JSON.stringify(expected)}, war ${JSON.stringify(actual)}`);
  }
}

function jsonRes(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), { status, headers: { 'content-type': 'application/json' } });
}

async function run(body: JsonRecord, provider: () => Response): Promise<{ status: number; lines: JsonRecord[] }> {
  resetAuthFailCacheForTests();
  const originalFetch = globalThis.fetch;
  const original = { log: console.log, warn: console.warn, error: console.error };
  const logs: string[] = [];
  const record = (...args: unknown[]) => logs.push(args.map((arg) => typeof arg === 'string' ? arg : JSON.stringify(arg)).join(' '));
  console.log = record;
  console.warn = record;
  console.error = record;
  globalThis.fetch = ((input: string | URL | Request, init?: RequestInit): Promise<Response> => {
    const url = String(input instanceof Request ? input.url : input);
    const payload = typeof init?.body === 'string' ? JSON.parse(init.body) as JsonRecord : {};
    if (url.includes('/auth/v1/user')) return Promise.resolve(jsonRes({ id: USER_ID }));
    if (url.includes('/rpc/consume_edge_rate_limits')) {
      return Promise.resolve(jsonRes((payload.p_gates as JsonRecord[]).map((gate) => ({
        allowed: true, limit: gate.limit, remaining: 1,
        resetAt: new Date(Date.now() + 600_000).toISOString(), windowSeconds: gate.window_seconds,
      }))));
    }
    if (url.includes('/rpc/reserve_ai_provider_call')) return Promise.resolve(jsonRes({ allowed: true, reason: 'allowed' }));
    if (url.includes('/rpc/prune_edge_rate_limits')) return Promise.resolve(new Response(null, { status: 204 }));
    if (isClaudeCall(url)) return Promise.resolve(provider());
    throw new Error(`Unerwarteter fetch: ${url}`);
  }) as typeof fetch;
  try {
    const response = await handleRequest(new Request('https://edge.test.invalid/analyze-meal', {
      method: 'POST',
      headers: {
        authorization: `Bearer ${userToken(USER_ID)}`,
        'content-type': 'application/json',
        'cf-connecting-ip': CLIENT_IP,
      },
      body: JSON.stringify(body),
    }));
    await response.body?.cancel();
    const lines = logs.filter((line) => line.startsWith('{"event":"ai_call"'));
    for (const line of lines) {
      for (const secret of [PROBE, 'Diabetes', USER_ID, CLIENT_IP]) {
        assert(!line.includes(secret), `ai_call-Zeile enthaelt ${secret}: ${line}`);
      }
    }
    return { status: response.status, lines: lines.map((line) => JSON.parse(line) as JsonRecord) };
  } finally {
    globalThis.fetch = originalFetch;
    Object.assign(console, original);
  }
}

const USAGE = { input_tokens: 1650, output_tokens: 410, cache_creation_input_tokens: 0, cache_read_input_tokens: 1900, service_tier: PROBE };

Deno.test('ai_call: a photo analysis logs one line with its tokens and no hint text', async () => {
  const { status, lines } = await run(
    { imageBase64: PNG_BASE64, freeTextHint: `ohne Sauce ${PROBE}` },
    () => jsonRes(claudeResponse(JSON.stringify(MEAL), 'stop', USAGE)),
  );
  assertEquals(status, 200, 'Analyse');
  assertEquals(lines.length, 1, 'eine Zeile pro Aufruf');
  const line = lines[0];
  assertEquals([line.fn, line.route, line.provider, line.effort, line.stream, line.outcome, line.http_status, line.stop_reason],
    ['analyze-meal', 'analyze', 'anthropic', 'medium', false, 'ok', 200, 'end_turn'], 'Metadaten');
  assertEquals([line.input_tokens, line.output_tokens, line.cache_read_input_tokens, line.refunded],
    [1650, 410, 1900, false], 'Zaehler');
});

Deno.test('ai_call: a described meal is its own route', async () => {
  const { status, lines } = await run(
    { mealText: `Ein Steak mit Kartoffeln ${PROBE}` },
    () => jsonRes(claudeResponse(JSON.stringify(MEAL), 'stop', USAGE)),
  );
  assertEquals(status, 200, 'Beschreibung');
  assertEquals(lines.map((line) => [line.route, line.effort]), [['describe', 'low']], 'Route und Effort');
});

Deno.test('ai_call: a provider error and a truncated answer are visible without content', async () => {
  const failed = await run(
    { imageBase64: PNG_BASE64 },
    () => jsonRes({ type: 'error', error: { type: 'overloaded_error', message: PROBE } }, 529),
  );
  assertEquals(failed.status, 502, 'Ausfall');
  assertEquals(failed.lines.map((line) => [line.outcome, line.http_status, line.input_tokens]), [['error', 529, null]], 'Fehlerzeile');

  const truncated = await run(
    { imageBase64: PNG_BASE64 },
    () => jsonRes(claudeResponse('{"mealName": "Steak', 'length', { input_tokens: 1650, output_tokens: 4096 })),
  );
  assertEquals(truncated.status, 502, 'abgeschnittenes JSON');
  assertEquals(truncated.lines.map((line) => [line.outcome, line.stop_reason, line.output_tokens]),
    [['ok', 'max_tokens', 4096]], 'max_tokens bleibt als Abbruchgrund sichtbar');
});
