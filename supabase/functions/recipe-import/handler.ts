import { authFailGate } from '../_shared/auth_fail_gate.ts';
import { clientIpSubject } from '../_shared/client_ip.ts';
import { readProviderBody } from '../_shared/provider_body.ts';
import { providerCallBudget, ProviderBudgetError } from '../_shared/provider_budget.ts';
import { hasExpectedUserTokenContext } from '../_shared/user_token_context.ts';
import { extractionPrompt, parseExtraction } from './extraction.ts';
import { loadSource } from './source.ts';

const REQUEST_BUDGET_MS = 55_000;
const MAX_BODY_BYTES = 90_000;
const MAX_TEXT_CHARS = 20_000;
type Secrets = { supabaseUrl: string; anonKey: string; serviceKey: string; providerKey: string };
type Gate = { scope: string; subject: string; limit: number; window_seconds: number };

class ImportError extends Error {
  constructor(readonly status: number, readonly code: string, readonly retryAfter?: number) {
    super(code);
  }
}

function record(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function headers(request: Request): Headers {
  const result = new Headers({
    'Content-Type': 'application/json', 'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff', 'Referrer-Policy': 'no-referrer',
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
  });
  const origins = (Deno.env.get('EATOVA_ALLOWED_ORIGINS') ?? '').split(',').map((value) => value.trim()).filter(Boolean);
  const origin = request.headers.get('origin');
  if (origin && origins.includes(origin)) {
    result.set('Access-Control-Allow-Origin', origin);
    result.set('Vary', 'Origin');
  }
  return result;
}

function json(request: Request, data: unknown, status = 200, retryAfter?: number): Response {
  const responseHeaders = headers(request);
  if (retryAfter) responseHeaders.set('Retry-After', String(retryAfter));
  return new Response(JSON.stringify(data), { status, headers: responseHeaders });
}

function stepSignal(total: AbortSignal, milliseconds: number): AbortSignal {
  total.throwIfAborted();
  return AbortSignal.any([total, AbortSignal.timeout(milliseconds)]);
}

async function boundedJson(response: Response, maxBytes: number, signal: AbortSignal): Promise<unknown> {
  const raw = await readProviderBody(response, maxBytes, signal);
  if (raw === null) throw new Error('body_too_large');
  return JSON.parse(raw);
}

async function authenticate(request: Request, secrets: Secrets, total: AbortSignal): Promise<string> {
  const token = request.headers.get('authorization')?.match(/^Bearer\s+(.+)$/i)?.[1].trim();
  if (!token || token === secrets.anonKey || token.length > 16_384) throw new ImportError(401, 'unauthorized');
  const signal = stepSignal(total, 5000);
  let response: Response;
  try {
    response = await fetch(`${secrets.supabaseUrl}/auth/v1/user`, {
      headers: { apikey: secrets.anonKey, authorization: `Bearer ${token}` }, signal, redirect: 'error',
    });
  } catch { throw new ImportError(503, 'auth_unavailable'); }
  if (!response.ok) {
    await response.body?.cancel();
    if (response.status >= 500 || response.status === 429) throw new ImportError(503, 'auth_unavailable');
    const gate = await authFailGate({
      supabaseUrl: secrets.supabaseUrl, serviceKey: secrets.serviceKey,
      scope: 'recipe-import:auth-fail', subject: clientIpSubject(request, 'anon'),
      signal: stepSignal(total, 5000),
    });
    if (gate.limited) throw new ImportError(429, 'rate_limited', gate.retryAfterSeconds);
    throw new ImportError(401, 'unauthorized');
  }
  let user: unknown;
  try { user = await boundedJson(response, 32_000, signal); }
  catch { throw new ImportError(503, 'auth_unavailable'); }
  if (!record(user) || typeof user.id !== 'string' || !hasExpectedUserTokenContext(token, user.id)) throw new ImportError(401, 'unauthorized');
  return user.id;
}

async function consumeGates(secrets: Secrets, gates: Gate[], total: AbortSignal): Promise<void> {
  const signal = stepSignal(total, 5000);
  let data: unknown;
  try {
    const response = await fetch(`${secrets.supabaseUrl}/rest/v1/rpc/consume_edge_rate_limits`, {
      method: 'POST', signal, redirect: 'error',
      headers: { apikey: secrets.serviceKey, authorization: `Bearer ${secrets.serviceKey}`, 'content-type': 'application/json' },
      body: JSON.stringify({ p_gates: gates }),
    });
    if (!response.ok) {
      await response.body?.cancel();
      throw new Error('unavailable');
    }
    data = await boundedJson(response, 12_000, signal);
  } catch { throw new ImportError(503, 'rate_limit_unavailable'); }
  if (!Array.isArray(data) || !data.length || data.length > gates.length) throw new ImportError(503, 'rate_limit_unavailable');
  for (const [index, value] of data.entries()) {
    if (!record(value) || typeof value.allowed !== 'boolean') throw new ImportError(503, 'rate_limit_unavailable');
    if (!value.allowed) {
      const remaining = typeof value.resetAt === 'string' ? Math.ceil((Date.parse(value.resetAt) - Date.now()) / 1000) : NaN;
      throw new ImportError(429, 'rate_limited', Number.isFinite(remaining) ? Math.max(1, Math.min(remaining, 86_400)) : gates[index].window_seconds);
    }
  }
  if (data.length !== gates.length) throw new ImportError(503, 'rate_limit_unavailable');
}

async function parseBody(request: Request, total: AbortSignal): Promise<{ text: string; locale: 'de' | 'en' }> {
  if (!/^application\/json(?:\s*;|$)/i.test(request.headers.get('content-type') ?? '')) throw new ImportError(415, 'unsupported_content_type');
  const length = Number(request.headers.get('content-length'));
  if (length > MAX_BODY_BYTES) throw new ImportError(413, 'payload_too_large');
  const raw = await readProviderBody(new Response(request.body), MAX_BODY_BYTES, stepSignal(total, 5000));
  if (raw === null) throw new ImportError(413, 'payload_too_large');
  let body: unknown;
  try { body = JSON.parse(raw); } catch { throw new ImportError(400, 'invalid_json'); }
  if (!record(body) || Object.keys(body).some((key) => key !== 'text' && key !== 'locale') ||
    typeof body.text !== 'string' || !body.text.trim() || body.text.length > MAX_TEXT_CHARS ||
    (body.locale !== 'de' && body.locale !== 'en')) throw new ImportError(400, 'invalid_request');
  if ([...body.text].some((char) => {
    const code = char.charCodeAt(0);
    return code === 127 || code < 32 && code !== 9 && code !== 10 && code !== 13;
  })) throw new ImportError(400, 'invalid_request');
  return { text: body.text.trim(), locale: body.locale };
}

export async function handleRequest(request: Request): Promise<Response> {
  if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers: headers(request) });
  if (request.method !== 'POST') return json(request, { error: 'method_not_allowed' }, 405);
  const total = AbortSignal.any([request.signal, AbortSignal.timeout(REQUEST_BUDGET_MS)]);
  try {
    const secrets: Secrets = {
      supabaseUrl: Deno.env.get('SUPABASE_URL') ?? '', anonKey: Deno.env.get('SUPABASE_ANON_KEY') ?? '',
      serviceKey: Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '', providerKey: Deno.env.get('OPENROUTER_API_KEY') ?? '',
    };
    if (Object.values(secrets).some((value) => !value)) throw new ImportError(503, 'not_configured');
    const userId = await authenticate(request, secrets, total);
    await consumeGates(secrets, [
      { scope: 'recipe-import:ip', subject: clientIpSubject(request, userId), limit: 60, window_seconds: 600 },
      { scope: 'recipe-import:user', subject: userId, limit: 20, window_seconds: 3600 },
    ], total);
    const input = await parseBody(request, total);
    const source = await loadSource(input.text, stepSignal(total, 10_000));
    total.throwIfAborted();
    if (!source.text) return json(request, {
      status: 'needs_text', source: source.source, candidates: [], warnings: ['source_incomplete'],
    });
    // No recipe/user-data writes occur here. Rate gates and the shared, durable
    // paid-call reservation protect this endpoint just like existing AI flows.
    await consumeGates(secrets, [
      { scope: 'recipe-import:user-day', subject: userId, limit: 20, window_seconds: 86_400 },
    ], total);
    const budget = providerCallBudget({ supabaseUrl: secrets.supabaseUrl, serviceKey: secrets.serviceKey, userId, signal: total });
    await budget('coach_recipe');
    const signal = stepSignal(total, 35_000);
    let provider: unknown;
    try {
      const response = await fetch('https://openrouter.ai/api/v1/chat/completions', {
        method: 'POST', signal, redirect: 'error',
        headers: { authorization: `Bearer ${secrets.providerKey}`, 'content-type': 'application/json' },
        body: JSON.stringify({
          model: Deno.env.get('RECIPE_IMPORT_MODEL') ?? Deno.env.get('COACH_MODEL_ANSWER') ?? 'google/gemini-3.8-flash',
          messages: [
            { role: 'system', content: extractionPrompt(input.locale) },
            { role: 'user', content: JSON.stringify({ source_text: source.text }) },
          ],
          response_format: { type: 'json_object' }, temperature: 0,
          reasoning: { effort: 'minimal' }, max_tokens: 12_000,
        }),
      });
      if (!response.ok) {
        await response.body?.cancel();
        throw new ImportError(502, 'provider_unavailable');
      }
      provider = await boundedJson(response, 192_000, signal);
    } catch (error) {
      if (error instanceof ImportError) throw error;
      if (signal.aborted) throw new ImportError(504, 'request_timeout');
      throw new ImportError(502, 'provider_invalid_response');
    }
    if (!record(provider) || !Array.isArray(provider.choices) || !record(provider.choices[0])) throw new ImportError(502, 'provider_invalid_response');
    const choice = provider.choices[0];
    if (choice.finish_reason !== 'stop' || !record(choice.message) || typeof choice.message.content !== 'string') throw new ImportError(502, 'provider_invalid_response');
    const result = await parseExtraction(choice.message.content, source);
    if (!result) throw new ImportError(502, 'provider_invalid_response');
    return json(request, result);
  } catch (error) {
    if (error instanceof ProviderBudgetError) return json(request, { error: error.code }, error.status);
    if (error instanceof ImportError) return json(request, { error: error.code }, error.status, error.retryAfter);
    if (total.aborted || error instanceof DOMException && ['TimeoutError', 'AbortError'].includes(error.name)) return json(request, { error: 'request_timeout' }, 504);
    // Exceptions may contain URLs, captions or credentials; never log them.
    console.error('recipe-import request failed');
    return json(request, { error: 'internal_error' }, 500);
  }
}
