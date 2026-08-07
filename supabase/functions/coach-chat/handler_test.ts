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

import { handleRequest } from "./handler.ts";

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
  /** claim_chat_quota beantworten statt zu werfen. Default: werfen. */
  allowQuota?: boolean;
  /** Inhalt der Antwort des teuren Answer-Calls. */
  answerContent?: string;
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

function installFetch(options: StubOptions = {}): FetchStub {
  const calls: RecordedCall[] = [];
  const openRouterBodies: JsonRecord[] = [];
  const original = globalThis.fetch;

  function route(url: string, method: string, body: string): Response {
    if (url.includes("/auth/v1/user")) {
      return jsonRes({ id: USER_ID });
    }
    if (url.includes("/rest/v1/rpc/consume_edge_rate_limit")) {
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
      if (!options.allowQuota) {
        // Layer 1 und Layer 2 refusen VOR dem Quota-Claim. Wird die RPC auf
        // einem Refusal-Pfad doch erreicht, verliert der Nutzer einen
        // Tages-Slot fuer eine Frage, die nie beantwortet wurde.
        throw new Error(
          "claim_chat_quota wurde auf einem Refusal-Pfad aufgerufen - die Quota darf dort NICHT angefasst werden",
        );
      }
      return jsonRes([{ used: 1, remaining: 4 }]);
    }
    if (url.includes("openrouter.ai")) {
      const parsed = JSON.parse(body) as JsonRecord;
      openRouterBodies.push(parsed);
      // Klassifizierer und Answer-Call unterscheiden sich eindeutig im
      // Token-Budget (50 vs. 600).
      if (parsed.max_tokens === 50) {
        return jsonRes({
          choices: [{
            message: {
              content: JSON.stringify({
                category: options.classifierCategory ?? "fitness",
                confidence: "high",
              }),
            },
          }],
        });
      }
      return jsonRes({
        choices: [{
          message: { content: options.answerContent ?? "Klar, machen wir." },
        }],
      });
    }
    if (url.includes("/rest/v1/chat_messages")) {
      // POST = storeMessage, GET = loadHistory.
      if (method === "POST") return new Response(null, { status: 201 });
      return jsonRes([]);
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
    return Promise.resolve(route(url, method, body));
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
    assert(
      !("remaining" in body),
      "'remaining' darf fehlen, damit der Client seinen Zaehler nicht veraendert",
    );

    // Quota-frei: die RPC darf gar nicht erst erreicht werden.
    assertEquals(stub.callsTo("claim_chat_quota").length, 0, "claim_chat_quota-Calls");
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

Deno.test("Bild + eating_disorder -> ED-Antwort, quota-frei", async () => {
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
    assertEquals(stub.callsTo("claim_chat_quota").length, 0, "claim_chat_quota-Calls");
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
      assertEquals(stub.callsTo("claim_chat_quota").length, 0, `${category}: kein Quota-Claim`);
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
    allowQuota: true,
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
    allowQuota: true,
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

Deno.test("Textpfad unveraendert: off_topic wird weiterhin quota-frei refused", async () => {
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
    assert(!("remaining" in body), "kein remaining auf dem Refusal-Pfad");
    assertEquals(stub.callsTo("claim_chat_quota").length, 0, "claim_chat_quota-Calls");
    assertEquals(stub.answerBodies().length, 0, "Answer-Calls");
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
    allowQuota: true,
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

Deno.test("Layer 1 bleibt vor Layer 2: eindeutiger Text blockt ohne LLM-Call", async () => {
  const stub = installFetch({ classifierCategory: "fitness" });
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
