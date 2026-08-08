// Sentinel-Rest-Tests fuer handleRequest (Nachverifikation 2026-08-08):
// Stellen, an denen der Handler "ich weiss es nicht" (fehlender Row,
// gescheiterter Fetch, Provider-Fehler) in einen konkreten Wert verwandelte,
// den der Client nicht von echtem Wissen unterscheiden kann.
//
// Gleicher Stil wie handler_test.ts: gestubbtes globalThis.fetch, keine
// externen Test-Dependencies, `deno test --allow-env`.

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
  /** Antwort-Body des claim_chat_quota-RPC (Default: [{used:1,remaining:4}]). */
  quotaBody?: unknown;
  /** Antwort-Body des consume_edge_rate_limit-RPC. */
  rateLimitBody?: unknown;
  /** Der teure Answer-Call (max_tokens 600) scheitert mit 500. */
  answerFails?: boolean;
  /** GET auf chat_messages (loadHistory) antwortet 500. */
  historyFails?: boolean;
  /** GET auf chat_sessions?id=... (Besitzpruefung) antwortet 500. */
  sessionCheckFails?: boolean;
  /** POST auf chat_messages (storeMessage) antwortet 500. */
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
  // claim_chat_quota antwortet 200 mit leerem Array (Schema-Drift, kaputter
  // Return). Frueher wurde daraus `remaining: 0` — der Client sperrte den
  // Composer bis Mitternacht, direkt nach einer ERFOLGREICHEN Antwort. Der
  // Wire-Vertrag kann "weiss ich nicht" ausdruecken: Feld weglassen
  // (Flutter behandelt fehlendes remaining als "kein Update").
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
  } finally {
    stub.restore();
  }
});

Deno.test("E2: Provider-Fehler -> ehrlicher 502 statt erfundener Coach-Antwort mit 200", async () => {
  // Frueher: catch -> reply "Da ging gerade was schief..." als PERSISTIERTE
  // Assistant-Nachricht, refusal_reason "model_refusal", HTTP 200. Der Client
  // kann das nicht von einer echten Refusal unterscheiden, die Fake-Zeile
  // vergiftet als History den Kontext aller Folgefragen.
  const stub = installFetch({ answerFails: true });
  try {
    const res = await handleRequest(makeRequest({ message: "Wie viel Protein nach dem Training?" }));
    const body = await res.json() as JsonRecord;
    assertEquals(res.status, 502, "Status");
    assertEquals(body.error, "provider_error", "Fehlercode");
    // Die User-Message ist gespeichert (sie ist echt), aber KEINE erfundene
    // Assistant-Zeile.
    assertEquals(stub.postsTo("chat_messages").length, 1, "nur die User-Message persistiert");
  } finally {
    stub.restore();
  }
});

Deno.test("E3: History nicht ladbar -> Abbruch VOR dem Quota-Claim statt kontextloser Antwort", async () => {
  // Frueher: `if (!resp.ok) return []` — der Coach beantwortete die
  // Folgefrage ohne Kontext ("und davon 200 g?"), der Nutzer haelt den
  // Kontextverlust fuer Modellversagen. Und weil die History NACH dem Claim
  // geladen wurde, war der Tages-Slot trotzdem weg.
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
  // Frueher fiel `!resp.ok` in denselben Fallthrough wie "Session gehoert
  // dir nicht" — die Nachricht landete kommentarlos in einer ANDEREN
  // Unterhaltung.
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
  // Frueher lief `storeMessage` ohne resp.ok-Pruefung: der Client bekam 200
  // samt Antwort, aber die Nachricht fehlte nach dem Reload und in der
  // History jeder Folgefrage.
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
  } finally {
    stub.restore();
  }
});

Deno.test("E6: Rate-Limit-RPC mit kaputtem Shape -> rate_limit_unavailable statt erfundenem 429", async () => {
  // Frueher wurde `allowed: data?.allowed === true` aus einem leeren Objekt
  // zu false — ein 429 "Zu viele Anfragen" mit erfundenen Zahlen, obwohl nie
  // ein Limit gemessen wurde. Ein kaputter Shape ist ein Ausfall des
  // Limiters, kein Limit.
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
