// ai_call telemetry of coach-chat end to end (../_shared/ai_telemetry.ts):
// one line per provider call, written once the request has settled, with the
// token counters, the final refund flag and never a word of the conversation.
//
// Offline stubs only; `deno test --allow-env`.

import { userToken } from "../_shared/auth_test_fixtures.ts";
import { resetAuthFailCacheForTests } from "../_shared/auth_fail_gate.ts";
import {
  claudeEvent,
  claudeResponse,
  claudeTextDelta,
  isClaudeCall,
  isClassifierRequest,
  outputSchema,
} from "../_shared/claude_test_fixtures.ts";
import { JPEG_BASE64 } from "../analyze-meal/image_fixtures.ts";
import { handleRequest } from "./handler.ts";
import { isResolvePlanCall, resolvePlanResponse } from "./plan_test_fixtures.ts";

const USER_ID = "11111111-1111-4111-8111-111111111111";
const SESSION_ID = "22222222-2222-4222-8222-222222222222";
const CLIENT_IP = "203.0.113.77";
/** Stands in for the user's words; must never reach an ai_call line. */
const PROBE = "PROBE-Gesundheit-Diabetes-4711";

Deno.env.set("SUPABASE_URL", "https://supabase.test.invalid");
Deno.env.set("SUPABASE_ANON_KEY", "test-anon-key");
Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "test-service-key");
Deno.env.set("ANTHROPIC_API_KEY", "test-anthropic-key");
Deno.env.set("OPENROUTER_API_KEY", "test-openrouter-key");

type JsonRecord = Record<string, unknown>;

const RECIPE_JSON = JSON.stringify({
  title: "Huehnchenauflauf",
  description: "Cremig und proteinreich.",
  portion: "1 grosse Portion",
  ingredients: "- 250 g Haehnchenbrust",
  preparation: "1. Ofen vorheizen.",
  calories_kcal: 520,
  protein_g: 48,
  carbs_g: 32,
  fat_g: 18,
  estimated_g: 450,
});

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

function assertEquals(actual: unknown, expected: unknown, message: string): void {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(`${message}: erwartet ${JSON.stringify(expected)}, war ${JSON.stringify(actual)}`);
  }
}

function jsonRes(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), { status, headers: { "content-type": "application/json" } });
}

/** Usage with the probe smuggled into fields the line must ignore. */
const ANSWER_USAGE = {
  input_tokens: 812,
  output_tokens: 233,
  cache_creation_input_tokens: 0,
  cache_read_input_tokens: 2400,
  service_tier: PROBE,
  server_tool_use: { web_search_requests: PROBE },
};

interface Stub {
  restore(): void;
  logs: string[];
}

interface Options {
  answerStatus?: number;
  stream?: string;
  imageUsage?: JsonRecord;
  throwingLogger?: boolean;
}

function install(options: Options = {}): Stub {
  resetAuthFailCacheForTests();
  const originalFetch = globalThis.fetch;
  const originalLog = console.log;
  const originalError = console.error;
  const logs: string[] = [];
  console.log = options.throwingLogger
    ? () => {
      throw new Error("logger down");
    }
    : (...args: unknown[]) => logs.push(args.map(String).join(" "));
  console.error = () => {};
  globalThis.fetch = ((input: string | URL | Request, init?: RequestInit): Promise<Response> => {
    const url = String(input instanceof Request ? input.url : input);
    const method = (init?.method ?? "GET").toUpperCase();
    const body = typeof init?.body === "string" ? JSON.parse(init.body) as JsonRecord : {};
    if (url.includes("/auth/v1/user")) return Promise.resolve(jsonRes({ id: USER_ID }));
    if (url.includes("/rpc/consume_edge_rate_limits")) {
      return Promise.resolve(jsonRes((body.p_gates as JsonRecord[]).map((gate) => ({
        allowed: true, limit: gate.limit, remaining: 1,
        resetAt: new Date(Date.now() + 600_000).toISOString(), windowSeconds: gate.window_seconds,
      }))));
    }
    if (url.includes("/rpc/reserve_ai_provider_call")) return Promise.resolve(jsonRes({ allowed: true, reason: "allowed" }));
    if (url.includes("/rpc/ensure_default_chat_session")) return Promise.resolve(jsonRes(SESSION_ID));
    if (url.includes("/rpc/claim_chat_quota")) {
      return Promise.resolve(jsonRes([{ used: 1, remaining: 4, quota_day: "2026-10-18" }]));
    }
    if (isResolvePlanCall(url)) return Promise.resolve(resolvePlanResponse("legacy"));
    if (url.includes("/rpc/")) return Promise.resolve(new Response(null, { status: 204 }));
    if (url.includes("/rest/v1/chat_messages")) {
      return Promise.resolve(method === "POST" ? jsonRes([{ id: "33333333-3333-4333-8333-333333333333" }], 201) : jsonRes([]));
    }
    if (url.includes("/rest/v1/chat_sessions")) {
      return Promise.resolve(method === "PATCH" ? new Response(null, { status: 204 }) : jsonRes([]));
    }
    if (url.startsWith("https://openrouter.ai/")) {
      return Promise.resolve(jsonRes({ data: [{ b64_json: JPEG_BASE64 }], usage: options.imageUsage }));
    }
    if (isClaudeCall(url)) {
      if (isClassifierRequest(body)) {
        return Promise.resolve(jsonRes(claudeResponse(JSON.stringify({ category: "fitness", confidence: "high" }), "stop", {
          input_tokens: 301, output_tokens: 40, cache_read_input_tokens: 1200, cache_creation_input_tokens: 0,
        })));
      }
      if (options.answerStatus !== undefined) {
        return Promise.resolve(jsonRes({ type: "error", error: { type: "api_error", message: PROBE } }, options.answerStatus));
      }
      if (body.stream === true && options.stream !== undefined) {
        return Promise.resolve(new Response(options.stream, { headers: { "content-type": "text/event-stream" } }));
      }
      const text = outputSchema(body) !== undefined ? RECIPE_JSON : `Mehr Protein hilft. ${PROBE}`;
      return Promise.resolve(jsonRes(claudeResponse(text, "stop", ANSWER_USAGE)));
    }
    throw new Error(`Unerwarteter fetch: ${method} ${url}`);
  }) as typeof fetch;
  return {
    logs,
    restore: () => {
      globalThis.fetch = originalFetch;
      console.log = originalLog;
      console.error = originalError;
    },
  };
}

function request(payload: JsonRecord, headers: Record<string, string> = {}): Request {
  return new Request("https://edge.test.invalid/coach-chat", {
    method: "POST",
    headers: {
      authorization: `Bearer ${userToken(USER_ID)}`,
      "content-type": "application/json",
      "cf-connecting-ip": CLIENT_IP,
      ...headers,
    },
    body: JSON.stringify(payload),
  });
}

/** The ai_call lines of a capture, parsed; every one must be free of identity and content. */
function aiCalls(logs: string[]): JsonRecord[] {
  const lines = logs.filter((line) => line.startsWith('{"event":"ai_call"'));
  for (const line of lines) {
    for (const secret of [PROBE, "Diabetes", USER_ID, SESSION_ID, CLIENT_IP, "test-anthropic-key"]) {
      assert(!line.includes(secret), `ai_call-Zeile enthaelt ${secret}: ${line}`);
    }
  }
  return lines.map((line) => JSON.parse(line) as JsonRecord);
}

Deno.test("ai_call: a buffered chat logs classifier and answer with tokens, never the conversation", async () => {
  const stub = install();
  try {
    const response = await handleRequest(request({
      message: `Wie viel Protein brauche ich? ${PROBE}`,
      user_context: `Profil: ${PROBE}`,
      locale: "de",
    }));
    assertEquals(response.status, 200, "Antwort");
    await response.body?.cancel();
    const lines = aiCalls(stub.logs);
    assertEquals(lines.map((line) => line.route), ["classifier", "chat"], "eine Zeile pro Provider-Aufruf");
    const [classifier, answer] = lines;
    assertEquals([classifier.input_tokens, classifier.cache_read_input_tokens, classifier.effort], [301, 1200, "high"], "Klassifizierer");
    assertEquals({
      fn: answer.fn, provider: answer.provider, model: answer.model, outcome: answer.outcome,
      http_status: answer.http_status, stop_reason: answer.stop_reason, stream: answer.stream,
      input_tokens: answer.input_tokens, output_tokens: answer.output_tokens,
      cache_read_input_tokens: answer.cache_read_input_tokens, refunded: answer.refunded,
    }, {
      fn: "coach-chat", provider: "anthropic", model: "claude-sonnet-5-5", outcome: "ok",
      http_status: 200, stop_reason: "end_turn", stream: false,
      input_tokens: 812, output_tokens: 233, cache_read_input_tokens: 2400, refunded: false,
    }, "Antwortzeile");
  } finally {
    stub.restore();
  }
});

Deno.test("ai_call: a provider outage marks every call of the request as refunded", async () => {
  const stub = install({ answerStatus: 529 });
  try {
    const response = await handleRequest(request({ message: `Wie viel Protein? ${PROBE}` }));
    assertEquals(response.status, 502, "Ausfall");
    await response.body?.cancel();
    const lines = aiCalls(stub.logs);
    assertEquals(lines.map((line) => [line.route, line.outcome, line.http_status, line.refunded]), [
      ["classifier", "ok", 200, true],
      ["chat", "error", 529, true],
    ], "Erstattung und Status");
  } finally {
    stub.restore();
  }
});

Deno.test("ai_call: a streamed answer reports its usage after the stream has ended", async () => {
  const stream = [
    claudeEvent({
      type: "message_start",
      message: { usage: { input_tokens: 90, output_tokens: 1, cache_read_input_tokens: 2400, cache_creation_input_tokens: 0 } },
    }),
    claudeEvent({ type: "content_block_start", index: 1, content_block: { type: "text", text: "" } }),
    claudeTextDelta("Mehr Protein hilft beim Muskelaufbau, verteilt ueber den Tag."),
    claudeEvent({ type: "content_block_stop", index: 1 }),
    claudeEvent({ type: "message_delta", delta: { stop_reason: "end_turn" }, usage: { output_tokens: 57 } }),
    claudeEvent({ type: "message_stop" }),
  ].join("");
  const stub = install({ stream });
  try {
    const response = await handleRequest(request({ message: `Wie viel Protein? ${PROBE}` }, { accept: "text/event-stream" }));
    assertEquals(response.status, 200, "SSE");
    const wire = await response.text();
    assert(wire.includes("event: done"), "Stream endet regulaer");
    await new Promise((resolve) => setTimeout(resolve, 0));
    const answer = aiCalls(stub.logs).find((line) => line.route === "chat");
    assert(answer, `keine Antwortzeile: ${stub.logs.join(" | ")}`);
    assertEquals([answer.stream, answer.outcome, answer.input_tokens, answer.output_tokens, answer.cache_read_input_tokens, answer.stop_reason],
      [true, "ok", 90, 57, 2400, "end_turn"], "Stream-Zaehler");
  } finally {
    stub.restore();
  }
});

Deno.test("ai_call: a recipe logs the draft and the image call with its provider usage", async () => {
  const stub = install({ imageUsage: { prompt_tokens: 25, completion_tokens: 1290 } });
  try {
    const response = await handleRequest(request({ message: `Auflauf mit Haehnchen ${PROBE}`, mode: "recipe" }));
    assertEquals(response.status, 200, "Rezept");
    await response.body?.cancel();
    const lines = aiCalls(stub.logs);
    assertEquals(lines.map((line) => line.route), ["classifier", "recipe", "image"], "drei Aufrufe");
    const image = lines[2];
    assertEquals([image.provider, image.model, image.effort, image.input_tokens, image.output_tokens],
      ["openrouter", "google/gemini-3.1-flash-image", null, 25, 1290], "Bildzeile");
  } finally {
    stub.restore();
  }
});
