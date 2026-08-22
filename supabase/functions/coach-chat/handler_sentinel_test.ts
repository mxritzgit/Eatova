// Sentinel tests for handleRequest: places where the handler turned "unknown"
// (missing row, failed fetch, provider error) into a concrete value the client
// cannot tell from real knowledge.
//
// Same style as handler_test.ts: stubbed globalThis.fetch, no external test
// dependencies, `deno test --allow-env`.

import { handleRequest } from "./handler.ts";

const USER_ID = "11111111-1111-4111-8111-111111111111";
const SESSION_ID = "22222222-2222-4222-8222-222222222222";
const BASE_URL = "https://supabase.test.invalid";

Deno.env.set("SUPABASE_URL", BASE_URL);
Deno.env.set("SUPABASE_ANON_KEY", "test-anon-key");
Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "test-service-key");
Deno.env.set("OPENROUTER_API_KEY", "test-openrouter-key");

type JsonRecord = Record<string, unknown>;

interface RecordedCall {
  url: string;
  method: string;
  body: string;
}

interface StubOptions {
  /** Response body of the claim_chat_quota RPC (default [{used:1,remaining:4}]). */
  quotaBody?: unknown;
  /** Response body of the consume_edge_rate_limit RPC. */
  rateLimitBody?: unknown;
  /** The expensive answer call (max_tokens 600) fails with 500. */
  answerFails?: boolean;
  /** GET on chat_messages (loadHistory) answers 500. */
  historyFails?: boolean;
  /** GET on chat_sessions?id=... (ownership check) answers 500. */
  sessionCheckFails?: boolean;
  /** POST on chat_messages (storeMessage) answers 500. */
  storeFails?: boolean;
}

function assert(condition: boolean, message: string): void {
  if (!condition) throw new Error(message);
}

function assertEquals(actual: unknown, expected: unknown, message: string): void {
  if (actual !== expected) {
    throw new Error(
      `${message}: erwartet ${JSON.stringify(expected)}, war ${JSON.stringify(actual)}`,
    );
  }
}

function jsonRes(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "content-type": "application/json" },
  });
}

function installFetch(options: StubOptions = {}) {
  const calls: RecordedCall[] = [];
  const original = globalThis.fetch;

  function route(url: string, method: string, body: string): Response {
    if (url.includes("/auth/v1/user")) return jsonRes({ id: USER_ID });
    if (url.includes("/rest/v1/rpc/consume_edge_rate_limit")) {
      return jsonRes(
        options.rateLimitBody ?? {
          allowed: true,
          limit: 120,
          remaining: 119,
          resetAt: new Date(Date.now() + 600_000).toISOString(),
          windowSeconds: 600,
        },
      );
    }
    if (url.includes("/rest/v1/rpc/prune_edge_rate_limits")) {
      return new Response(null, { status: 204 });
    }
    if (url.includes("/rest/v1/rpc/ensure_default_chat_session")) {
      return jsonRes(SESSION_ID);
    }
    if (url.includes("/rest/v1/rpc/touch_chat_session")) {
      return new Response(null, { status: 204 });
    }
    if (url.includes("/rest/v1/rpc/claim_chat_quota")) {
      return jsonRes(options.quotaBody ?? [{ used: 1, remaining: 4 }]);
    }
    if (url.includes("/rest/v1/rpc/refund_chat_quota")) {
      return new Response(null, { status: 204 });
    }
    if (url.includes("openrouter.ai")) {
      const parsed = JSON.parse(body) as JsonRecord;
      if (parsed.max_tokens === 50) {
        return jsonRes({
          choices: [{
            message: {
              content: JSON.stringify({ category: "fitness", confidence: "high" }),
            },
          }],
        });
      }
      if (options.answerFails) return jsonRes({ error: "upstream" }, 500);
      return jsonRes({
        choices: [{ message: { content: "Klar, machen wir." } }],
      });
    }
    if (url.includes("/rest/v1/chat_messages")) {
      if (method === "POST") {
        return options.storeFails
          ? jsonRes({ message: "rls" }, 500)
          : new Response(null, { status: 201 });
      }
      return options.historyFails ? jsonRes({ message: "kaputt" }, 500) : jsonRes([]);
    }
    if (url.includes("/rest/v1/chat_sessions")) {
      if (method === "PATCH") return new Response(null, { status: 204 });
      if (url.includes("select=title")) return jsonRes([{ title: "Egal" }]);
      if (url.includes("select=id")) {
        return options.sessionCheckFails
          ? jsonRes({ message: "kaputt" }, 500)
          : jsonRes([{ id: SESSION_ID }]);
      }
      return jsonRes([]);
    }
    throw new Error(`Unerwarteter fetch im Test: ${method} ${url}`);
  }

  globalThis.fetch = ((
    input: string | URL | Request,
    init?: RequestInit,
  ): Promise<Response> => {
    const url = typeof input === "string"
      ? input
      : input instanceof URL
      ? input.toString()
      : input.url;
    const method = (init?.method ?? "GET").toUpperCase();
    const body = typeof init?.body === "string" ? init.body : "";
    calls.push({ url, method, body });
    return Promise.resolve(route(url, method, body));
  }) as typeof globalThis.fetch;

  return {
    calls,
    callsTo: (fragment: string) => calls.filter((c) => c.url.includes(fragment)),
    postsTo: (fragment: string) =>
      calls.filter((c) => c.url.includes(fragment) && c.method === "POST"),
    restore: () => {
      globalThis.fetch = original;
    },
  };
}

function makeRequest(payload: JsonRecord): Request {
  return new Request("https://edge.test.invalid/coach-chat", {
    method: "POST",
    headers: {
      "authorization": "Bearer test-user-jwt",
      "content-type": "application/json",
    },
    body: JSON.stringify(payload),
  });
}

// ---------------------------------------------------------------------------

Deno.test("E1: leerer Quota-Row -> `remaining` FEHLT statt 0 (Composer-Sperre aus dem Nichts)", async () => {
  // claim_chat_quota answers 200 with an empty array (schema drift). That used
  // to become `remaining: 0`, locking the composer until midnight right after
  // a successful reply. The wire contract expresses "unknown" by omitting the
  // field; Flutter reads a missing remaining as "no update".
  const stub = installFetch({ quotaBody: [] });
  try {
    const res = await handleRequest(makeRequest({ message: "Wie viel Protein nach dem Training?" }));
    const body = await res.json() as JsonRecord;
    assertEquals(res.status, 200, "Status");
    assert(String(body.reply).length > 0, "Antwort kommt trotzdem");
    assert(!("remaining" in body), "'remaining' darf bei unbekanntem Stand NICHT erfunden werden");
  } finally {
    stub.restore();
  }
});

Deno.test("E10: der Erfolgs-Response traegt daily_limit (Client rechnet sonst gegen geratene 5)", async () => {
  const stub = installFetch();
  try {
    const res = await handleRequest(makeRequest({ message: "Wie viel Protein nach dem Training?" }));
    const body = await res.json() as JsonRecord;
    assertEquals(res.status, 200, "Status");
    assertEquals(typeof body.daily_limit, "number", "daily_limit ist eine Zahl");
    assertEquals(body.remaining, 4, "remaining aus dem RPC");
    assertEquals(stub.callsTo("refund_chat_quota").length, 0,
      "im Erfolgsfall wird NICHT refundiert — sonst waere das Limit wirkungslos");
  } finally {
    stub.restore();
  }
});

Deno.test("E2: Provider-Fehler -> ehrlicher 502 statt erfundener Coach-Antwort mit 200", async () => {
  // Used to persist a fake assistant message with refusal_reason
  // "model_refusal" and HTTP 200: indistinguishable from a real refusal and it
  // poisons the history of every follow-up.
  const stub = installFetch({ answerFails: true });
  try {
    const res = await handleRequest(makeRequest({ message: "Wie viel Protein nach dem Training?" }));
    const body = await res.json() as JsonRecord;
    assertEquals(res.status, 502, "Status");
    assertEquals(body.error, "provider_error", "Fehlercode");
    // The user message is stored (it is real), no invented assistant row.
    assertEquals(stub.postsTo("chat_messages").length, 1, "nur die User-Message persistiert");
    // The claimed slot is refunded: a provider outage must not burn the day.
    assertEquals(stub.callsTo("refund_chat_quota").length, 1, "Slot refundiert");
  } finally {
    stub.restore();
  }
});

Deno.test("E3: History nicht ladbar -> Abbruch VOR dem Quota-Claim statt kontextloser Antwort", async () => {
  // `if (!resp.ok) return []` used to answer follow-ups without context, and
  // since history loaded after the claim, the day's slot was gone anyway.
  const stub = installFetch({ historyFails: true });
  try {
    const res = await handleRequest(makeRequest({ message: "Und davon 200 g?" }));
    const body = await res.json() as JsonRecord;
    assertEquals(res.status, 500, "Status");
    assertEquals(body.error, "history_unavailable", "Fehlercode");
    assertEquals(stub.callsTo("claim_chat_quota").length, 0, "kein Slot verbrannt");
    assertEquals(stub.postsTo("chat_messages").length, 0, "nichts halb persistiert");
  } finally {
    stub.restore();
  }
});

Deno.test("E4: Besitzpruefung transient kaputt -> Fehler statt stiller Umleitung in die Default-Session", async () => {
  // `!resp.ok` used to share the fallthrough with "session is not yours", so
  // the message silently landed in a different conversation.
  const stub = installFetch({ sessionCheckFails: true });
  try {
    const res = await handleRequest(makeRequest({
      message: "Wie viel Protein nach dem Training?",
      session_id: SESSION_ID,
    }));
    const body = await res.json() as JsonRecord;
    assertEquals(res.status, 500, "Status");
    assertEquals(body.error, "session_unavailable", "Fehlercode");
    assertEquals(
      stub.callsTo("ensure_default_chat_session").length,
      0,
      "keine stille Umleitung in die Default-Session",
    );
  } finally {
    stub.restore();
  }
});

Deno.test("E5: User-Message nicht speicherbar -> Fehler statt Antwort auf eine Nachricht, die es nie gab", async () => {
  // `storeMessage` used to skip the resp.ok check: 200 plus a reply, but the
  // message was missing after a reload and in every follow-up's history.
  const stub = installFetch({ storeFails: true });
  try {
    const res = await handleRequest(makeRequest({ message: "Wie viel Protein nach dem Training?" }));
    const body = await res.json() as JsonRecord;
    assertEquals(res.status, 500, "Status");
    assertEquals(body.error, "store_failed", "Fehlercode");
    assert(
      stub.calls.every((c) => !c.url.includes("openrouter.ai") || JSON.parse(c.body).max_tokens === 50),
      "kein teurer Answer-Call fuer eine Nachricht, die nicht persistiert ist",
    );
    // The claimed slot is refunded here too.
    assertEquals(stub.callsTo("refund_chat_quota").length, 1, "Slot refundiert");
  } finally {
    stub.restore();
  }
});

Deno.test("E6: Rate-Limit-RPC mit kaputtem Shape -> rate_limit_unavailable statt erfundenem 429", async () => {
  // `allowed: data?.allowed === true` on an empty object became false: a 429
  // with invented numbers although no limit was ever measured. A broken shape
  // is a limiter outage, not a limit.
  const stub = installFetch({ rateLimitBody: {} });
  try {
    const res = await handleRequest(makeRequest({ message: "Wie viel Protein nach dem Training?" }));
    const body = await res.json() as JsonRecord;
    assertEquals(res.status, 500, "Status");
    assertEquals(body.error, "rate_limit_unavailable", "Fehlercode");
  } finally {
    stub.restore();
  }
});
