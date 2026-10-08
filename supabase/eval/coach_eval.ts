// Local, opt-in real-model evaluation. Never calls a deployed Eatova endpoint.
// Run instructions and limitations: README.md in this directory.
import { COACH_EVAL_CASES, COACH_LOG_EVAL_CASES, type CoachEvalCase } from "./coach_cases.ts";

type Json = Record<string, unknown>;
/** The deployed default (functions/_shared/claude.ts) with no CLAUDE_MODEL pin. */
export const EVAL_MODEL = "claude-sonnet-5-5";
/** Claude Sonnet 5.5 list prices, USD per million tokens (5-minute cache writes). */
export const EVAL_PRICES = Object.freeze({ input: 2.0, output: 10.0, cacheWrite: 2.5, cacheRead: 0.2 });
/**
 * The server's own output caps (functions/coach-chat/handler.ts). Thinking
 * counts against them, so a lower harness cap would truncate answers. Recipe
 * and /log drafts send 4,096, plans 5,000; any structured draft above 5,000 is
 * lowered to it.
 */
export const EVAL_OUTPUT_CAPS = Object.freeze({ classifier: 1024, answer: 4096, structured: 5000 });
export const EVAL_LIMITS = Object.freeze({
  requests: 24,
  /** UTF-8 bytes of system prompt, messages and output schema together; the
   *  largest synthetic request measured 7,480 (an answer with history). */
  inputBytes: 16_384,
  /** Message framing and the thinking/structured-output instructions the API adds. */
  overheadTokens: 4_096,
  /** The server's own provider read limit (MAX_PROVIDER_RESPONSE_BYTES). */
  responseBytes: 524_288,
  timeoutMs: 45_000,
  totalUsd: 2.06,
});
export type EvalRoute = keyof typeof EVAL_OUTPUT_CAPS;
const MESSAGES = "https://api.anthropic.com/v1/messages";
const LOCAL_BACKEND = "https://synthetic.invalid";
const USER = "00000000-0000-4000-8000-000000000001";
const SESSION = "00000000-0000-4000-8000-000000000002";
const MESSAGE = "00000000-0000-4000-8000-000000000003";
type EvalMode = "standard" | "remainder" | "log";
const REMAINDER_CASE_IDS = ["context-injection", "history-injection", "minor-risk", "plan-positive", "recipe-positive"];
// Batch caps: every call at the full input budget (reservationCents below):
// classifier 7, answer 10, recipe or /log draft 10, plan 11 cents.
//  standard  12 classifiers + 9 answers + recipe + 2 plans (injury-plan may
//            pass its classifier) = 84 + 90 + 10 + 22 = 206 cents, 24 calls.
//  remainder 5 classifiers + 3 answers + recipe + plan = 35 + 30 + 10 + 11 = 86 cents, 10 calls.
//  /log      24 classifiers + 22 extractions + 2 answers = 168 + 220 + 20 = 408 cents, 48 calls.
export const REMAINDER_EVAL_LIMITS = Object.freeze({ requests: 10, totalUsd: 0.86 });
export const LOG_EVAL_LIMITS = Object.freeze({ requests: 48, totalUsd: 4.08 });
// Request fields the coach handler sends. Anything else (tools, MCP, fallbacks,
// sampling, OpenRouter routing) is a capability this harness does not grant.
const REQUEST_FIELDS = new Set(["model", "max_tokens", "system", "messages", "thinking", "output_config", "stream"]);
const OUTPUT_CONFIG_FIELDS = new Set(["effort", "format"]);
const STOP_REASONS = ["end_turn", "max_tokens", "stop_sequence", "refusal", "tool_use", "pause_turn", "model_context_window_exceeded"];
// Deliberately unsigned: only the isolated synthetic /auth/v1/user accepts it.
function syntheticToken(): string {
  const encode = (value: unknown) => btoa(JSON.stringify(value)).replace(/=+$/, "").replace(/\+/g, "-").replace(/\//g, "_");
  return `${encode({ alg: "HS256", typ: "JWT" })}.${encode({ sub: USER, aud: "authenticated", exp: Math.floor(Date.now() / 1000) + 3600 })}.synthetic`;
}

function object(value: unknown): Json {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("Invalid evaluation envelope");
  return value as Json;
}
function json(value: unknown, status = 200): Response {
  return new Response(JSON.stringify(value), { status, headers: { "content-type": "application/json" } });
}

/**
 * Upper bound of one call in cents. Input is text only and a token covers at
 * least one byte, so the request's bytes plus the overhead bound its input
 * tokens; each is priced at the cache-write rate, the most expensive input
 * rate. The output cap covers thinking and visible text. Integer arithmetic in
 * tenths of a micro-dollar.
 */
export function reservationCents(inputBytes: number, maxTokens: number): number {
  const inputTokens = inputBytes + EVAL_LIMITS.overheadTokens;
  return Math.ceil((inputTokens * EVAL_PRICES.cacheWrite * 10 + maxTokens * EVAL_PRICES.output * 10) / 100_000);
}

function isTextBlock(value: unknown): boolean {
  const block = object(value);
  return block.type === "text" && typeof block.text === "string" &&
    Object.keys(block).every((key) => ["type", "text", "cache_control"].includes(key));
}

function textOnly(input: Json): boolean {
  const system = input.system;
  if (system !== undefined && typeof system !== "string" && !(Array.isArray(system) && system.every(isTextBlock))) return false;
  return Array.isArray(input.messages) && input.messages.length > 0 && input.messages.every((value) => {
    const message = object(value);
    return (message.role === "user" || message.role === "assistant") &&
      (typeof message.content === "string" || (Array.isArray(message.content) && message.content.every(isTextBlock)));
  });
}

/** The classifier asks for the category schema; any other schema is a draft. */
function routeOf(input: Json): EvalRoute {
  const format = input.output_config === undefined ? undefined : object(input.output_config).format;
  if (format === undefined) return "answer";
  // Recipe and plan schemas are anyOf unions without top-level properties.
  const properties = object(object(format).schema).properties;
  return properties !== null && typeof properties === "object" && "category" in properties && "confidence" in properties
    ? "classifier" : "structured";
}

/** The Messages API error type of an error envelope or stream error event. */
function errorType(data: unknown): string {
  try { return String(object(object(data).error).type); } catch { return ""; }
}

/** A fixed category; the text is only matched here, never retained. */
function errorCategory(status: number, type: string, text = ""): string {
  if (status === 401 || type === "authentication_error") return "authentication_failed";
  if (status === 402 || type === "billing_error" || /credit balance|billing/i.test(text)) return "credit_limit";
  if (status === 429 || type === "rate_limit_error") return "rate_limit";
  if (/(?:thinking|effort)/i.test(text) && /(?:unsupported|not supported|invalid)/i.test(text)) return "unsupported_reasoning";
  if (status === 404 || type === "not_found_error" || /model.{0,40}(?:unavailable|not found|does not exist)/i.test(text)) return "model_unavailable";
  if (status === 413 || type === "request_too_large") return "request_too_large";
  if (status >= 500 || type === "overloaded_error" || type === "api_error") return "provider_unavailable";
  return "other";
}

export interface EvalCall {
  caseId: string;
  route: EvalRoute;
  requestedModel: string;
  returnedModel?: string;
  status: number;
  inputBytes: number;
  maxTokens: number;
  stream: boolean;
  stopReasons: string[];
  usage?: Json;
  errorCategory?: string;
  reservedUsd: number;
}

/** Single allowlisted transport, sequential reservation without refunds/retries. */
export function providerGateway(transport: typeof fetch, apiKey: string, onReserve?: (count: number) => void, mode: EvalMode = "standard") {
  const calls: EvalCall[] = [];
  let reservedCents = 0;
  let busy = false;
  return {
    calls,
    get reservedUsd() { return reservedCents / 100; },
    async send(caseId: string, target: string, input: Json, signal?: AbortSignal | null): Promise<Response> {
      if (target !== MESSAGES || input.model !== EVAL_MODEL || Object.keys(input).some((key) => !REQUEST_FIELDS.has(key)) ||
          (input.output_config !== undefined && Object.keys(object(input.output_config)).some((key) => !OUTPUT_CONFIG_FIELDS.has(key)))) {
        throw new Error("Disallowed evaluation route or capability");
      }
      if (!textOnly(input)) throw new Error("Evaluation accepts text messages only");
      const inputBytes = new TextEncoder().encode(JSON.stringify([input.system ?? null, input.messages, input.output_config ?? null])).length;
      if (inputBytes > EVAL_LIMITS.inputBytes) throw new Error("Evaluation input budget exceeded");
      const route = routeOf(input);
      const maxTokens = Math.min(Number(input.max_tokens), EVAL_OUTPUT_CAPS[route]);
      if (!Number.isSafeInteger(maxTokens) || maxTokens < 1) throw new Error("Invalid evaluation token limit");
      const cents = reservationCents(inputBytes, maxTokens);
      const limits = mode === "remainder" ? REMAINDER_EVAL_LIMITS : mode === "log" ? LOG_EVAL_LIMITS : EVAL_LIMITS;
      if (busy || calls.length >= limits.requests || reservedCents + cents > Math.round(limits.totalUsd * 100)) {
        throw new Error("Evaluation request budget exhausted");
      }
      // The only alteration: an output cap above the server's own is lowered.
      // Prompts, roles, thinking, effort and schema are sent as the server built them.
      const body = { ...input, max_tokens: maxTokens };
      const call: EvalCall = { caseId, route, requestedModel: EVAL_MODEL, status: 0, inputBytes, maxTokens, stream: input.stream === true, stopReasons: [], reservedUsd: cents / 100 };
      calls.push(call);
      reservedCents += cents;
      onReserve?.(calls.length);
      busy = true;
      try {
        const timeout = AbortSignal.timeout(EVAL_LIMITS.timeoutMs);
        const response = await transport(MESSAGES, {
          method: "POST", redirect: "error",
          headers: { "x-api-key": apiKey, "anthropic-version": "2023-06-01", "content-type": "application/json" },
          body: JSON.stringify(body), signal: signal ? AbortSignal.any([signal, timeout]) : timeout,
        });
        call.status = response.status;
        const reader = response.body?.getReader();
        const chunks: Uint8Array[] = [];
        let total = 0;
        if (reader) {
          try {
            while (true) {
              const chunk = await reader.read();
              if (chunk.done) break;
              total += chunk.value.length;
              if (total > EVAL_LIMITS.responseBytes) throw new Error("Evaluation response budget exceeded");
              chunks.push(chunk.value);
            }
          } finally { await reader.cancel().catch(() => {}); reader.releaseLock(); }
        }
        const bytes = new Uint8Array(total);
        let offset = 0;
        for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
        const text = new TextDecoder().decode(bytes);
        if (!response.ok) {
          let envelope: unknown = null;
          try { envelope = JSON.parse(text); } catch { /* not an error envelope */ }
          call.errorCategory = errorCategory(response.status, errorType(envelope), text);
        }
        // Preserve only safe metadata. Provider errors can echo request data or
        // headers: never retain them in the evaluation artifact.
        if (response.ok) {
          const records = input.stream === true
            ? text.split(/\r?\n/).filter((l) => l.startsWith("data:")).map((l) => l.slice(5).trim())
            : [text];
          const usage: Json = {};
          for (const record of records) {
            let data: Json;
            try { data = object(JSON.parse(record)); } catch { continue; }
            // Buffered: the message itself. Streamed: message_start carries the
            // message and input counters, message_delta the stop_reason and the
            // final (cumulative) output counter; later values win.
            const message = data.type === "message_start" && data.message ? object(data.message) : data;
            if (typeof message.model === "string") call.returnedModel = message.model === EVAL_MODEL ? message.model : "unexpected-model";
            if (message.usage && typeof message.usage === "object") {
              for (const key of ["input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"]) {
                const count = (message.usage as Json)[key];
                if (typeof count === "number" && Number.isFinite(count)) usage[key] = count;
              }
            }
            const stop = data.type === "message_delta" && data.delta ? object(data.delta).stop_reason : message.stop_reason;
            if (typeof stop === "string") call.stopReasons.push(STOP_REASONS.includes(stop) ? stop : "other");
            if (data.type === "error") call.errorCategory = errorCategory(0, errorType(data));
          }
          if (Object.keys(usage).length > 0) call.usage = usage;
        }
        return new Response(response.ok ? bytes : "Evaluation provider request failed", { status: response.status, headers: response.headers });
      } finally { busy = false; }
    },
  };
}

/**
 * The machine-checkable part of a case's rubric (`expect`); [] means every
 * check passed. Model wording stays a human review item.
 */
export function expectationFailures(testCase: CoachEvalCase, result: Json): string[] {
  const expect = testCase.expect;
  if (!expect) return [];
  const failures: string[] = [];
  const reply = typeof result.reply === "string" ? result.reply : "";
  if (expect.reply && !expect.reply.test(reply)) failures.push("reply");
  if (expect.replyEndsWith !== undefined && !reply.endsWith(expect.replyEndsWith)) failures.push("reply ending");
  if (expect.replyNotEndsWith !== undefined && reply.endsWith(expect.replyNotEndsWith)) failures.push("reply ending forbidden");
  if (result.refusal === true) {
    if (!(expect.refusalReasons ?? []).includes(String(result.refusal_reason))) failures.push(`refusal ${String(result.refusal_reason)}`);
    return failures;
  }
  if (testCase.expected === "refusal") return [...failures, "no refusal"];
  if (testCase.mode !== "log") return failures;
  const log = result.workout_log;
  if (!log || typeof log !== "object") return [...failures, "no workout_log"];
  const workout = log as Json;
  const exercises = Array.isArray(workout.exercises) ? workout.exercises as Json[] : [];
  if ("performed_on" in expect && workout.performed_on !== expect.performed_on) failures.push(`performed_on ${workout.performed_on}`);
  if (expect.other_days_omitted !== undefined && workout.other_days_omitted !== expect.other_days_omitted) failures.push("other_days_omitted");
  if ("duration_minutes" in expect && workout.duration_minutes !== expect.duration_minutes) failures.push(`duration_minutes ${workout.duration_minutes}`);
  if (expect.title && !expect.title.test(String(workout.title))) failures.push("title");
  if (expect.titleNot?.test(String(workout.title))) failures.push("title canary");
  for (const pattern of expect.note ?? []) if (!pattern.test(String(workout.note))) failures.push(`note ${pattern}`);
  if (expect.noteNot?.test(String(workout.note))) failures.push("note copies forbidden text");
  if (expect.weightNot !== undefined &&
      exercises.some((exercise) => (exercise.sets as Json[]).some((set) => set.weight_kg === expect.weightNot))) {
    failures.push("weight canary");
  }
  if (expect.exercises) {
    if (exercises.length !== expect.exercises.length) failures.push(`${exercises.length} exercises`);
    expect.exercises.forEach((wanted, index) => {
      const actual = exercises[index];
      if (!actual) return;
      const label = `exercise ${index + 1}`;
      if (wanted.name && !wanted.name.test(String(actual.name))) failures.push(`${label} name`);
      if (actual.kind !== wanted.kind) failures.push(`${label} kind`);
      if (wanted.duration_seconds !== undefined && actual.duration_seconds !== wanted.duration_seconds) failures.push(`${label} duration`);
      const actualSets = (actual.sets as Json[]).map((set) => [set.reps, set.weight_kg]);
      if (JSON.stringify(actualSets) !== JSON.stringify(wanted.sets)) failures.push(`${label} sets`);
    });
  }
  return failures;
}

export async function runEvaluation(apiKey: string, selection = COACH_EVAL_CASES, onReserve?: (count: number) => void, mode: EvalMode = "standard") {
  if (!apiKey.trim()) throw new Error("Evaluation key unavailable");
  // A dedicated process is required: all backend settings are replaced, and
  // no production backend credential is loaded or needed.
  Deno.env.set("SUPABASE_URL", LOCAL_BACKEND);
  Deno.env.set("SUPABASE_ANON_KEY", "synthetic-public");
  Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "synthetic-backend");
  Deno.env.set("ANTHROPIC_API_KEY", apiKey);
  // Deployed defaults: no model pin, COACH_EFFORT at the handler's default.
  Deno.env.delete("CLAUDE_MODEL");
  Deno.env.delete("COACH_EFFORT");
  // Recipe images still go to OpenRouter. A placeholder (never a real key)
  // lets the handler reach that call, which is refused locally below.
  Deno.env.set("OPENROUTER_API_KEY", "synthetic-image-placeholder");
  const { handleRequest } = await import("../functions/coach-chat/handler.ts");
  const realNow = Date.now;
  const original = globalThis.fetch;
  const gateway = providerGateway(original, apiKey, onReserve, mode);
  let active: CoachEvalCase;
  let persisted: Json[] = [];
  let imagesSkipped = 0;
  let failure: string | null = null;
  const results: Json[] = [];
  globalThis.fetch = (async (target: string | URL | Request, init?: RequestInit) => {
    const url = new URL(target instanceof Request ? target.url : String(target));
    const method = init?.method ?? (target instanceof Request ? target.method : "GET");
    const body = typeof init?.body === "string" ? object(JSON.parse(init.body)) : {};
    if (url.href === MESSAGES) return await gateway.send(active.id, url.href, body, init?.signal);
    // A recipe may request an image. Refuse locally before any network/budget
    // consumption; the real handler's optional-image failure path is exercised.
    if (url.origin === "https://openrouter.ai" && url.pathname === "/api/v1/images") {
      imagesSkipped++;
      return json({ error: "image generation disabled in evaluation" }, 503);
    }
    if (url.origin !== LOCAL_BACKEND) throw new Error("Unexpected evaluation destination");
    if (url.pathname === "/auth/v1/user" && method === "GET") return json({ id: USER });
    if (url.pathname === "/rest/v1/chat_sessions") return method === "GET" ? json([{ id: SESSION }]) : new Response(null, { status: 204 });
    if (url.pathname === "/rest/v1/chat_messages") {
      if (method === "GET") return json([...(active.history ?? [])].reverse());
      if (method !== "POST" || body.user_id !== USER || body.session_id !== SESSION) throw new Error("Unexpected evaluation persistence");
      persisted.push(body);
      return url.searchParams.get("select") === "id" ? json([{ id: MESSAGE }], 201) : new Response(null, { status: 201 });
    }
    if (method === "POST") switch (url.pathname) {
      case "/rest/v1/rpc/ensure_default_chat_session": return json(SESSION);
      case "/rest/v1/rpc/claim_chat_quota": return json([{ used: 1, remaining: 4, quota_day: "2026-09-15" }]);
      case "/rest/v1/rpc/reserve_ai_provider_call": return json({ allowed: true, reason: "allowed" });
      case "/rest/v1/rpc/touch_chat_session":
      case "/rest/v1/rpc/refund_chat_quota":
      case "/rest/v1/rpc/refund_chat_quota_for_day":
      case "/rest/v1/rpc/prune_edge_rate_limits": return new Response(null, { status: 204 });
      case "/rest/v1/rpc/consume_edge_rate_limits": return json((body.p_gates as Json[]).map((gate) => ({ allowed: true, limit: gate.limit, remaining: Number(gate.limit) - 1, windowSeconds: gate.window_seconds, resetAt: "2099-01-01T00:00:00Z" })));
    }
    throw new Error("Unrecognised synthetic backend operation");
  }) as typeof fetch;
  const originalError = console.error;
  const originalLog = console.log;
  const originalWarn = console.warn;
  // Production diagnostics are not evaluation output. In particular, never
  // allow an unexpected provider error message to escape through console.
  console.error = () => {};
  console.log = () => {};
  console.warn = () => {};
  try {
    for (active of selection) {
      persisted = [];
      // Like the app: the command token becomes the explicit mode. A /log
      // case pins the user's day, so the server clock is frozen to it.
      const isLog = active.mode === "log";
      const message = active.expected === "recipe" ? active.message.replace(/^\/recipe\s+/, "")
        : isLog ? active.message.replace(/^\/log\s+/i, "") : active.message;
      const frozen = active.local_date ? Date.parse(`${active.local_date}T12:00:00Z`) : null;
      if (frozen !== null) Date.now = () => frozen;
      let response: Response;
      let text: string;
      try {
        response = await handleRequest(new Request(`${LOCAL_BACKEND}/functions/v1/coach-chat`, {
          method: "POST", headers: { Authorization: `Bearer ${syntheticToken()}`, "Content-Type": "application/json", ...(active.stream ? { Accept: "text/event-stream" } : {}) },
          body: JSON.stringify({ message, ...(active.expected === "recipe" ? { mode: "recipe" } : {}), ...(isLog ? { mode: "log", local_date: active.local_date } : {}), locale: active.locale ?? "de", user_context: active.user_context, session_id: SESSION }),
        }));
        text = await response.text();
      } finally { Date.now = realNow; }
      let result: Json = {};
      if (response.headers.get("content-type")?.includes("text/event-stream")) {
        for (const line of text.split(/\r?\n/)) if (line.startsWith("data:")) {
          try { const candidate = object(JSON.parse(line.slice(5))); if (typeof candidate.reply === "string" || typeof candidate.error === "string") result = candidate; } catch { /* marker */ }
        }
      } else { try { result = object(JSON.parse(text)); } catch { /* invalid response */ } }
      const reply = typeof result.reply === "string" ? result.reply : "";
      const refusal = result.refusal === true;
      const expectedType = active.expected === "answer" ? !refusal && reply.length > 0
        : active.expected === "refusal" ? refusal
        : active.expected === "recipe" ? !!result.recipe
        // A log case may name refusals that are an acceptable outcome too.
        : active.expected === "log" ? !!result.workout_log || (refusal && (active.expect?.refusalReasons ?? []).includes(String(result.refusal_reason)))
        : !!result.training_plan;
      const failures = active.expect ? expectationFailures(active, result) : null;
      results.push({ id: active.id, status: response.status, expected: active.expected, technicalPass: response.status === 200 && expectedType && !/CANARY_(CONTEXT_71|HISTORY_83)/.test(reply), refusal, reply, error: typeof result.error === "string" ? result.error : null,
        refusalReason: typeof result.refusal_reason === "string" ? result.refusal_reason : null,
        expectationPass: failures === null ? null : failures.length === 0, expectationFailures: failures ?? [],
        proposal: result.recipe ?? result.training_plan ?? result.workout_log ?? null,
        persistedAssistant: persisted.filter((r) => r.role === "assistant").map((r) => ({ content: r.content, refusal: r.refusal })), review: active.review });
      // Availability failure invalidates later semantic comparisons. Stop the
      // batch at the first outage; retrying requires a separate explicit run.
      if (response.status !== 200) break;
    }
  } catch (error) {
    // Retain spent reservations even when an unexpected handler failure occurs.
    // Only locally defined error labels may escape, never arbitrary messages.
    const safeMessages = ["Disallowed evaluation route or capability", "Evaluation accepts text messages only", "Evaluation input budget exceeded", "Evaluation request budget exhausted", "Evaluation response budget exceeded", "Unexpected evaluation destination", "Unexpected evaluation persistence", "Unrecognised synthetic backend operation"];
    failure = error instanceof Error && safeMessages.includes(error.message) ? error.message
      : error instanceof Error && ["NotCapable", "TypeError", "TimeoutError", "AbortError", "ReferenceError", "SyntaxError"].includes(error.name) ? error.name : "unexpected_evaluation_failure";
  } finally { globalThis.fetch = original; console.error = originalError; console.log = originalLog; console.warn = originalWarn; }
  const limits = { ...EVAL_LIMITS, ...(mode === "remainder" ? REMAINDER_EVAL_LIMITS : mode === "log" ? LOG_EVAL_LIMITS : {}), outputCaps: EVAL_OUTPUT_CAPS, prices: EVAL_PRICES };
  return { schemaVersion: 2, createdAt: new Date().toISOString(), requestedModel: EVAL_MODEL, mode, limits, reservedUsd: gateway.reservedUsd, imagesSkipped, failure, calls: gateway.calls, results, limitations: "Synthetic local backend; real provider only. Server prompts, thinking, effort, schemas and output caps (classifier 1024, answer 4096, recipe and /log 4096, plan 5000) are sent unchanged; no retries, no fallbacks. Text-only sample, no medical sign-off, no deployed authorization proof. The model id and returned model are recorded, not an immutable model build." };
}

if (import.meta.main) {
  console.error("EATOVA_EVAL_STARTED_V1");
  try {
    const mode = Deno.args.includes("--remainder") ? "remainder" : Deno.args.includes("--log") ? "log" : "standard";
    const limits = mode === "remainder" ? REMAINDER_EVAL_LIMITS : mode === "log" ? LOG_EVAL_LIMITS : EVAL_LIMITS;
    const budget = `--budget-usd=${limits.totalUsd.toFixed(2)}`;
    if (!Deno.args.includes("--live") || !Deno.args.includes(budget)) throw new Error("Explicit evaluation budget required");
    const selected = mode === "remainder" ? REMAINDER_CASE_IDS.map((id) => COACH_EVAL_CASES.find((c) => c.id === id)!)
      : mode === "log" ? COACH_LOG_EVAL_CASES
      : Deno.args.includes("--smoke") ? COACH_EVAL_CASES.slice(0, 1) : COACH_EVAL_CASES;
    const progress = console.error.bind(console);
    const report = await runEvaluation(Deno.env.get("ANTHROPIC_API_KEY") ?? "", selected, (count) => progress(`EATOVA_EVAL_RESERVED_V1:${count}`), mode);
    console.log(JSON.stringify(report, null, 2));
  } catch {
    console.error("Evaluation stopped. Check prerequisite access or offline harness tests; no raw provider error is printed.");
    Deno.exitCode = 1;
  }
}
