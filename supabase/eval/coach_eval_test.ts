import { EVAL_LIMITS, EVAL_MODEL, providerGateway, runEvaluation } from "./coach_eval.ts";
import { COACH_EVAL_CASES } from "./coach_cases.ts";

const URL = "https://openrouter.ai/api/v1/chat/completions";
const INPUT = { model: EVAL_MODEL, messages: [{ role: "user", content: "Synthetic snack question" }], max_tokens: 3072 };
function assert(value: unknown, message = "Assertion failed"): asserts value { if (!value) throw new Error(message); }
async function rejects(operation: () => Promise<unknown>) {
  let rejected = false;
  try { await operation(); } catch { rejected = true; }
  assert(rejected, "Expected rejection before unsafe operation");
}
function ok() { return Response.json({ model: EVAL_MODEL, choices: [{ finish_reason: "stop", message: { content: "Synthetic reply" } }] }); }

Deno.test("eval gateway blocks other hosts/models/tools/images before a paid request", async () => {
  let calls = 0;
  const gateway = providerGateway((() => { calls++; return Promise.resolve(ok()); }) as typeof fetch, "dummy");
  for (const [target, input] of [
    ["https://example.com/chat/completions", INPUT],
    [URL + "/", INPUT],
    [URL, { ...INPUT, model: "other/model" }],
    [URL, { ...INPUT, models: [EVAL_MODEL] }],
    [URL, { ...INPUT, tools: [] }],
    [URL, { ...INPUT, plugins: [] }],
    [URL, { ...INPUT, modalities: ["image"] }],
    [URL, { ...INPUT, messages: [{ role: "user", content: [{ type: "image_url" }] }] }],
    [URL, { ...INPUT, messages: [{ role: "user", content: "x".repeat(EVAL_LIMITS.inputBytes) }] }],
    [URL, { ...INPUT, max_tokens: 0 }],
  ] as const) await rejects(() => gateway.send("test", target, input));
  assert(calls === 0 && gateway.reservedUsd === 0);
});

Deno.test("eval hard reservation stops request 25 even when all previous requests failed", async () => {
  let calls = 0;
  const gateway = providerGateway((() => { calls++; return Promise.reject(new Error("synthetic transport failure")); }) as typeof fetch, "dummy");
  for (let i = 0; i < 24; i++) await rejects(() => gateway.send("test", URL, INPUT));
  await rejects(() => gateway.send("test", URL, INPUT));
  assert(calls === 24 && gateway.reservedUsd === 0.96);
});

Deno.test("eval preserves production prompt but caps output, price and redirects without fallback", async () => {
  const gateway = providerGateway(((_target: string | URL | Request, init?: RequestInit) => {
    const body = JSON.parse(String(init?.body));
    assert(JSON.stringify(body.messages) === JSON.stringify(INPUT.messages));
    assert(body.max_tokens === 768 && body.provider.allow_fallbacks === false);
    assert(body.provider.max_price.prompt === 1.5 && body.provider.max_price.completion === 7.5);
    assert(init?.redirect === "error" && init.signal instanceof AbortSignal);
    return Promise.resolve(ok());
  }) as typeof fetch, "dummy");
  await gateway.send("test", URL, INPUT);
  assert(gateway.calls[0].returnedModel === EVAL_MODEL && gateway.reservedUsd === 0.04);
});

Deno.test("eval rejects concurrent calls and oversized response bodies without refunds", async () => {
  let complete!: (value: Response) => void;
  const gateway = providerGateway((() => new Promise((resolve) => { complete = resolve; })) as typeof fetch, "dummy");
  const first = gateway.send("first", URL, INPUT);
  await rejects(() => gateway.send("second", URL, INPUT));
  complete(new Response("x".repeat(EVAL_LIMITS.responseBytes + 1)));
  await rejects(() => first);
  assert(gateway.calls.length === 1 && gateway.reservedUsd === 0.04);
});

Deno.test("eval report excludes raw provider errors and unknown metadata", async () => {
  const gateway = providerGateway((() => Promise.resolve(new Response("DO_NOT_LOG_ERROR_BODY", { status: 400 }))) as typeof fetch, "dummy");
  const response = await gateway.send("test", URL, INPUT);
  assert(!(await response.text()).includes("DO_NOT_LOG"));
  assert(!JSON.stringify(gateway.calls).includes("DO_NOT_LOG"));
  assert(gateway.calls[0].errorCategory === "other");
});

Deno.test("eval remainder reserves 7 cents for server-sized drafts and never exceeds 48 cents", async () => {
  let maxTokens = 0;
  const gateway = providerGateway(((_target: string | URL | Request, init?: RequestInit) => {
    maxTokens = JSON.parse(String(init?.body)).max_tokens;
    return Promise.resolve(ok());
  }) as typeof fetch, "dummy", undefined, "remainder");
  for (let i = 0; i < 8; i++) await gateway.send("context-injection", URL, INPUT);
  await gateway.send("plan-positive", URL, { ...INPUT, max_tokens: 4000 });
  assert(maxTokens === 4000, "Preserve actual server plan budget");
  await gateway.send("recipe-positive", URL, INPUT);
  assert(Number(maxTokens) === 3072 && gateway.reservedUsd === 0.46);
  await rejects(() => gateway.send("context-injection", URL, INPUT));
  assert(gateway.calls.length === 10);
  const drafts = providerGateway((() => Promise.resolve(ok())) as typeof fetch, "dummy", undefined, "remainder");
  for (let i = 0; i < 6; i++) await drafts.send("plan-positive", URL, { ...INPUT, max_tokens: 4000 });
  await rejects(() => drafts.send("plan-positive", URL, { ...INPUT, max_tokens: 4000 }));
  assert(drafts.calls.length === 6 && drafts.reservedUsd === 0.42, "Dollar cap acts before request-count cap");
});

Deno.test("eval classifies unsupported reasoning without retaining provider error text", async () => {
  const gateway = providerGateway((() => Promise.resolve(new Response("Unsupported reasoning level minimal. DO_NOT_LOG_PRIVATE_ECHO", { status: 400 }))) as typeof fetch, "dummy");
  await gateway.send("test", URL, INPUT);
  assert(gateway.calls[0].errorCategory === "unsupported_reasoning");
  assert(!JSON.stringify(gateway.calls).includes("DO_NOT_LOG"));
});

Deno.test("eval runs actual handler with local auth/history/quota and only allowlisted provider fetches", async () => {
  const original = globalThis.fetch;
  let providerCalls = 0;
  globalThis.fetch = ((target: string | URL | Request, init?: RequestInit) => {
    assert(String(target) === URL, "No backend network request may escape");
    providerCalls++;
    const body = JSON.parse(String(init?.body));
    return Promise.resolve(Response.json({ model: EVAL_MODEL, provider: "synthetic-provider", usage: { prompt_tokens: 100, completion_tokens: 20, cost: 0.001 }, choices: [{ finish_reason: "stop", message: { content: body.max_tokens === 256 ? '{"category":"nutrition","confidence":"high"}' : "Linsen und Tofu passen zu einem vegetarischen Mittagessen." } }] }));
  }) as typeof fetch;
  try {
    const report = await runEvaluation("dummy-evaluation-key", COACH_EVAL_CASES.slice(0, 1));
    assert(providerCalls === 2 && report.results[0].technicalPass === true);
    assert(report.reservedUsd === 0.08 && report.results[0].persistedAssistant instanceof Array);
    assert(!JSON.stringify(report).includes("dummy-evaluation-key"));
  } finally { globalThis.fetch = original; }
});

Deno.test("eval retains request reservations after an unexpected handler/transport failure", async () => {
  const original = globalThis.fetch;
  globalThis.fetch = (() => Promise.reject(new Error("DO_NOT_LOG_ARBITRARY_ERROR"))) as typeof fetch;
  try {
    const report = await runEvaluation("dummy-evaluation-key", COACH_EVAL_CASES.slice(0, 1));
    assert(report.calls.length === 1 && report.reservedUsd === 0.04);
    assert(report.failure === null && report.results[0].status === 502 && report.results[0].error === "provider_error");
    assert(!JSON.stringify(report).includes("DO_NOT_LOG"));
  } finally { globalThis.fetch = original; }
});

for (const mode of ["standard", "remainder"] as const) Deno.test(`eval exercises the complete ${mode} batch through the actual handler offline`, async () => {
  const original = globalThis.fetch;
  let calls = 0;
  const plan = { schema_version: 1, title: "Moderater Einstieg", description: "Ohne weitere Angaben moderat beginnen.", goal: "Bewegung", workouts: [{ title: "Einheit", description: "Ruhig aufwärmen und Pausen machen.", exercises: [{ name: "Kniebeuge", sets: 2, reps: 8, duration_seconds: null, rest_seconds: 60, notes: "Kontrolliert bewegen." }] }] };
  const recipe = { title: "Haferflocken", description: "Einfaches Frühstück.", portion: "Eine Schale", ingredients: "- Haferflocken\n- Banane", preparation: "1. Vermischen.", calories_kcal: 350, protein_g: 12, carbs_g: 55, fat_g: 8, estimated_g: 300 };
  globalThis.fetch = ((target: string | URL | Request, init?: RequestInit) => {
    assert(String(target) === URL, "Unexpected network destination");
    calls++;
    const body = JSON.parse(String(init?.body));
    const messages = body.messages as { role: string; content: string }[];
    const classifier = body.max_tokens === 256;
    const wish = messages.at(-1)!.content;
    const testCase = COACH_EVAL_CASES.find((c) => c.message.replace(/^\/(plan|recipe)\s+/, "") === wish);
    const content = classifier ? JSON.stringify({ category: testCase?.expected === "refusal" ? "medical_risk" : "nutrition", confidence: "high" })
      : messages[0].content.includes("recipe generator") ? JSON.stringify(recipe)
      : messages[0].content.includes("training-plan proposals") ? JSON.stringify(plan)
      : "Ein moderater Einstieg und ausgewogene, alltagstaugliche Mahlzeiten passen gut.";
    if (body.stream) return Promise.resolve(new Response(`data: ${JSON.stringify({ model: EVAL_MODEL, choices: [{ delta: { content }, finish_reason: null }] })}\n\ndata: ${JSON.stringify({ choices: [{ delta: {}, finish_reason: "stop" }] })}\n\ndata: [DONE]\n\n`, { headers: { "content-type": "text/event-stream" } }));
    return Promise.resolve(Response.json({ model: EVAL_MODEL, choices: [{ finish_reason: "stop", message: { content } }] }));
  }) as typeof fetch;
  try {
    const ids = ["context-injection", "history-injection", "minor-risk", "plan-positive", "recipe-positive"];
    const selection = mode === "standard" ? COACH_EVAL_CASES : ids.map((id) => COACH_EVAL_CASES.find((c) => c.id === id)!);
    const report = await runEvaluation("dummy-evaluation-key", selection, undefined, mode);
    assert(report.failure === null, `Unexpected harness failure: ${report.failure}`);
    assert(report.results.length === selection.length, `Only ${report.results.length} cases executed`);
    assert(report.results.every((r) => r.technicalPass === true), JSON.stringify(report.results.filter((r) => !r.technicalPass).map((r) => ({ id: r.id, status: r.status, error: r.error }))));
    assert(calls <= 24 && calls === report.calls.length && report.imagesSkipped === 1);
    if (mode === "standard") assert(report.calls.some((call) => call.caseId === "fitness-en-stream" && call.stream), "Streaming was not exercised");
    else assert(report.reservedUsd <= 0.48 && calls <= 10);
    assert(!JSON.stringify(report).includes("dummy-evaluation-key"));
  } finally { globalThis.fetch = original; }
});
