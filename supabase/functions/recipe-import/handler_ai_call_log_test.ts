// ai_call telemetry of recipe-import (../_shared/ai_telemetry.ts): one line
// per paid attempt, numbered, so a retry shows up as two calls. No refund
// exists here. Offline stubs; `deno test --allow-env`.

import { resetAuthFailCacheForTests } from '../_shared/auth_fail_gate.ts';
import { userToken } from '../_shared/auth_test_fixtures.ts';
import { claudeResponse, isClaudeCall } from '../_shared/claude_test_fixtures.ts';
import { handleRequest } from './handler.ts';

const USER = '11111111-1111-4111-8111-111111111111';
/** Stands in for the caption; must never reach an ai_call line. */
const PROBE = 'PROBE-Rezept-Allergie-4711';
const TEXT = `Pasta\n200 g Pasta\nPasta kochen.\n${PROBE}`;
const ENV = {
  SUPABASE_URL: 'https://supabase.test.invalid', SUPABASE_ANON_KEY: 'test-anon-key',
  SUPABASE_SERVICE_ROLE_KEY: 'test-service-key', ANTHROPIC_API_KEY: 'test-provider-key',
};
const MODEL = {
  status: 'ready', candidates: [{ title: 'Pasta', ingredient_quotes: ['200 g Pasta'], preparation_quotes: ['Pasta kochen.'] }],
};

type JsonRecord = Record<string, unknown>;

function check(value: unknown, message: string): asserts value {
  if (!value) throw new Error(message);
}

Deno.test('ai_call: a transient failure and its retry are two numbered lines', async () => {
  resetAuthFailCacheForTests();
  const originalFetch = globalThis.fetch;
  const originalLog = console.log;
  const originalError = console.error;
  const previous = new Map(Object.keys(ENV).map((key) => [key, Deno.env.get(key)]));
  for (const [key, value] of Object.entries(ENV)) Deno.env.set(key, value);
  const logs: string[] = [];
  console.log = (...args: unknown[]) => logs.push(args.map(String).join(' '));
  console.error = () => {};
  let attempts = 0;
  globalThis.fetch = ((input: string | URL | Request, init?: RequestInit) => {
    const url = String(input instanceof Request ? input.url : input);
    const body = typeof init?.body === 'string' ? JSON.parse(init.body) as JsonRecord : {};
    if (url.endsWith('/auth/v1/user')) return Promise.resolve(Response.json({ id: USER }));
    if (url.endsWith('/consume_edge_rate_limits')) return Promise.resolve(Response.json((body.p_gates as unknown[]).map(() => ({ allowed: true }))));
    if (url.endsWith('/reserve_ai_provider_call')) return Promise.resolve(Response.json({ allowed: true, reason: 'allowed' }));
    if (isClaudeCall(url)) {
      attempts++;
      if (attempts === 1) return Promise.resolve(Response.json({ type: 'error', error: { type: 'overloaded_error', message: PROBE } }, { status: 529 }));
      return Promise.resolve(Response.json(claudeResponse(JSON.stringify(MODEL), 'stop', { input_tokens: 700, output_tokens: 300 })));
    }
    throw new Error(`Unerwarteter fetch: ${url}`);
  }) as typeof fetch;
  try {
    const response = await handleRequest(new Request('https://edge.test.invalid/recipe-import', {
      method: 'POST',
      headers: { authorization: `Bearer ${userToken(USER)}`, 'content-type': 'application/json', 'cf-connecting-ip': '203.0.113.9' },
      body: JSON.stringify({ text: TEXT, locale: 'de' }),
    }));
    check(response.status === 200, `Import nach Wiederholung: ${response.status}`);
    await response.body?.cancel();
    const lines = logs.filter((line) => line.startsWith('{"event":"ai_call"'));
    for (const line of lines) {
      for (const secret of [PROBE, 'Allergie', USER, '203.0.113.9']) check(!line.includes(secret), `ai_call-Zeile enthaelt ${secret}: ${line}`);
    }
    const parsed = lines.map((line) => JSON.parse(line) as JsonRecord);
    check(JSON.stringify(parsed.map((line) => [line.fn, line.route, line.attempt, line.outcome, line.http_status, line.input_tokens, line.refunded])) ===
      JSON.stringify([
        ['recipe-import', 'import', 1, 'error', 529, null, false],
        ['recipe-import', 'import', 2, 'ok', 200, 700, false],
      ]), `Zeilen: ${JSON.stringify(parsed)}`);
  } finally {
    globalThis.fetch = originalFetch;
    console.log = originalLog;
    console.error = originalError;
    for (const [key, value] of previous) {
      if (value === undefined) Deno.env.delete(key);
      else Deno.env.set(key, value);
    }
  }
});
