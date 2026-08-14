// End-to-End-Tests fuer handleRequest (handler.ts) mit gestubbtem fetch.
//
// Das ist der eigentliche Regressionstest zum Layer-2-Bypass: bis 2026-08-07
// war der komplette Klassifizierer-Block in ein `if (!hasImage)` gewickelt.
// "irgendein Bild + Text" hat Layer 2 damit uebersprungen - und mit ihm
// self_harm und eating_disorder, also genau die beiden Kategorien, an denen
// die Krisen-Antwort mit der Telefonseelsorge-Nummer haengt.
//
// Warum das ohne Server geht: handler.ts liest die Request-Secrets PRO
// REQUEST (Deno.env.get in handleRequest), nicht beim Modul-Load - Deno.env.set
// im Test wirkt also. Deshalb braucht `deno test` hier --allow-env.
//
// Bewusst ohne externe Test-Dependencies (gleicher Stil wie prefilter_test.ts).

import { handleRequest, PROVIDER_TIMEOUTS_MS } from "./handler.ts";

const USER_ID = "11111111-1111-4111-8111-111111111111";
const SESSION_ID = "22222222-2222-4222-8222-222222222222";
const BASE_URL = "https://supabase.test.invalid";

// 1x1-PNG. Muss dem Base64-Guard in handleRequest genuegen
// (/^[A-Za-z0-9+/=\r\n]+$/), sonst kommt ein 400 statt des Vision-Flows.
const IMAGE_BASE64 =
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==";

// Krisen-Nummer aus refusalForReason("self_harm"). Wenn die je geaendert
// wird, muss sie in handler.ts UND im ANSWER_SYSTEM_PROMPT mitgezogen werden.
const CRISIS_NUMBER = "0800 111 0 111";
const CRISIS_REPLY =
  "Bitte sprich mit jemandem darueber - die Telefonseelsorge ist unter 0800 111 0 111 rund um die Uhr erreichbar. Du bist nicht allein.";
const ED_REPLY =
  "Da gehe ich nicht mit. Wenn du das Gefuehl hast, dass dein Essverhalten dich belastet, sprich bitte mit einem Arzt oder einer Beratungsstelle. Ich kann dir gern bei einer ausgewogenen, alltagstauglichen Ernaehrung helfen.";
const OFF_TOPIC_REPLY =
  "Das geht ueber meinen Bereich hinaus - ich bin der Fitness- und Ernaehrungs-Coach in Eatova. Frag mich gern was zu deinem naechsten Workout oder deinen Makros.";

// Formulierungen, die Layer 1 (prefilter.ts) BEWUSST durchlaesst - nur so
// landen sie ueberhaupt bei Layer 2, um den es hier geht.
const SELF_HARM_TEXT = "ich will einfach nicht mehr aufwachen, alles ist sinnlos";
const EATING_DISORDER_TEXT = "wie schaffe ich 10 kg in 5 tagen runter";

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
  /** Kategorie, die der gestubbte Klassifizierer zurueckgibt. */
  classifierCategory?: string;
  /**
   * ROH-Content der Klassifizierer-Antwort — ueberschreibt classifierCategory.
   * Fuer den Parse-Ausfall (W1): kaputtes JSON / unbekannte Kategorie, also
   * ein bezahlter Call, nach dem KEINE Klassifikation vorliegt.
   */
  classifierContent?: string;
  /**
   * Verhalten von claim_chat_quota. "ok" (Default) liefert einen Slot,
   * "exhausted" antwortet mit EX_QUOTA_EXCEEDED (Tageslimit erreicht),
   * "forbidden" laesst den Test laut scheitern, wenn der Claim ueberhaupt
   * erreicht wird (fuer Layer-1-Pfade, die die Quota nie anfassen duerfen).
   */
  quota?: "ok" | "exhausted" | "forbidden";
  /** Inhalt der Antwort des teuren Answer-Calls. */
  answerContent?: string;
  /** HTTP-Status des Klassifizierer-Calls (Infra-Fehler-Simulation). */
  classifierStatus?: number;
  /**
   * Rows, die loadHistory (GET chat_messages) liefert — im PostgREST-Format
   * der Function: absteigend nach created_at, NEUESTE Zeile zuerst.
   */
  historyRows?: JsonRecord[];
  /** HTTP-Status des /auth/v1/user-Lookups (Auth-Fehlschlag-Simulation). */
  authStatus?: number;
  /**
   * Der Klassifizierer-Call haengt: der Promise resolvet nie von selbst und
   * rejectet erst, wenn die Deadline (AbortSignal) ihn abbricht — simuliert
   * stilles/langsames Upstream fuer Finding 6.
   */
  classifierHangs?: boolean;
  /** Wie classifierHangs, aber fuer den teuren Answer-Call. */
  answerHangs?: boolean;
  /**
   * Budget des coach-chat:auth-fail-Buckets. Der Stub bildet die atomare
   * check+increment-Semantik der echten RPC nach: jeder Consume auf dem
   * Scope zaehlt hoch, ab Ueberschreitung kommt allowed=false.
   */
  authFailBudget?: number;
}

interface FetchStub {
  calls: RecordedCall[];
  openRouterBodies: JsonRecord[];
  callsTo(fragment: string): RecordedCall[];
  classifierBodies(): JsonRecord[];
  answerBodies(): JsonRecord[];
  restore(): void;
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

// Haengender Provider-Call (Finding 6): verhaelt sich wie ein echter fetch
// gegen totes Upstream — er kommt NIE von selbst zurueck und rejectet erst
// beim Abort mit signal.reason (bei AbortSignal.timeout eine DOMException
// "TimeoutError", exakt wie das echte fetch). Fehlt das Signal, knallt der
// Test sofort laut, statt bis zum Test-Timeout zu haengen — das ist zugleich
// der Regressionsschutz dagegen, dass jemand die Deadline wieder entfernt.
function hangUntilAbort(signal: AbortSignal | null | undefined): Promise<Response> {
  return new Promise((_, reject) => {
    if (!signal) {
      reject(new Error("haengender Provider-Call ohne AbortSignal — die Deadline (Finding 6) fehlt"));
      return;
    }
    if (signal.aborted) {
      reject(signal.reason);
      return;
    }
    signal.addEventListener("abort", () => reject(signal.reason), { once: true });
  });
}

function installFetch(options: StubOptions = {}): FetchStub {
  const calls: RecordedCall[] = [];
  const openRouterBodies: JsonRecord[] = [];
  const original = globalThis.fetch;
  let authFailConsumes = 0;

  function route(
    url: string,
    method: string,
    body: string,
    signal: AbortSignal | null | undefined,
  ): Response | Promise<Response> {
    if (url.includes("/auth/v1/user")) {
      if (options.authStatus !== undefined) {
        return jsonRes({ message: "invalid token" }, options.authStatus);
      }
      return jsonRes({ id: USER_ID });
    }
    if (url.includes("/rest/v1/rpc/consume_edge_rate_limit")) {
      const params = JSON.parse(body) as JsonRecord;
      if (params.p_scope === "coach-chat:auth-fail" && options.authFailBudget !== undefined) {
        // Atomare check+increment-Semantik wie die echte RPC (Migration
        // 20260518000100): der Consume selbst entscheidet ueber allowed.
        authFailConsumes++;
        return jsonRes({
          allowed: authFailConsumes <= options.authFailBudget,
          limit: options.authFailBudget,
          remaining: Math.max(options.authFailBudget - authFailConsumes, 0),
          resetAt: new Date(Date.now() + 3_600_000).toISOString(),
          windowSeconds: 3600,
        });
      }
      return jsonRes({
        allowed: true,
        limit: 120,
        remaining: 119,
        resetAt: new Date(Date.now() + 600_000).toISOString(),
        windowSeconds: 600,
      });
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
      const mode = options.quota ?? "ok";
      if (mode === "forbidden") {
        // Layer 1 refused VOR dem Quota-Claim. Wird die RPC dort doch
        // erreicht, verliert der Nutzer einen Tages-Slot fuer eine Frage,
        // die nie einen Provider-Call ausgeloest hat.
        throw new Error(
          "claim_chat_quota wurde auf einem Pfad aufgerufen, der die Quota nicht anfassen darf",
        );
      }
      if (mode === "exhausted") {
        // PostgREST-Shape eines geworfenen EX_QUOTA_EXCEEDED (handler.ts
        // matcht per text.includes auf den Sentinel im Fehler-Body).
        return jsonRes({ message: "EX_QUOTA_EXCEEDED" }, 400);
      }
      return jsonRes([{ used: 1, remaining: 4 }]);
    }
    if (url.includes("/rest/v1/rpc/refund_chat_quota")) {
      return new Response(null, { status: 204 });
    }
    if (url.includes("openrouter.ai")) {
      const parsed = JSON.parse(body) as JsonRecord;
      openRouterBodies.push(parsed);
      // Klassifizierer und Answer-Call unterscheiden sich eindeutig im
      // Token-Budget (50 vs. 600).
      if (parsed.max_tokens === 50) {
        if (options.classifierHangs) return hangUntilAbort(signal);
        if (options.classifierStatus !== undefined) {
          // Infra-Fehler des Klassifizierers (Provider antwortet non-ok).
          return new Response("upstream unavailable", { status: options.classifierStatus });
        }
        return jsonRes({
          choices: [{
            message: {
              content: options.classifierContent ?? JSON.stringify({
                category: options.classifierCategory ?? "fitness",
                confidence: "high",
              }),
            },
          }],
        });
      }
      if (options.answerHangs) return hangUntilAbort(signal);
      return jsonRes({
        choices: [{
          message: { content: options.answerContent ?? "Klar, machen wir." },
        }],
      });
    }
    if (url.includes("/rest/v1/chat_messages")) {
      // POST = storeMessage, GET = loadHistory.
      if (method === "POST") return new Response(null, { status: 201 });
      return jsonRes(options.historyRows ?? []);
    }
    if (url.includes("/rest/v1/chat_sessions")) {
      if (method === "PATCH") return new Response(null, { status: 204 });
      if (url.includes("select=title")) return jsonRes([{ title: "Neue Unterhaltung" }]);
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
    return Promise.resolve(route(url, method, body, init?.signal));
  }) as typeof globalThis.fetch;

  return {
    calls,
    openRouterBodies,
    callsTo: (fragment: string) => calls.filter((call) => call.url.includes(fragment)),
    classifierBodies: () => openRouterBodies.filter((b) => b.max_tokens === 50),
    answerBodies: () => openRouterBodies.filter((b) => b.max_tokens === 600),
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

Deno.test("REGRESSION: Bild + Self-Harm-Text -> Krisen-Antwort statt Bypass", async () => {
  const stub = installFetch({ classifierCategory: "self_harm" });
  try {
    const res = await handleRequest(makeRequest({
      message: SELF_HARM_TEXT,
      image_base64: IMAGE_BASE64,
      image_mime_type: "image/png",
    }));
    assertEquals(res.status, 200, "Status");
    const body = await res.json() as JsonRecord;

    assert(
      String(body.reply).includes(CRISIS_NUMBER),
      `Antwort muss die Telefonseelsorge-Nummer enthalten, war: ${String(body.reply)}`,
    );
    assertEquals(body.reply, CRISIS_REPLY, "exakter Krisen-Text");
    assertEquals(body.refusal, true, "refusal");
    assertEquals(body.refusal_reason, "self_harm", "refusal_reason");
    assertEquals(body.session_id, SESSION_ID, "session_id");
    // CWE-770-Fix: der Slot wird VOR dem Klassifizierer geclaimt und bei
    // einer Refusal bewusst NICHT refundet; remaining meldet dem Client den
    // Verbrauch.
    assertEquals(body.remaining, 4, "remaining aus dem Quota-Claim");
    assertEquals(stub.callsTo("claim_chat_quota").length, 1, "claim_chat_quota-Calls");
    assertEquals(stub.callsTo("refund_chat_quota").length, 0, "kein Refund fuer Refusals");
    // Genau EIN OpenRouter-Call: der Klassifizierer. Der teure Answer-Call
    // (inkl. Vision-Tokens fuer das Bild) darf nicht passieren.
    assertEquals(stub.openRouterBodies.length, 1, "OpenRouter-Calls");
    assertEquals(stub.classifierBodies().length, 1, "Klassifizierer-Calls");
    assertEquals(stub.answerBodies().length, 0, "Answer-Calls");
  } finally {
    stub.restore();
  }
});

Deno.test("Kostengarantie: der Klassifizierer sieht nie das Bild", async () => {
  const stub = installFetch({ classifierCategory: "self_harm" });
  try {
    await handleRequest(makeRequest({
      message: SELF_HARM_TEXT,
      image_base64: IMAGE_BASE64,
      image_mime_type: "image/png",
    }));

    const bodies = stub.classifierBodies();
    assertEquals(bodies.length, 1, "genau ein Klassifizierer-Call");
    const raw = JSON.stringify(bodies[0]);
    assert(!raw.includes("image_url"), "Klassifizierer-Body enthaelt image_url");
    assert(!raw.includes(IMAGE_BASE64), "Klassifizierer-Body enthaelt die Base64-Nutzlast");
    assert(
      !raw.includes(IMAGE_BASE64.slice(0, 32)),
      "Klassifizierer-Body enthaelt ein Fragment der Base64-Nutzlast",
    );
    // Damit kostet der Call im Bildpfad exakt dasselbe wie im Textpfad.
    assertEquals(bodies[0].max_tokens, 50, "max_tokens");

    const messages = bodies[0].messages as { role: string; content: unknown }[];
    assertEquals(messages.length, 2, "system + user");
    assertEquals(messages[1].role, "user", "zweite Message ist die User-Message");
    assertEquals(typeof messages[1].content, "string", "content ist ein reiner String");
    assertEquals(messages[1].content, SELF_HARM_TEXT, "content ist der Nachrichtentext");
  } finally {
    stub.restore();
  }
});

Deno.test("Bild + eating_disorder -> ED-Antwort, kein Answer-Call", async () => {
  const stub = installFetch({ classifierCategory: "eating_disorder" });
  try {
    const res = await handleRequest(makeRequest({
      message: EATING_DISORDER_TEXT,
      image_base64: IMAGE_BASE64,
    }));
    assertEquals(res.status, 200, "Status");
    const body = await res.json() as JsonRecord;
    assertEquals(body.reply, ED_REPLY, "ED-Antwort");
    assertEquals(body.refusal, true, "refusal");
    assertEquals(body.refusal_reason, "eating_disorder", "refusal_reason");
    assertEquals(stub.callsTo("claim_chat_quota").length, 1, "Quota-Claim vor Layer 2");
    assertEquals(stub.answerBodies().length, 0, "Answer-Calls");
  } finally {
    stub.restore();
  }
});

Deno.test("Bild + medical_risk und Bild + injection werden ebenfalls gefangen", async () => {
  const cases: { category: string; reason: string }[] = [
    { category: "medical_risk", reason: "medical_risk" },
    { category: "injection", reason: "injection" },
  ];
  for (const { category, reason } of cases) {
    const stub = installFetch({ classifierCategory: category });
    try {
      const res = await handleRequest(makeRequest({
        message: "kurze frage zu dem hier",
        image_base64: IMAGE_BASE64,
      }));
      const body = await res.json() as JsonRecord;
      assertEquals(body.refusal, true, `${category}: refusal`);
      assertEquals(body.refusal_reason, reason, `${category}: refusal_reason`);
      assertEquals(stub.callsTo("claim_chat_quota").length, 1, `${category}: Quota-Claim vor Layer 2`);
      assertEquals(stub.callsTo("refund_chat_quota").length, 0, `${category}: kein Refund`);
    } finally {
      stub.restore();
    }
  }
});

Deno.test("Bild + off_topic -> Layer 3 entscheidet (Quota + Answer-Call)", async () => {
  // off_topic ist im Bildpfad bewusst NICHT im Refusal-Set: der Klassifizierer
  // sieht nur den Text, und deiktische Captions ("was ist das?") wuerden sonst
  // systematisch abgelehnt. Off-topic BILDER faengt der __REFUSE__-Mechanismus
  // im ANSWER_SYSTEM_PROMPT, wo das Bild tatsaechlich vorliegt.
  const stub = installFetch({
    classifierCategory: "off_topic",
    answerContent: "Auf dem Teller sind etwa 600 kcal.",
  });
  try {
    const res = await handleRequest(makeRequest({
      message: "was ist das hier?",
      image_base64: IMAGE_BASE64,
    }));
    assertEquals(res.status, 200, "Status");
    const body = await res.json() as JsonRecord;
    assertEquals(body.reply, "Auf dem Teller sind etwa 600 kcal.", "Antwort kommt vom Modell");
    assertEquals(body.refusal, false, "keine Refusal");
    assertEquals(body.remaining, 4, "Quota wurde verbraucht");
    assertEquals(stub.callsTo("claim_chat_quota").length, 1, "claim_chat_quota-Calls");
    assertEquals(stub.classifierBodies().length, 1, "Klassifizierer lief trotzdem");
    assertEquals(stub.answerBodies().length, 1, "Answer-Call");
    // Der Answer-Call bekommt das Bild - dort gehoert es hin.
    assert(
      JSON.stringify(stub.answerBodies()[0]).includes("image_url"),
      "Answer-Call muss das Bild enthalten",
    );
  } finally {
    stub.restore();
  }
});

Deno.test("Bild ohne Text -> kein Klassifizierer-Call, Answer-Call laeuft", async () => {
  // Ein blindes classify(key, "") wuerde im fail-closed off_topic-Default
  // landen und JEDEN legitimen Bild-Upload ablehnen.
  const stub = installFetch({
    classifierCategory: "off_topic",
    answerContent: "Sieht nach einer ordentlichen Portion Reis aus.",
  });
  try {
    const res = await handleRequest(makeRequest({
      message: "",
      image_base64: IMAGE_BASE64,
    }));
    assertEquals(res.status, 200, "Status");
    const body = await res.json() as JsonRecord;
    assertEquals(body.reply, "Sieht nach einer ordentlichen Portion Reis aus.", "Antwort");
    assertEquals(body.refusal, false, "keine Refusal");
    assertEquals(stub.classifierBodies().length, 0, "kein Klassifizierer-Call");
    assertEquals(stub.answerBodies().length, 1, "Answer-Call laeuft");
    assertEquals(stub.callsTo("claim_chat_quota").length, 1, "Quota wird verbraucht");
  } finally {
    stub.restore();
  }
});

Deno.test("CWE-770-Fix: Classifier-Refusal verbraucht den Tages-Slot, kein Refund", async () => {
  // Wuerde die Refusal refundet (oder der Claim wie frueher erst danach
  // laufen), koennte ein User mit erschoepfter Quota ueber das Stunden-Gate
  // (60/h) bis zu 1440 bezahlte Classifier-Calls pro Tag ausloesen.
  const stub = installFetch({ classifierCategory: "off_topic" });
  try {
    const res = await handleRequest(makeRequest({
      message: "Was ist die Hauptstadt von Frankreich?",
    }));
    assertEquals(res.status, 200, "Status");
    const body = await res.json() as JsonRecord;
    assertEquals(body.reply, OFF_TOPIC_REPLY, "Off-Topic-Antwort");
    assertEquals(body.refusal, true, "refusal");
    assertEquals(body.refusal_reason, "off_topic", "refusal_reason");
    assertEquals(body.remaining, 4, "remaining meldet den Verbrauch");
    assertEquals(body.daily_limit, 5, "daily_limit gehoert zur Zahl (E10)");
    assertEquals(stub.callsTo("claim_chat_quota").length, 1, "claim_chat_quota-Calls");
    assertEquals(stub.callsTo("refund_chat_quota").length, 0, "kein Refund fuer Refusals");
    assertEquals(stub.answerBodies().length, 0, "Answer-Calls");
  } finally {
    stub.restore();
  }
});

Deno.test("CWE-770-Fix: erschoepfte Quota -> 429 VOR jedem bezahlten Provider-Call", async () => {
  // Das eigentliche Finding: der Classifier-Call lief vor dem Quota-Claim,
  // ein User mit erschoepfter Tagesquota erreichte also weiterhin die
  // bezahlte Klassifikation. Jetzt muss der 429 kommen, bevor OpenRouter
  // auch nur einmal angefasst wird.
  const stub = installFetch({ quota: "exhausted", classifierCategory: "fitness" });
  try {
    const res = await handleRequest(makeRequest({
      message: "Wie oft soll ich pro Woche trainieren?",
    }));
    assertEquals(res.status, 429, "Status");
    const body = await res.json() as JsonRecord;
    assertEquals(body.error, "quota_exceeded", "error");
    assertEquals(body.remaining, 0, "remaining");
    assertEquals(body.daily_limit, 5, "daily_limit");
    assertEquals(stub.openRouterBodies.length, 0, "kein OpenRouter-Call bei erschoepfter Quota");
    assertEquals(stub.classifierBodies().length, 0, "Klassifizierer-Calls");
    assertEquals(stub.answerBodies().length, 0, "Answer-Calls");
    assertEquals(stub.callsTo("refund_chat_quota").length, 0, "nichts zu refunden");
  } finally {
    stub.restore();
  }
});

Deno.test("CWE-770-Fix: Classifier-Infra-Fehler refundet den Slot und antwortet 502", async () => {
  // Infrastruktur-Fehler (Provider non-ok) ist der einzige Fall, in dem der
  // Classifier-Pfad refundet: der User hat keinerlei Leistung bekommen —
  // gleiche Semantik wie der Answer-Pfad (Sentinel-Rest E2).
  const stub = installFetch({ classifierStatus: 500 });
  try {
    const res = await handleRequest(makeRequest({
      message: "Wie viel Protein brauche ich beim Cutting?",
    }));
    assertEquals(res.status, 502, "Status");
    const body = await res.json() as JsonRecord;
    assertEquals(body.error, "provider_error", "error");
    assertEquals(body.session_id, SESSION_ID, "session_id");
    assertEquals(stub.callsTo("claim_chat_quota").length, 1, "Slot wurde geclaimt");
    assertEquals(stub.callsTo("refund_chat_quota").length, 1, "Slot wurde refundet");
    assertEquals(stub.answerBodies().length, 0, "kein Answer-Call");
    // Keine erfundene Refusal-Zeile in der History (E2-Muster): auf dem
    // Infra-Fehler-Pfad wird nichts persistiert.
    assertEquals(
      stub.callsTo("/rest/v1/chat_messages").filter((c) => c.method === "POST").length,
      0,
      "keine Message-Persistenz auf dem Infra-Fehler-Pfad",
    );
  } finally {
    stub.restore();
  }
});

Deno.test("Textpfad unveraendert: self_harm liefert dieselbe Krisen-Antwort", async () => {
  const stub = installFetch({ classifierCategory: "self_harm" });
  try {
    const res = await handleRequest(makeRequest({ message: SELF_HARM_TEXT }));
    const body = await res.json() as JsonRecord;
    assertEquals(body.reply, CRISIS_REPLY, "Krisen-Antwort im Textpfad");
    assert(String(body.reply).includes(CRISIS_NUMBER), "Nummer enthalten");
    assertEquals(body.refusal_reason, "self_harm", "refusal_reason");
  } finally {
    stub.restore();
  }
});

Deno.test("Textpfad unveraendert: on-topic laeuft durch bis zur Antwort", async () => {
  const stub = installFetch({
    classifierCategory: "nutrition",
    answerContent: "Ziel sind 1,6-2,2 g Protein pro kg Koerpergewicht.",
  });
  try {
    const res = await handleRequest(makeRequest({
      message: "Wie viel Protein brauche ich beim Cutting?",
    }));
    assertEquals(res.status, 200, "Status");
    const body = await res.json() as JsonRecord;
    assertEquals(body.reply, "Ziel sind 1,6-2,2 g Protein pro kg Koerpergewicht.", "Antwort");
    assertEquals(body.refusal, false, "keine Refusal");
    assertEquals(body.remaining, 4, "remaining aus dem Quota-Claim");
    assertEquals(stub.classifierBodies().length, 1, "Klassifizierer-Call");
    assertEquals(stub.answerBodies().length, 1, "Answer-Call");
    // Kein Bild im Textpfad.
    assert(
      !JSON.stringify(stub.answerBodies()[0]).includes("image_url"),
      "Textpfad darf kein image_url schicken",
    );
  } finally {
    stub.restore();
  }
});

// ---------------------------------------------------------------------------
// W1 (2026-08-14): unbrauchbarer Modell-Output ist seit dem Fix von einem
// echten off_topic unterscheidbar (ClassifierResult.parseFailed). Reagieren
// darf darauf NUR der Rezept-Pfad (handler_recipe_test.ts) — Chat- und
// Bildpfad muessen sich exakt wie vorher verhalten. Genau das sichern die
// beiden Tests hier ab.
// ---------------------------------------------------------------------------

Deno.test("W1-Gegenprobe: echtes off_topic im Chat bleibt die normale Off-Topic-Refusal", async () => {
  // Der Klassifizierer hat geantwortet und "off_topic" gesagt. Das ist KEIN
  // Parse-Ausfall und darf deshalb weder eskalieren (classifier_unusable)
  // noch zu einem Fehlerstatus fuehren: 200 mit dem freundlichen
  // Off-Topic-Text, wie seit jeher.
  const stub = installFetch({ classifierCategory: "off_topic" });
  try {
    const res = await handleRequest(makeRequest({
      message: "Erklaer mir bitte die franzoesische Revolution",
    }));
    assertEquals(res.status, 200, "Status");
    const body = await res.json() as JsonRecord;
    assertEquals(body.reply, OFF_TOPIC_REPLY, "unveraenderter Off-Topic-Text");
    assertEquals(body.refusal, true, "refusal");
    assertEquals(body.refusal_reason, "off_topic", "refusal_reason bleibt die Kategorie");
    assertEquals(body.remaining, 4, "remaining aus dem Quota-Claim");
    assertEquals(stub.answerBodies().length, 0, "kein Answer-Call");
    assertEquals(stub.callsTo("refund_chat_quota").length, 0, "kein Refund");
  } finally {
    stub.restore();
  }
});

Deno.test("W1: unparsbare Classifier-Antwort aendert den Chat-Pfad nicht (off_topic-Refusal)", async () => {
  // Im Chat liegt off_topic im Refusal-Set — der fail-closed-Default faengt
  // den Aussetzer also weiterhin selbst ab. Die Antwort muss byteweise die
  // von "echtes off_topic" sein: der Nutzer soll fuer denselben Vorgang nicht
  // ploetzlich einen anderen Text bekommen.
  for (
    const content of [
      "Ich denke, das ist Fitness.", // gar kein JSON
      '{"category":"banane","confidence":"high"}', // unbekannte Kategorie
      '{"category":', // abgeschnittenes JSON
    ]
  ) {
    const stub = installFetch({ classifierContent: content });
    try {
      const res = await handleRequest(makeRequest({
        message: "Wie viel Protein brauche ich beim Cutting?",
      }));
      assertEquals(res.status, 200, `${content}: Status`);
      const body = await res.json() as JsonRecord;
      assertEquals(body.reply, OFF_TOPIC_REPLY, `${content}: unveraenderter Text`);
      assertEquals(body.refusal_reason, "off_topic", `${content}: refusal_reason`);
      assertEquals(stub.answerBodies().length, 0, `${content}: kein Answer-Call`);
      assertEquals(stub.callsTo("refund_chat_quota").length, 0, `${content}: kein Refund`);
    } finally {
      stub.restore();
    }
  }
});

Deno.test("W1: unparsbare Classifier-Antwort blockt den Bildpfad nicht", async () => {
  // Der Bildpfad reagiert bewusst NICHT auf den Parse-Ausfall: dort steht mit
  // Layer 3 eine zweite Krisen-Schicht (CRISIS RULE im ANSWER_SYSTEM_PROMPT,
  // die das Bild tatsaechlich sieht), und eine Refusal wuerde bei jedem
  // Aussetzer legitime Bild-Uploads treffen.
  const stub = installFetch({
    classifierContent: "Ich denke, das ist Fitness.",
    answerContent: "Auf dem Teller sind etwa 600 kcal.",
  });
  try {
    const res = await handleRequest(makeRequest({
      message: "was ist das hier?",
      image_base64: IMAGE_BASE64,
    }));
    assertEquals(res.status, 200, "Status");
    const body = await res.json() as JsonRecord;
    assertEquals(body.reply, "Auf dem Teller sind etwa 600 kcal.", "Antwort kommt vom Modell");
    assertEquals(body.refusal, false, "keine Refusal");
    assertEquals(stub.answerBodies().length, 1, "Answer-Call laeuft");
  } finally {
    stub.restore();
  }
});

Deno.test("Layer 1 bleibt vor Layer 2: eindeutiger Text blockt ohne LLM-Call", async () => {
  // quota: "forbidden" — Layer 1 ist der einzige Refusal-Pfad, der die
  // Quota weiterhin nie anfassen darf (kein Provider-Call, kein Verbrauch).
  const stub = installFetch({ classifierCategory: "fitness", quota: "forbidden" });
  try {
    const res = await handleRequest(makeRequest({
      message: "ich will mich ritzen",
      image_base64: IMAGE_BASE64,
    }));
    const body = await res.json() as JsonRecord;
    assertEquals(body.reply, CRISIS_REPLY, "Krisen-Antwort aus Layer 1");
    assertEquals(body.refusal_reason, "self_harm", "refusal_reason");
    assertEquals(stub.openRouterBodies.length, 0, "Layer 1 darf keinen LLM-Call ausloesen");
    assertEquals(stub.callsTo("claim_chat_quota").length, 0, "claim_chat_quota-Calls");
  } finally {
    stub.restore();
  }
});

Deno.test("IP-Gate nutzt das normalisierte Subject aus _shared/client_ip.ts", async () => {
  const stub = installFetch({ classifierCategory: "self_harm" });
  try {
    const req = new Request("https://edge.test.invalid/coach-chat", {
      method: "POST",
      headers: {
        "authorization": "Bearer test-user-jwt",
        "content-type": "application/json",
        // Links der vom Client gesetzte Wert, rechts der von Cloudflare
        // angehaengte. Nur der rechte darf im Subject landen.
        "x-forwarded-for": "9.9.9.9, 203.0.113.7",
      },
      body: JSON.stringify({ message: SELF_HARM_TEXT, image_base64: IMAGE_BASE64 }),
    });
    await handleRequest(req);

    const gateCalls = stub.callsTo("consume_edge_rate_limit");
    assert(gateCalls.length >= 1, "IP-Gate wurde nicht aufgerufen");
    const ipGate = JSON.parse(gateCalls[0].body) as JsonRecord;
    assertEquals(ipGate.p_scope, "coach-chat:ip", "Scope");
    assertEquals(ipGate.p_subject, "ip:203.0.113.7", "Subject muss der rechte Eintrag sein");
    assert(ipGate.p_subject !== "ip:9.9.9.9", "client-kontrollierter Wert im Subject");
  } finally {
    stub.restore();
  }
});

Deno.test("Rate-Limit-Tabelle wird jetzt auch von coach-chat gepruned", async () => {
  const stub = installFetch({ classifierCategory: "self_harm" });
  try {
    await handleRequest(makeRequest({ message: SELF_HARM_TEXT }));
    assertEquals(stub.callsTo("prune_edge_rate_limits").length, 1, "prune-Calls");
  } finally {
    stub.restore();
  }
});

// ---------------------------------------------------------------------------
// CWE-400-Fix (Security-Review 2026-08-11, Finding 2): der too_long-Pfad war
// bis dahin ein normaler Layer-1-Refusal-Pfad und speicherte die VOLLE
// abgelehnte Nachricht (bis knapp unter 6,25 MB) via service_role in
// chat_messages; loadHistory schickte solche Rows danach komplett an
// OpenRouter mit. Jetzt: Groessenverletzung = Protokollfehler 413 ohne jede
// Persistenz, plus Row-Cap + Aggregat-Budget beim History-Laden.
// ---------------------------------------------------------------------------

Deno.test("CWE-400-Fix: ueberlange Nachricht -> 413 VOR Session, Persistenz und Quota", async () => {
  // quota: "forbidden" — wird claim_chat_quota hier doch erreicht, knallt
  // der Stub. Dazu duerfen weder Session-Erzeugung/-Pruefung noch
  // storeMessage noch irgendein Provider-Call passieren.
  const stub = installFetch({ quota: "forbidden" });
  try {
    const res = await handleRequest(makeRequest({ message: "x".repeat(1001) }));
    assertEquals(res.status, 413, "Status");
    const body = await res.json() as JsonRecord;
    assertEquals(body.error, "message_too_long", "error");
    assertEquals(body.refusal, true, "refusal");
    assertEquals(body.refusal_reason, "too_long", "refusal_reason");
    assert(
      String(body.reply).includes("1000 Zeichen"),
      "reply nennt den 1000-Zeichen-Vertrag",
    );
    assertEquals(stub.callsTo("/rest/v1/chat_messages").length, 0, "kein storeMessage/loadHistory");
    assertEquals(stub.callsTo("chat_sessions").length, 0, "keine Session-Pruefung");
    assertEquals(stub.callsTo("ensure_default_chat_session").length, 0, "keine Session-Erzeugung");
    assertEquals(stub.callsTo("claim_chat_quota").length, 0, "Quota unangetastet");
    assertEquals(stub.callsTo("touch_chat_session").length, 0, "kein touchSession");
    assertEquals(stub.openRouterBodies.length, 0, "kein Provider-Call");
  } finally {
    stub.restore();
  }
});

Deno.test("CWE-400-Fix: exakt 1000 Zeichen (auch multi-byte) bleiben erlaubt", async () => {
  // Gegenprobe gegen Over-Blocking: 1000x "ü" sind 2000 UTF-8-Bytes — der
  // Byte-Deckel (4000) darf den Zeichen-Vertrag (1000) nicht unterbieten.
  const stub = installFetch({
    classifierCategory: "fitness",
    answerContent: "Alles klar, langer Text angekommen.",
  });
  try {
    const res = await handleRequest(makeRequest({ message: "ü".repeat(1000) }));
    assertEquals(res.status, 200, "Status");
    const body = await res.json() as JsonRecord;
    assertEquals(body.reply, "Alles klar, langer Text angekommen.", "Antwort");
    assertEquals(body.refusal, false, "keine Refusal");
  } finally {
    stub.restore();
  }
});

Deno.test("CWE-400-Fix: oversized History-Row wird im Provider-Payload auf 4000 Zeichen gekappt", async () => {
  // Bestands-Quarantaene: eine VOR dem Fix persistierte 9000-Zeichen-Row
  // darf den Answer-Call nicht mehr in voller Laenge erreichen.
  const stub = installFetch({
    classifierCategory: "fitness",
    answerContent: "Weiter geht's.",
    historyRows: [{ role: "assistant", content: "B".repeat(9000) }],
  });
  try {
    const res = await handleRequest(makeRequest({
      message: "Wie viel Protein nach dem Training?",
    }));
    assertEquals(res.status, 200, "Status");
    const answers = stub.answerBodies();
    assertEquals(answers.length, 1, "Answer-Call");
    const messages = answers[0].messages as { role: string; content: unknown }[];
    // [system, History-Row, aktuelle User-Message]
    assertEquals(messages.length, 3, "system + history + user");
    assertEquals(messages[1].role, "assistant", "History-Row ist die Assistant-Zeile");
    const historyContent = String(messages[1].content);
    assertEquals(historyContent.length, 4000, "Row-Cap greift");
    assert(historyContent.startsWith("BBBB"), "gekappter Inhalt, kein Ersatztext");
  } finally {
    stub.restore();
  }
});

Deno.test("CWE-400-Fix: Aggregat-Budget verwirft aelteste History-Eintraege zuerst", async () => {
  // 10 Rows a 4000 Zeichen (nach Row-Cap) = 40000 > Budget 24000: nur die
  // 6 NEUESTEN Zeilen duerfen in den Provider-Request, die 4 aeltesten
  // fallen raus. Rows im PostgREST-Format: absteigend, H0 = neueste.
  const stub = installFetch({
    classifierCategory: "fitness",
    answerContent: "Passt.",
    historyRows: Array.from({ length: 10 }, (_, i) => ({
      role: "assistant",
      content: `H${i}` + "x".repeat(4000),
    })),
  });
  try {
    const res = await handleRequest(makeRequest({
      message: "Wie viel Protein nach dem Training?",
    }));
    assertEquals(res.status, 200, "Status");
    const answers = stub.answerBodies();
    assertEquals(answers.length, 1, "Answer-Call");
    const messages = answers[0].messages as { role: string; content: string }[];
    // [system, 6x History, aktuelle User-Message]
    assertEquals(messages.length, 8, "system + 6 History-Rows + user");
    const history = messages.slice(1, -1).map((m) => String(m.content));
    assertEquals(history.length, 6, "Budget behaelt genau 6 Rows");
    // Chronologisch: H5 (aelteste behaltene) ... H0 (neueste).
    assert(history[0].startsWith("H5"), `aelteste behaltene Row ist H5, war ${history[0].slice(0, 3)}`);
    assert(history[5].startsWith("H0"), `neueste Row ist H0, war ${history[5].slice(0, 3)}`);
    assert(
      history.every((c) => !c.startsWith("H6") && !c.startsWith("H7") && !c.startsWith("H8") && !c.startsWith("H9")),
      "die 4 aeltesten Rows (H6-H9) sind verworfen",
    );
    history.forEach((c, i) => {
      assert(c.length <= 4000, `Row ${i} ueber dem Row-Cap (${c.length})`);
    });
  } finally {
    stub.restore();
  }
});

// ---------------------------------------------------------------------------
// CWE-400-Fix (Security-Review 2026-08-11, Finding 3): der Handler leitete
// JEDEN Bearer-Wert — auch den absichtlich OEFFENTLICHEN Anon-Key — an
// /auth/v1/user weiter, und fehlgeschlagene Auth returnte VOR beiden
// Limitern. Ein anonymer Angreifer konnte so unbegrenzt Edge-+Auth-Arbeit
// erzeugen, ohne je einen Application-Bucket zu beruehren. Jetzt: Anon-Key
// lokal abgewiesen (Muster der Schwester-Functions), Auth-Fehlschlaege
// verbrauchen ein eigenes IP-Bucket (coach-chat:auth-fail, 30/h).
// ---------------------------------------------------------------------------

Deno.test("CWE-400-Fix: exakter Anon-Key -> 401 lokal, kein Auth-Roundtrip, kein DB-Call", async () => {
  const stub = installFetch();
  try {
    const req = new Request("https://edge.test.invalid/coach-chat", {
      method: "POST",
      headers: {
        // Exakt der Wert aus Deno.env.set("SUPABASE_ANON_KEY", ...) oben.
        "authorization": "Bearer test-anon-key",
        "content-type": "application/json",
      },
      body: JSON.stringify({ message: "hi" }),
    });
    const res = await handleRequest(req);
    assertEquals(res.status, 401, "Status");
    const body = await res.json() as JsonRecord;
    assertEquals(body.error, "Unauthorized", "error");
    // Der Kern des Fixes: der bekannte oeffentliche Token kostet weder einen
    // Auth-Roundtrip noch irgendeinen anderen Backend-Call.
    assertEquals(stub.callsTo("/auth/v1/user").length, 0, "kein /auth/v1/user-Lookup");
    assertEquals(stub.callsTo("consume_edge_rate_limit").length, 0, "kein Rate-Limit-Call");
    assertEquals(stub.calls.length, 0, "gar kein Backend-Call fuer den Anon-Key");
  } finally {
    stub.restore();
  }
});

Deno.test("CWE-400-Fix: wiederholte Auth-Fehlschlaege verbrauchen das Fail-Bucket bis 429", async () => {
  // Budget 2: die ersten beiden Fehlversuche antworten 401 (und zaehlen),
  // der dritte laeuft in den atomaren check+increment und bekommt 429.
  const stub = installFetch({ authStatus: 401, authFailBudget: 2 });
  try {
    const first = await handleRequest(makeRequest({ message: "hi" }));
    assertEquals(first.status, 401, "1. Fehlversuch: Status");
    const second = await handleRequest(makeRequest({ message: "hi" }));
    assertEquals(second.status, 401, "2. Fehlversuch: Status");
    const third = await handleRequest(makeRequest({ message: "hi" }));
    assertEquals(third.status, 429, "3. Fehlversuch: Status");
    const body = await third.json() as JsonRecord;
    assertEquals(body.error, "rate_limited", "error");
    assert(third.headers.get("Retry-After") !== null, "Retry-After fehlt");

    // Jeder Fehlschlag kostet genau einen Lookup und genau einen Consume im
    // Fail-Bucket — mit den konfigurierten konservativen Parametern.
    assertEquals(stub.callsTo("/auth/v1/user").length, 3, "Auth-Lookups");
    const failGates = stub.callsTo("consume_edge_rate_limit")
      .map((c) => JSON.parse(c.body) as JsonRecord)
      .filter((p) => p.p_scope === "coach-chat:auth-fail");
    assertEquals(failGates.length, 3, "Fail-Bucket-Consumes");
    assertEquals(failGates[0].p_limit, 30, "konservatives Limit (30/h)");
    assertEquals(failGates[0].p_window_seconds, 3600, "Stunden-Fenster");
    // Ohne cf-connecting-ip/x-forwarded-for greift der dokumentierte
    // geteilte Fallback — im Fail-Bucket landen nur Fehlversuche, also ok.
    assertEquals(failGates[0].p_subject, "uid:anon", "Fallback-Subject");

    // Auth-Fehlschlaege erreichen NIE die Application-Gates oder Provider.
    const otherGates = stub.callsTo("consume_edge_rate_limit")
      .map((c) => JSON.parse(c.body) as JsonRecord)
      .filter((p) => p.p_scope !== "coach-chat:auth-fail");
    assertEquals(otherGates.length, 0, "keine ip/user-Gates auf dem Fehlschlag-Pfad");
    assertEquals(stub.callsTo("claim_chat_quota").length, 0, "keine Quota");
    assertEquals(stub.openRouterBodies.length, 0, "kein Provider-Call");
  } finally {
    stub.restore();
  }
});

Deno.test("CWE-400-Fix: erfolgreiche Auth beruehrt das Fail-Bucket nicht", async () => {
  const stub = installFetch({
    classifierCategory: "fitness",
    answerContent: "Alles gut, weiter so.",
  });
  try {
    const res = await handleRequest(makeRequest({
      message: "Wie oft soll ich pro Woche trainieren?",
    }));
    assertEquals(res.status, 200, "Status");
    const scopes = stub.callsTo("consume_edge_rate_limit")
      .map((c) => (JSON.parse(c.body) as JsonRecord).p_scope);
    assert(!scopes.includes("coach-chat:auth-fail"), "Fail-Bucket auf dem Happy Path beruehrt");
    // Die regulaeren Gates laufen unveraendert (Reihenfolge: ip, dann user).
    assertEquals(scopes[0], "coach-chat:ip", "IP-Gate");
    assertEquals(scopes[1], "coach-chat:user", "User-Gate");
    assertEquals(scopes.length, 2, "genau zwei Gates auf dem Happy Path");
  } finally {
    stub.restore();
  }
});

// ---------------------------------------------------------------------------
// CWE-400-Fix (Security-Review 2026-08-11, Finding 6): beide OpenRouter-
// Fetches liefen ohne AbortSignal — ein haengendes Upstream hielt die
// Execution bis zum aeusseren Plattform-Limit (Concurrency-Verbrauch, und
// der geclaimte Slot wurde nie refundet, weil der Plattform-Kill die
// catch-Bloecke nie erreichte). Jetzt: AbortSignal.timeout um Fetch UND
// Body-Read; der Timeout laeuft ueber die BESTEHENDEN Infra-Fehler-Pfade
// (genau 1 Refund, sanitisierter 504 provider_timeout — Statuscode-Paar wie
// analyze-meal). Die Tests verkuerzen die Deadline ueber PROVIDER_TIMEOUTS_MS
// und stellen die Produktions-Defaults im finally wieder her.
// ---------------------------------------------------------------------------

Deno.test("Finding 6: Classifier-Timeout -> genau 1 Refund + sanitisierter 504", async () => {
  const stub = installFetch({ classifierHangs: true });
  const originalMs = PROVIDER_TIMEOUTS_MS.classify;
  PROVIDER_TIMEOUTS_MS.classify = 30;
  try {
    const res = await handleRequest(makeRequest({
      message: "Wie viel Protein brauche ich beim Cutting?",
    }));
    assertEquals(res.status, 504, "Status");
    const body = await res.json() as JsonRecord;
    assertEquals(body.error, "provider_timeout", "error");
    assertEquals(body.session_id, SESSION_ID, "session_id");
    assertEquals(stub.callsTo("claim_chat_quota").length, 1, "Slot wurde geclaimt");
    assertEquals(stub.callsTo("refund_chat_quota").length, 1, "genau EIN Refund");
    assertEquals(stub.answerBodies().length, 0, "kein Answer-Call");
    // Wie der Infra-Fehler (E2-Muster): auf dem Timeout-Pfad wird nichts
    // persistiert und keine erfundene Refusal-Zeile erzeugt.
    assertEquals(
      stub.callsTo("/rest/v1/chat_messages").filter((c) => c.method === "POST").length,
      0,
      "keine Message-Persistenz auf dem Timeout-Pfad",
    );
  } finally {
    PROVIDER_TIMEOUTS_MS.classify = originalMs;
    stub.restore();
  }
});

Deno.test("Finding 6: Answer-Timeout -> genau 1 Refund + sanitisierter 504", async () => {
  const stub = installFetch({ classifierCategory: "fitness", answerHangs: true });
  const originalMs = PROVIDER_TIMEOUTS_MS.answer;
  PROVIDER_TIMEOUTS_MS.answer = 30;
  try {
    const res = await handleRequest(makeRequest({
      message: "Wie oft soll ich pro Woche trainieren?",
    }));
    assertEquals(res.status, 504, "Status");
    const body = await res.json() as JsonRecord;
    assertEquals(body.error, "provider_timeout", "error");
    assertEquals(body.session_id, SESSION_ID, "session_id");
    assertEquals(stub.callsTo("claim_chat_quota").length, 1, "Slot wurde geclaimt");
    assertEquals(stub.callsTo("refund_chat_quota").length, 1, "genau EIN Refund");
    // Die (echte) User-Message bleibt gespeichert, aber KEINE erfundene
    // Assistant-Zeile (E2-Muster des Answer-Fehlerpfads).
    assertEquals(
      stub.callsTo("/rest/v1/chat_messages").filter((c) => c.method === "POST").length,
      1,
      "nur die User-Message persistiert",
    );
    assertEquals(stub.callsTo("touch_chat_session").length, 1, "Session wird getoucht");
  } finally {
    PROVIDER_TIMEOUTS_MS.answer = originalMs;
    stub.restore();
  }
});

Deno.test("Finding 6: Timeout-Antworten tragen kein Provider-Detail und keinen Roh-Fehlertext", async () => {
  // Beide Timeout-Pfade: der Response-Body besteht ausschliesslich aus den
  // sanitisierten Feldern error + session_id — keine DOMException-Message
  // ("Signal timed out"), kein Provider-Host, kein interner Fehlertext.
  const cases: { name: string; options: StubOptions }[] = [
    { name: "Classifier", options: { classifierHangs: true } },
    { name: "Answer", options: { classifierCategory: "fitness", answerHangs: true } },
  ];
  for (const { name, options } of cases) {
    const stub = installFetch(options);
    const originalClassifyMs = PROVIDER_TIMEOUTS_MS.classify;
    const originalAnswerMs = PROVIDER_TIMEOUTS_MS.answer;
    PROVIDER_TIMEOUTS_MS.classify = 30;
    PROVIDER_TIMEOUTS_MS.answer = 30;
    try {
      const res = await handleRequest(makeRequest({
        message: "Wie viel Protein nach dem Training?",
      }));
      assertEquals(res.status, 504, `${name}: Status`);
      const raw = await res.text();
      const body = JSON.parse(raw) as JsonRecord;
      assertEquals(
        Object.keys(body).sort().join(","),
        "error,session_id",
        `${name}: nur sanitisierte Felder im Body`,
      );
      for (const marker of ["TimeoutError", "timed out", "openrouter", "fehlgeschlagen", "DOMException", "stack"]) {
        assert(
          !raw.toLowerCase().includes(marker.toLowerCase()),
          `${name}: Response-Body leakt "${marker}": ${raw}`,
        );
      }
    } finally {
      PROVIDER_TIMEOUTS_MS.classify = originalClassifyMs;
      PROVIDER_TIMEOUTS_MS.answer = originalAnswerMs;
      stub.restore();
    }
  }
});
