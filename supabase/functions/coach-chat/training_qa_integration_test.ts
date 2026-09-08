import { handleRequest } from "./handler.ts";
import { parseTrainingPlan } from "./training_plan.ts";

const USER = "11111111-1111-4111-8111-111111111111";
const SESSION = "22222222-2222-4222-8222-222222222222";
const MESSAGE = "33333333-3333-4333-8333-333333333333";
const NOW = Date.parse("2026-09-08T12:00:00Z");
type Row = Record<string, unknown>;

function draft() {
  return {
    schema_version: 1, title: "Comfortable training", description: "", goal: "Consistency",
    workouts: [{ title: "Session A", description: "", exercises: [{
      name: "Chair squat", sets: 2, reps: 8, duration_seconds: null, rest_seconds: 30, notes: "",
    }] }],
  };
}

function check(value: unknown, label: string): asserts value {
  if (!value) throw new Error(label);
}

function json(value: unknown, status = 200) {
  return new Response(JSON.stringify(value), { status, headers: { "content-type": "application/json" } });
}

async function run(
  body: Row,
  options: { providerDraft?: unknown; assistantHistoryFails?: boolean } = {},
) {
  // Fixed CI-only credentials; never load local runtime configuration.
  Deno.env.set("SUPABASE_URL", "https://ci.invalid");
  Deno.env.set("SUPABASE_ANON_KEY", "ci-dummy-key");
  Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "ci-dummy-service");
  Deno.env.set("OPENROUTER_API_KEY", "ci-dummy-provider");
  const originalFetch = globalThis.fetch;
  const originalNow = Date.now;
  const calls: { path: string; method: string; body: Row }[] = [];
  const unexpected: string[] = [];
  Date.now = () => NOW;
  globalThis.fetch = ((input: string | URL | Request, init?: RequestInit) => Promise.resolve().then(() => {
    const url = new URL(input instanceof Request ? input.url : String(input));
    const method = init?.method ?? "GET";
    const data = typeof init?.body === "string" ? JSON.parse(init.body) as Row : {};
    calls.push({ path: url.pathname, method, body: data });
    if (url.hostname === "ci.invalid") {
      switch (url.pathname) {
        case "/auth/v1/user": return json({ id: USER });
        case "/rest/v1/rpc/consume_edge_rate_limits":
          return json((data.p_gates as Row[]).map((gate) => ({
            allowed: true, remaining: 10, limit: gate.limit,
            resetAt: "2026-09-08T12:01:00Z", windowSeconds: gate.window_seconds,
          })));
        case "/rest/v1/rpc/prune_edge_rate_limits":
        case "/rest/v1/rpc/touch_chat_session":
        case "/rest/v1/rpc/refund_chat_quota_for_day":
          return new Response(null, { status: 204 });
        case "/rest/v1/rpc/claim_chat_quota":
          return json([{ used: 1, remaining: 4, quota_day: "2026-09-08" }]);
        case "/rest/v1/chat_sessions":
          return method === "GET" ? json([{ id: SESSION, title: "QA" }]) : new Response(null, { status: 204 });
        case "/rest/v1/chat_messages":
          if (method === "GET") return json([]);
          if (data.training_plan && options.assistantHistoryFails) return json({ error: "ci-history-failed" }, 500);
          return json([{ id: MESSAGE }], 201);
      }
    }
    if (url.href === "https://openrouter.ai/api/v1/chat/completions") {
      let content: string;
      if (data.max_tokens === 50) content = JSON.stringify({ category: "fitness", confidence: "high" });
      else if (data.response_format) content = JSON.stringify(options.providerDraft ?? draft());
      else content = "Ordinary coaching answer.";
      return json({ choices: [{ message: { content } }] });
    }
    unexpected.push(`${method} ${url.pathname}`);
    throw new Error("Unstubbed request blocked");
  })) as typeof fetch;
  try {
    const response = await handleRequest(new Request("https://ci.invalid/functions/v1/coach-chat", {
      method: "POST", headers: { authorization: "Bearer ci-dummy-user", "content-type": "application/json" },
      body: JSON.stringify({ session_id: SESSION, locale: "en", ...body }),
    }));
    const result = await response.json();
    check(unexpected.length === 0, `Unexpected request: ${unexpected.join(",")}`);
    check(calls.every((call) => call.path !== "/rest/v1/training_plans"), "Generation wrote the saved library");
    return { status: response.status, result, calls };
  } finally {
    globalThis.fetch = originalFetch;
    Date.now = originalNow;
  }
}

Deno.test("QA: generation returns a draft and writes only assistant history", async () => {
  const result = await run({ mode: "plan", message: "A comfortable beginner plan" });
  check(result.status === 200, `status ${result.status}`);
  check(result.result.training_plan?.title === "Comfortable training", "No usable proposal");
  const history = result.calls.filter((call) => call.path === "/rest/v1/chat_messages" && call.body.training_plan);
  check(history.length === 1, "Draft history count");
  check(history[0].body.role === "assistant" && history[0].body.refusal === false, "Wrong history role");
  check(history[0].body.user_id === USER && history[0].body.session_id === SESSION, "Wrong history owner/session");
});

Deno.test("QA: optional history failure keeps ephemeral draft without adopting it", async () => {
  const result = await run({ mode: "plan", message: "Two short workouts" }, { assistantHistoryFails: true });
  check(result.status === 200 && result.result.training_plan, "Ephemeral proposal lost");
  check(result.result.assistant_message_id === undefined, "Invented durable history ID");
});

Deno.test("QA: provider-injected identity never reaches proposal history", async () => {
  const result = await run({ mode: "plan", message: "Simple training" }, { providerDraft: { ...draft(), user_id: USER } });
  check(result.status === 502 && !result.result.training_plan, "Tampered plan accepted");
  check(!result.calls.some((call) => call.body.training_plan), "Tampered plan persisted in history");
  const refunds = result.calls.filter((call) => call.path.endsWith("/refund_chat_quota_for_day"));
  check(refunds.length === 1 && refunds[0].body.p_quota_day === "2026-09-08", "Refund lost charged day");
});

Deno.test("QA: model refusal never creates adoptable history", async () => {
  const result = await run({ mode: "plan", message: "A training request" }, { providerDraft: { refuse: "Please seek suitable professional support." } });
  check(result.status === 200 && result.result.refusal === true && !result.result.training_plan, "Refusal is adoptable");
  check(!result.calls.some((call) => call.body.training_plan), "Refusal persisted as plan");
});

for (const command of ["/planet training", "/planx", "/dance training"]) {
  Deno.test(`QA: unknown command ${command} stays ordinary chat`, async () => {
    const result = await run({ message: command });
    check(result.status === 200 && !result.result.training_plan, "Unknown command generated a plan");
    check(!result.calls.some((call) => call.body.response_format), "Unknown command used draft generation");
  });
}

for (const explicitMode of [true, false]) {
  Deno.test(`QA: photo plus /plan rejects (explicit mode ${explicitMode})`, async () => {
    const result = await run({ ...(explicitMode ? { mode: "plan" } : {}), message: "/plan gentle training",
      image_base64: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==",
      image_mime_type: "image/png",
    });
    check(result.status === 400 && result.result.error === "plan_image_not_supported", `Photo+plan routed to ${result.status}`);
    check(!result.calls.some((call) => call.path.includes("chat/completions")), "Rejected attachment consumed a provider call");
  });
}

Deno.test("QA: TS text limits preserve supplementary codepoints and reject aggregate overflow", () => {
  const value = draft();
  value.title = "🏋".repeat(120);
  check(parseTrainingPlan(value)?.title === value.title, "Unicode title truncated or rejected");
  value.title += "🏋";
  check(parseTrainingPlan(value) === null, "121-codepoint title accepted");
  value.title = "P";
  value.goal = "";
  value.workouts[0].title = "W";
  value.workouts[0].exercises = Array.from({ length: 20 }, () => ({ ...draft().workouts[0].exercises[0], name: "N".repeat(99), notes: "x".repeat(500) }));
  value.description = "🏋".repeat(18);
  check(parseTrainingPlan(value) !== null, "12000-codepoint plan rejected");
  value.description += "🏋";
  check(parseTrainingPlan(value) === null, "12001-codepoint plan accepted");
});
