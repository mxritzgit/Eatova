// Real handler, stubbed transport: failures before and after response headers.
import { handleRequest, SUPABASE_TIMEOUTS_MS } from "./handler.ts";

const USER_ID = "11111111-1111-4111-8111-111111111111";
const SESSION_ID = "22222222-2222-4222-8222-222222222222";
const QUOTA_DAY = "2026-09-08";
const PRIVATE_ERROR = "PRIVATE_RESPONSE_SENTINEL";
const REPLY = "Eine Banane liefert etwa 100 Kalorien.";
const RECIPE = { title: "Auflauf", calories_kcal: 520, estimated_g: 450 };

Deno.env.set("SUPABASE_URL", "https://supabase.test.invalid");
Deno.env.set("SUPABASE_ANON_KEY", "test-anon-key");
Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "test-service-key");
Deno.env.set("OPENROUTER_API_KEY", "test-openrouter-key");

type Stage = "auth" | "limits" | "session" | "ownership" | "history" | "claim" |
  "user-store" | "title" | "assistant-store" | "recipe-store" | "touch";
type Fault = "transport" | "body-timeout" | "body-invalid";
type Call = { url: string; method: string; body: Record<string, unknown> };

function equal(actual: unknown, expected: unknown, label: string): void {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(`${label}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  }
}

function json(value: unknown, status = 200): Response {
  return new Response(JSON.stringify(value), { status });
}

async function withStub(
  options: {
    stage?: Stage;
    fault?: Fault;
    recipe?: boolean;
    quotaDay?: unknown;
    midnightFailure?: boolean;
  },
  verify: (response: Response, calls: Call[]) => Promise<void>,
): Promise<void> {
  const originalFetch = globalThis.fetch;
  const originalLog = console.error;
  const originalDate = globalThis.Date;
  const originalTimeout = SUPABASE_TIMEOUTS_MS.call;
  const calls: Call[] = [];
  const logs: string[] = [];
  let clockMs = originalDate.parse(`${QUOTA_DAY}T23:59:59.000Z`);
  // Keep Date.now(), new Date() and Date() on one clock. Explicit constructor
  // arguments and static parsing retain the native calendar semantics.
  globalThis.Date = new Proxy(originalDate, {
    construct(target, args) {
      return Reflect.construct(target, args.length === 0 ? [clockMs] : args);
    },
    apply() {
      return new originalDate(clockMs).toString();
    },
    get(target, property, receiver) {
      return property === "now" ? () => clockMs : Reflect.get(target, property, receiver);
    },
  });
  SUPABASE_TIMEOUTS_MS.call = 30;
  console.error = (...args: unknown[]) => logs.push(args.map(String).join(" "));
  const replyFor = (stage: Stage, value: unknown, signal: AbortSignal | null | undefined): Response => {
    if (stage !== options.stage) return json(value);
    if (options.fault === "transport") throw new TypeError(PRIVATE_ERROR);
    if (options.fault === "body-invalid") return new Response(PRIVATE_ERROR);
    if (!signal) throw new Error("Missing response-body deadline");
    return new Response(new ReadableStream<Uint8Array>({
      start(controller) {
        controller.enqueue(new TextEncoder().encode("{"));
        if (signal.aborted) controller.error(signal.reason);
        else signal.addEventListener("abort", () => controller.error(signal.reason), { once: true });
      },
    }));
  };
  globalThis.fetch = ((input: string | URL | Request, init?: RequestInit): Promise<Response> => {
    const url = input instanceof Request ? input.url : String(input);
    const method = init?.method ?? "GET";
    const body = typeof init?.body === "string" ? JSON.parse(init.body) : {};
    calls.push({ url, method, body });
    const answer = (stage: Stage, value: unknown) => replyFor(stage, value, init?.signal);
    try {
      if (url.endsWith("/auth/v1/user")) return Promise.resolve(answer("auth", { id: USER_ID }));
      if (url.endsWith("/consume_edge_rate_limits")) {
        return Promise.resolve(answer("limits", [{ allowed: true }, { allowed: true }]));
      }
      if (url.endsWith("/prune_edge_rate_limits")) return Promise.resolve(json(null));
      if (url.endsWith("/ensure_default_chat_session")) return Promise.resolve(answer("session", SESSION_ID));
      if (url.endsWith("/claim_chat_quota")) {
        return Promise.resolve(answer("claim", [{
          used: 1, remaining: 4,
          quota_day: "quotaDay" in options ? options.quotaDay : QUOTA_DAY,
        }]));
      }
      if (url.includes("/refund_chat_quota")) return Promise.resolve(json(null));
      if (url.endsWith("/touch_chat_session")) return Promise.resolve(answer("touch", null));
      if (url.includes("/chat_sessions") && method === "PATCH") return Promise.resolve(answer("title", null));
      if (url.includes("/chat_sessions") && method === "GET") return Promise.resolve(answer("ownership", [{ id: SESSION_ID }]));
      if (url.includes("/chat_messages")) {
        if (method === "GET") return Promise.resolve(answer("history", []));
        const stage = body.role === "user" ? "user-store" : url.includes("select=id") ? "recipe-store" : "assistant-store";
        return Promise.resolve(answer(stage, [{ id: "33333333-3333-4333-8333-333333333333" }]));
      }
      if (url.endsWith("/api/v1/images")) return Promise.resolve(json({ data: [] }));
      if (url.endsWith("/api/v1/chat/completions")) {
        if (body.max_tokens === 256) {
          return Promise.resolve(json({ choices: [{ message: { content: '{"category":"nutrition","confidence":"high"}' } }] }));
        }
        if (options.midnightFailure) {
          clockMs = originalDate.parse("2026-09-09T00:00:01.000Z");
          return Promise.resolve(json({ error: "provider unavailable" }, 503));
        }
        return Promise.resolve(json({ choices: [{
          message: { content: options.recipe ? JSON.stringify(RECIPE) : REPLY }, finish_reason: "stop",
        }] }));
      }
      throw new Error(`Unexpected fixture route: ${method} ${url}`);
    } catch (error) {
      return Promise.reject(error);
    }
  }) as typeof fetch;
  try {
    const response = await handleRequest(new Request("https://edge.test.invalid/coach-chat", {
      method: "POST",
      headers: { authorization: "Bearer test-user", "cf-connecting-ip": "203.0.113.7" },
      body: JSON.stringify({
        message: "Wie viele Kalorien hat eine Banane?",
        ...(options.recipe ? { mode: "recipe" } : {}),
        ...(options.stage === "ownership" ? { session_id: SESSION_ID } : {}),
      }),
    }));
    await verify(response, calls);
    equal(logs.some((line) => line.includes(PRIVATE_ERROR)), false, "response and transport details stay out of logs");
  } finally {
    globalThis.fetch = originalFetch;
    console.error = originalLog;
    globalThis.Date = originalDate;
    SUPABASE_TIMEOUTS_MS.call = originalTimeout;
  }
}

for (const stage of ["user-store", "title", "assistant-store", "recipe-store", "touch"] as const) {
  Deno.test(`Supabase transport failure: ${stage} preserves the answer or refunds`, async () => {
    await withStub({ stage, fault: "transport", recipe: stage === "recipe-store" }, async (response, calls) => {
      const body = await response.json();
      equal(response.status, stage === "user-store" ? 500 : 200, "status");
      const refunds = calls.filter((call) => call.url.includes("/refund_chat_quota"));
      equal(refunds.length, stage === "user-store" ? 1 : 0, "refund count");
      if (stage === "user-store") {
        equal(body.error, "store_failed", "critical write failure");
        equal(calls.some((call) => call.body.max_tokens === 3072), false, "no paid answer after failed user store");
      } else if (stage === "recipe-store") {
        equal(body.recipe.title, "Auflauf", "finished recipe delivered");
        equal("assistant_message_id" in body, false, "no invented persisted id");
      } else equal(body.reply, REPLY, "finished answer delivered");
    });
  });
}

for (const fault of ["transport", "body-timeout", "body-invalid"] as const) {
  for (const [stage, status, code] of [
    ["auth", 503, "auth_unavailable"],
    ["limits", 500, "rate_limit_unavailable"],
    ["session", 500, "session_unavailable"],
    ["ownership", 500, "session_unavailable"],
    ["history", 500, "history_unavailable"],
    ["claim", 500, "rpc_unavailable"],
  ] as const) {
    Deno.test(`Supabase ${fault}: ${stage} fails closed through its public contract`, async () => {
      await withStub({ stage, fault }, async (response, calls) => {
        equal(response.status, status, "status");
        equal((await response.json()).error, code, "public error");
        equal(calls.some((call) => call.url.includes("openrouter.ai")), false, "no provider call");
        equal(calls.some((call) => call.url.includes("refund_chat_quota")), false, "no speculative refund");
        if (stage === "ownership") {
          equal(calls.some((call) => call.url.includes("ensure_default_chat_session")), false, "no default-session fallback on outage");
        }
      });
    });
  }
}

for (const fault of ["body-timeout", "body-invalid"] as const) {
  Deno.test(`Supabase ${fault}: recipe representation does not discard the recipe`, async () => {
    await withStub({ stage: "recipe-store", fault, recipe: true }, async (response, calls) => {
      const body = await response.json();
      equal(response.status, 200, "status");
      equal(body.recipe.title, "Auflauf", "finished recipe delivered");
      equal("assistant_message_id" in body, false, "ephemeral recipe");
      equal(calls.some((call) => call.url.includes("refund_chat_quota")), false, "no refund for delivered recipe");
    });
  });
}

for (const recipe of [false, true]) {
  Deno.test(`Quota refund retains the claimed UTC day across midnight (${recipe ? "recipe" : "chat"})`, async () => {
    await withStub({ recipe, midnightFailure: true }, async (response, calls) => {
      equal(Date.now(), Date.parse("2026-09-09T00:00:01.000Z"), "clock crossed UTC midnight");
      equal(new Date().toISOString(), "2026-09-09T00:00:01.000Z", "implicit Date constructor uses the same clock");
      equal(response.status, 502, "provider outage");
      equal((await response.json()).error, "provider_error", "public failure");
      const refunds = calls.filter((call) => call.url.includes("refund_chat_quota"));
      equal(refunds.length, 1, "one refund");
      equal(refunds[0].url.endsWith("/refund_chat_quota_for_day"), true, "date-bound RPC");
      equal(refunds[0].body, { p_user_id: USER_ID, p_quota_day: QUOTA_DAY }, "refund original day only");
    });
  });
}

for (const quotaDay of [undefined, null, "", "2026-02-30", "2026-09-08T00:00:00Z"]) {
  Deno.test(`Missing or invalid claim day cannot refund another bucket (${String(quotaDay)})`, async () => {
    await withStub({ quotaDay, midnightFailure: true }, async (response, calls) => {
      equal(response.status, 502, "honest provider error survives rollout mismatch");
      equal((await response.json()).error, "provider_error", "public failure");
      equal(calls.some((call) => call.url.includes("refund_chat_quota")), false, "no refund with unknown claim date");
    });
  });
}
