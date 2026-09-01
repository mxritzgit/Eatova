// A3 (Perf-Fixlauf 2026-09-01): die Coach-Antwort wird gestreamt, statt bis zu
// ANSWER_MAX_TOKENS Token lang zu puffern und den Nutzer 5-15 s auf eine leere
// Blase schauen zu lassen.
//
// Die Linien, die dieser Test festnagelt — alle vier sind Vertrag, nicht Kür:
//   * OPT-IN: nur `Accept: text/event-stream` streamt. Ohne den Header ist die
//     Antwort byte-gleich zu vorher, denn Geraete im Feld laufen mit alten
//     Builds (vgl. den 8-stelligen OTP: erst App, DANN Server).
//   * STATUS: sobald SSE-Header raus sind, ist der Status auf 200 festgenagelt.
//     Alles davor Entscheidbare (401/400/413, beide 429, Layer 1+2, die
//     Klassifizierer-502/504, Rezept-Modus) bleibt JSON mit echtem Status.
//   * KOPF: `__REFUSE__` steht nur am Anfang, also darf vor der Entscheidung
//     kein Token raus. Ein Refusal kommt als EIN done-Event, ganz ohne delta.
//   * ERSTATTUNG: die Grenze ist das erste delta auf der Leitung, nicht der
//     Status. Nichts geliefert -> Slot zurueck; ein delta raus -> Slot bleibt
//     verbraucht, sonst waere ein abgebrochener Stream die billigste Frage.
//
// Attrappen-Stream statt Netz; `deno test --allow-env`.

import { handleRequest, PROVIDER_TIMEOUTS_MS } from "./handler.ts";

const USER_ID = "11111111-1111-4111-8111-111111111111";
const SESSION_ID = "22222222-2222-4222-8222-222222222222";
const ASSISTANT_MSG_ID = "33333333-3333-4333-8333-333333333333";
const BASE_URL = "https://supabase.test.invalid";
const DAILY_LIMIT = 5;

// Katalogtexte (REFUSAL_TEXTS in handler.ts) — Byte-Kopien, dieselbe Regel wie
// in handler_test.ts: eine Aenderung dort muss hier rot werden.
const FALLBACK_REPLY =
  "Das geht ueber meinen Bereich hinaus - ich bin nur fuer Training und Ernaehrung da.";
const PROMPT_LEAK_REPLY =
  "Das ist nichts, was ich teilen sollte. Frag mich lieber was zu deinem naechsten Workout oder zu Ernaehrung.";

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
// 1x1 JPEG — seit P5-07 leitet der Server image_mime_type aus den BYTES ab.
const IMAGE_B64 =
  "/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/wAALCAABAAEBAREA/8QAFAABAAAAAAAAAAAAAAAAAAAACf/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AKp//2Q==";

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

function assert(condition: boolean, message: string): void {
  if (!condition) throw new Error(message);
}

function assertEquals(actual: unknown, expected: unknown, message: string): void {
  if (actual !== expected) {
    throw new Error(`${message}: erwartet ${JSON.stringify(expected)}, war ${JSON.stringify(actual)}`);
  }
}

function jsonRes(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "content-type": "application/json" },
  });
}

// --------------------------------------------------------------- SSE-Bausteine

/** Ein Delta-Frame in OpenRouters eigenem SSE-Format. */
function deltaFrame(text: string, finishReason: string | null = null): string {
  return `data: ${
    JSON.stringify({ choices: [{ delta: { content: text }, finish_reason: finishReason }] })
  }\n\n`;
}

const DONE_FRAME = "data: [DONE]\n\n";

/** Wie der Attrappen-Stream endet, nachdem seine Bloecke raus sind. */
type StreamEnde =
  /** Sauber geschlossen. */
  | "close"
  /** Anbieter-Ausfall mitten in der Antwort. */
  | "fail"
  /** Stiller Upstream: nur die Frist beendet das noch. */
  | "stall";

/**
 * Antwort-Body des Anbieters. Die Bloecke sind BYTE-Bloecke, keine Frames —
 * genau so laesst sich nachstellen, was ein echter Stream tut: mehrere Frames
 * in einem Read, ein Frame ueber zwei Reads verteilt, Keep-Alive-Kommentare.
 */
function providerBody(
  bloecke: string[],
  ende: StreamEnde,
  signal: AbortSignal | null | undefined,
): ReadableStream<Uint8Array> {
  const enc = new TextEncoder();
  let i = 0;
  return new ReadableStream<Uint8Array>({
    pull(controller) {
      if (i < bloecke.length) {
        controller.enqueue(enc.encode(bloecke[i++]));
        return;
      }
      if (ende === "close") {
        controller.close();
        return;
      }
      if (ende === "fail") {
        controller.error(new Error("upstream stream broke"));
        return;
      }
      // Ohne Signal laut scheitern: das ist die Regressionswache gegen eine
      // entfernte Frist auf dem gestreamten Body.
      return new Promise<void>((_, reject) => {
        if (!signal) {
          reject(new Error("gestreamter Provider-Call ohne AbortSignal — die Frist fehlt"));
          return;
        }
        if (signal.aborted) {
          reject(signal.reason);
          return;
        }
        signal.addEventListener("abort", () => reject(signal.reason), { once: true });
      });
    },
  });
}

interface SseEvent {
  event: string;
  data: JsonRecord;
}

function parseSse(raw: string): SseEvent[] {
  const events: SseEvent[] = [];
  for (const block of raw.split("\n\n")) {
    const lines = block.split("\n").filter((line) => line.length > 0);
    const eventLine = lines.find((line) => line.startsWith("event: "));
    const dataLine = lines.find((line) => line.startsWith("data: "));
    if (!eventLine || !dataLine) continue;
    events.push({
      event: eventLine.slice("event: ".length),
      data: JSON.parse(dataLine.slice("data: ".length)) as JsonRecord,
    });
  }
  return events;
}

function deltaTexte(events: SseEvent[]): string[] {
  return events.filter((e) => e.event === "delta").map((e) => String(e.data.t));
}

// ------------------------------------------------------------------ Attrappe

interface StubOptions {
  quota?: "ok" | "exhausted" | "forbidden";
  classifierCategory?: string;
  /** Byte-Bloecke des gestreamten Antwort-Bodys. */
  answerChunks?: string[];
  /** Bequemer: je ein Delta-Frame pro Text, mit [DONE] am Ende. */
  answerDeltas?: string[];
  /** finish_reason im letzten Delta-Frame. */
  answerFinishReason?: string;
  /** Wie der Stream nach seinen Bloecken endet (Standard: sauber). */
  answerEnde?: StreamEnde;
  /** HTTP-Status des Antwort-Calls (Ausfall vor jedem Byte). */
  answerStatus?: number;
  /** Inhalt des GEPUFFERTEN Antwort-Calls (Pfad ohne Opt-in). */
  answerContent?: string;
  /** Inhalt des Rezept-Entwurfs (max_tokens 900). */
  draftContent?: string;
}

interface FetchStub {
  calls: RecordedCall[];
  callsTo(fragment: string): RecordedCall[];
  answerBodies(): JsonRecord[];
  /** Gespeicherte Assistant-Zeilen, in Aufrufreihenfolge. */
  assistantRows(): JsonRecord[];
  /** Ledger: der Anspruch zaehlt hoch, die Erstattung wieder runter. */
  quotaUsed(): number;
  restore(): void;
}

function installFetch(options: StubOptions = {}): FetchStub {
  const calls: RecordedCall[] = [];
  const original = globalThis.fetch;
  let quotaUsed = 0;

  function streamedAnswer(signal: AbortSignal | null | undefined): Response {
    const ende = options.answerEnde ?? "close";
    const bloecke = options.answerChunks ??
      [
        ...(options.answerDeltas ?? ["Klar, machen wir das."]).map((text, index, all) =>
          deltaFrame(text, index === all.length - 1 ? options.answerFinishReason ?? "stop" : null)
        ),
        // [DONE] nur im sauberen Fall: ein Ausfall/Haenger passiert per
        // Definition, BEVOR der Anbieter sein Ende schickt.
        ...(ende === "close" ? [DONE_FRAME] : []),
      ];
    return new Response(providerBody(bloecke, ende, signal), {
      status: 200,
      headers: { "content-type": "text/event-stream" },
    });
  }

  function route(
    url: string,
    method: string,
    body: string,
    signal: AbortSignal | null | undefined,
  ): Response {
    if (url.includes("/auth/v1/user")) return jsonRes({ id: USER_ID });
    // Gebuendelter Limiter (P6-02) VOR der Einzel-URL: deren Fragment ist ein
    // Praefix von dieser.
    if (url.includes("/rest/v1/rpc/consume_edge_rate_limits")) {
      const gates = (JSON.parse(body) as JsonRecord).p_gates as JsonRecord[];
      return jsonRes(gates.map((gate) => ({
        allowed: true,
        limit: Number(gate.limit),
        remaining: Number(gate.limit) - 1,
        resetAt: new Date(Date.now() + Number(gate.window_seconds) * 1000).toISOString(),
        windowSeconds: Number(gate.window_seconds),
      })));
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
    if (url.includes("/rest/v1/rpc/prune_edge_rate_limits")) return new Response(null, { status: 204 });
    if (url.includes("/rest/v1/rpc/ensure_default_chat_session")) return jsonRes(SESSION_ID);
    if (url.includes("/rest/v1/rpc/touch_chat_session")) return new Response(null, { status: 204 });
    if (url.includes("/rest/v1/rpc/claim_chat_quota")) {
      const mode = options.quota ?? "ok";
      if (mode === "forbidden") {
        throw new Error("claim_chat_quota auf einem Pfad, der die Quota nicht anfassen darf");
      }
      if (mode === "exhausted") return jsonRes({ message: "EX_QUOTA_EXCEEDED" }, 400);
      quotaUsed++;
      return jsonRes([{ used: quotaUsed, remaining: DAILY_LIMIT - quotaUsed }]);
    }
    if (url.includes("/rest/v1/rpc/refund_chat_quota")) {
      quotaUsed = Math.max(0, quotaUsed - 1);
      return new Response(null, { status: 204 });
    }
    if (url.includes("openrouter.ai/api/v1/images")) {
      return jsonRes({ data: [{ b64_json: IMAGE_B64, media_type: "image/jpeg" }] });
    }
    if (url.includes("openrouter.ai")) {
      const parsed = JSON.parse(body) as JsonRecord;
      // Die drei Chat-Calls trennen sich am Token-Budget (50/800/900).
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
      if (parsed.max_tokens === 900) {
        return jsonRes({ choices: [{ message: { content: options.draftContent ?? RECIPE_JSON } }] });
      }
      if (options.answerStatus !== undefined) {
        return new Response("upstream unavailable", { status: options.answerStatus });
      }
      if (parsed.stream === true) return streamedAnswer(signal);
      return jsonRes({
        choices: [{
          message: { content: options.answerContent ?? "Klar, machen wir das." },
          finish_reason: options.answerFinishReason ?? "stop",
        }],
      });
    }
    if (url.includes("/rest/v1/chat_messages")) {
      if (method === "POST") {
        if (url.includes("select=id")) return jsonRes([{ id: ASSISTANT_MSG_ID }], 201);
        return new Response(null, { status: 201 });
      }
      return jsonRes([]);
    }
    if (url.includes("/rest/v1/chat_sessions")) {
      if (method === "PATCH") return new Response(null, { status: 204 });
      return jsonRes([]);
    }
    throw new Error(`Unerwarteter fetch im Test: ${method} ${url}`);
  }

  globalThis.fetch = ((input: string | URL | Request, init?: RequestInit): Promise<Response> => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.toString() : input.url;
    const method = (init?.method ?? "GET").toUpperCase();
    const body = typeof init?.body === "string" ? init.body : "";
    calls.push({ url, method, body });
    try {
      return Promise.resolve(route(url, method, body, init?.signal));
    } catch (e) {
      return Promise.reject(e);
    }
  }) as typeof globalThis.fetch;

  return {
    calls,
    callsTo: (fragment: string) => calls.filter((call) => call.url.includes(fragment)),
    answerBodies: () =>
      calls
        .filter((call) => call.url.includes("openrouter.ai/api/v1/chat/completions"))
        .map((call) => JSON.parse(call.body) as JsonRecord)
        .filter((parsed) => parsed.max_tokens === 800),
    assistantRows: () =>
      calls
        .filter((call) => call.url.includes("/rest/v1/chat_messages") && call.method === "POST")
        .map((call) => JSON.parse(call.body) as JsonRecord)
        .filter((row) => row.role === "assistant"),
    quotaUsed: () => quotaUsed,
    restore: () => {
      globalThis.fetch = original;
    },
  };
}

function makeRequest(payload: JsonRecord, stream = false): Request {
  return new Request("https://edge.test.invalid/coach-chat", {
    method: "POST",
    headers: {
      "authorization": "Bearer test-user-jwt",
      "content-type": "application/json",
      ...(stream ? { "accept": "text/event-stream" } : {}),
    },
    body: JSON.stringify(payload),
  });
}

const FRAGE = "Wie viel Protein nach dem Training?";

/** Wartet, bis die Bedingung stimmt — fuer die Arbeit, die NACH dem Abbruch
 *  des Clients noch im Pump laeuft (Persistenz). */
async function warteBis(pred: () => boolean, ms = 1_500): Promise<void> {
  const ende = Date.now() + ms;
  while (!pred() && Date.now() < ende) {
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
}

/** Kuerzt die Antwort-Frist fuer einen Fall und stellt sie danach her. */
async function mitKurzerFrist(ms: number, run: () => Promise<void>): Promise<void> {
  const original = PROVIDER_TIMEOUTS_MS.answer;
  PROVIDER_TIMEOUTS_MS.answer = ms;
  try {
    await run();
  } finally {
    PROVIDER_TIMEOUTS_MS.answer = original;
  }
}

// Lang genug, dass der Kopfpuffer sicher freigegeben wird (der Leck-Riegel
// haelt die letzten 64 Zeichen zurueck, solange der Stream offen ist).
const LANGER_TEXT_A =
  "Nach dem Training sind 25 bis 30 g Protein ein guter Richtwert, damit die Muskulatur ";
const LANGER_TEXT_B =
  "gut versorgt ist und du deine Tagesbilanz nicht sprengst. Quark oder Huehnchen passen.";

// ---------------------------------------------------------------------------
// 1) Opt-in
// ---------------------------------------------------------------------------

Deno.test("A3: ohne Accept-Header bleibt alles gepuffertes JSON", async () => {
  const stub = installFetch();
  try {
    const res = await handleRequest(makeRequest({ message: FRAGE }));
    assertEquals(res.status, 200, "Status");
    assertEquals(
      res.headers.get("content-type"),
      "application/json; charset=utf-8",
      "Content-Type",
    );
    const body = await res.json() as JsonRecord;
    assertEquals(body.reply, "Klar, machen wir das.", "Antworttext");
    assertEquals(body.refusal, false, "refusal");
    assertEquals(body.session_id, SESSION_ID, "session_id");
    assertEquals(body.remaining, 4, "remaining");
    assertEquals(body.daily_limit, DAILY_LIMIT, "daily_limit");
    // Der entscheidende Beweis fuer alte Builds im Feld: der Anbieter wird
    // nicht einmal um einen Stream gebeten.
    assertEquals(stub.answerBodies().length, 1, "genau ein Answer-Call");
    assertEquals(stub.answerBodies()[0].stream, undefined, "kein stream-Flag ohne Opt-in");
  } finally {
    stub.restore();
  }
});

Deno.test("A3: mit Accept: text/event-stream kommt ein Stream", async () => {
  const stub = installFetch({ answerDeltas: [LANGER_TEXT_A, LANGER_TEXT_B] });
  try {
    const res = await handleRequest(makeRequest({ message: FRAGE }, true));
    assertEquals(res.status, 200, "Status");
    assertEquals(
      res.headers.get("content-type"),
      "text/event-stream; charset=utf-8",
      "Content-Type",
    );
    assert(
      (res.headers.get("cache-control") ?? "").includes("no-cache"),
      `Cache-Control: ${res.headers.get("cache-control")}`,
    );
    assertEquals(stub.answerBodies()[0].stream, true, "der Anbieter wird um einen Stream gebeten");
    const events = parseSse(await res.text());
    assert(events.length >= 3, `zu wenige Events: ${JSON.stringify(events)}`);
  } finally {
    stub.restore();
  }
});

Deno.test("A3: gestreamter Prompt ist derselbe wie der gepufferte, nur mit stream", async () => {
  // Sonst antwortet das Modell auf zwei verschiedene Fragen, je nachdem welchen
  // Build der Nutzer installiert hat.
  const gepuffert = installFetch();
  let ohneStream: JsonRecord;
  try {
    await handleRequest(makeRequest({ message: FRAGE, user_context: "Ziel: 2000 kcal" }));
    ohneStream = gepuffert.answerBodies()[0];
  } finally {
    gepuffert.restore();
  }
  const gestreamt = installFetch({ answerDeltas: [LANGER_TEXT_A] });
  try {
    const res = await handleRequest(
      makeRequest({ message: FRAGE, user_context: "Ziel: 2000 kcal" }, true),
    );
    await res.text();
    const mitStream = { ...gestreamt.answerBodies()[0] };
    assertEquals(mitStream.stream, true, "stream-Flag");
    delete mitStream.stream;
    assertEquals(
      JSON.stringify(mitStream),
      JSON.stringify(ohneStream),
      "der Prompt unterscheidet sich ausser im stream-Flag",
    );
  } finally {
    gestreamt.restore();
  }
});

// ---------------------------------------------------------------------------
// 2) Reihenfolge und Nutzlast der Events
// ---------------------------------------------------------------------------

Deno.test("A3: Reihenfolge ist meta, delta..., done — und done traegt die gepufferte Nutzlast", async () => {
  const stub = installFetch({ answerDeltas: [LANGER_TEXT_A, LANGER_TEXT_B] });
  try {
    const res = await handleRequest(makeRequest({ message: FRAGE }, true));
    const events = parseSse(await res.text());
    assertEquals(events[0].event, "meta", "erstes Event");
    assertEquals(events[events.length - 1].event, "done", "letztes Event");
    assert(
      events.slice(1, -1).every((e) => e.event === "delta"),
      `dazwischen nur deltas: ${events.map((e) => e.event).join(",")}`,
    );

    const meta = events[0].data;
    assertEquals(meta.session_id, SESSION_ID, "meta.session_id");
    assertEquals(meta.remaining, 4, "meta.remaining");
    assertEquals(meta.daily_limit, DAILY_LIMIT, "meta.daily_limit");

    const done = events[events.length - 1].data;
    const volltext = LANGER_TEXT_A + LANGER_TEXT_B;
    assertEquals(done.reply, volltext, "done.reply");
    assertEquals(done.refusal, false, "done.refusal");
    assertEquals(done.refusal_reason, null, "done.refusal_reason");
    assertEquals(done.remaining, 4, "done.remaining");
    assertEquals(done.daily_limit, DAILY_LIMIT, "done.daily_limit");
    assertEquals(done.session_id, SESSION_ID, "done.session_id");
    // Die deltas ergeben zusammen genau den Antworttext.
    assertEquals(deltaTexte(events).join(""), volltext, "Summe der deltas");
  } finally {
    stub.restore();
  }
});

Deno.test("A3: done traegt exakt dieselbe Nutzlast wie der gepufferte Body", async () => {
  // Eine Quelle der Wahrheit fuer die Drahtform: der Client parst dieselbe
  // Struktur weiter, und der Vertrag kann nicht auseinanderlaufen.
  const text = LANGER_TEXT_A + LANGER_TEXT_B;
  const gepuffert = installFetch({ answerContent: text });
  let bufferedBody: JsonRecord;
  try {
    bufferedBody = await (await handleRequest(makeRequest({ message: FRAGE }))).json() as JsonRecord;
  } finally {
    gepuffert.restore();
  }
  const gestreamt = installFetch({ answerDeltas: [LANGER_TEXT_A, LANGER_TEXT_B] });
  try {
    const res = await handleRequest(makeRequest({ message: FRAGE }, true));
    const events = parseSse(await res.text());
    const done = events[events.length - 1].data;
    assertEquals(
      JSON.stringify(done, Object.keys(done).sort()),
      JSON.stringify(bufferedBody, Object.keys(bufferedBody).sort()),
      "done-Nutzlast weicht vom gepufferten Body ab",
    );
  } finally {
    gestreamt.restore();
  }
});

Deno.test("A3: eine lange Antwort kommt in MEHREREN deltas, nicht in einem Stueck", async () => {
  // Der eigentliche Zweck des Umbaus: der Text laeuft ein, waehrend das Modell
  // noch schreibt.
  const stub = installFetch({
    answerDeltas: [LANGER_TEXT_A, LANGER_TEXT_B, LANGER_TEXT_A, LANGER_TEXT_B],
  });
  try {
    const res = await handleRequest(makeRequest({ message: FRAGE }, true));
    const events = parseSse(await res.text());
    const deltas = deltaTexte(events);
    assert(deltas.length >= 3, `zu wenige deltas: ${deltas.length}`);
    assertEquals(
      deltas.join(""),
      LANGER_TEXT_A + LANGER_TEXT_B + LANGER_TEXT_A + LANGER_TEXT_B,
      "Summe der deltas",
    );
  } finally {
    stub.restore();
  }
});

Deno.test("A3: die Assistant-Zeile wird gespeichert wie im gepufferten Pfad", async () => {
  const stub = installFetch({ answerDeltas: [LANGER_TEXT_A] });
  try {
    const res = await handleRequest(makeRequest({ message: FRAGE }, true));
    await res.text();
    const rows = stub.assistantRows();
    assertEquals(rows.length, 1, "genau eine Assistant-Zeile");
    // Getrimmt wie im gepufferten Pfad — finalizeAnswer entscheidet fuer beide.
    assertEquals(rows[0].content, LANGER_TEXT_A.trim(), "Inhalt");
    assertEquals(rows[0].refusal, false, "refusal");
    assertEquals(rows[0].refusal_reason, null, "refusal_reason");
    assertEquals(stub.callsTo("touch_chat_session").length, 1, "touchSession laeuft wie bisher");
  } finally {
    stub.restore();
  }
});

Deno.test("A3: finish_reason=length markiert die Antwort auch im Stream", async () => {
  const stub = installFetch({
    answerDeltas: [LANGER_TEXT_A],
    answerFinishReason: "length",
  });
  try {
    const res = await handleRequest(makeRequest({ message: FRAGE }, true));
    const events = parseSse(await res.text());
    const done = events[events.length - 1].data;
    assert(String(done.reply).endsWith("…"), `ohne Kennzeichnung: ${String(done.reply)}`);
  } finally {
    stub.restore();
  }
});

// ---------------------------------------------------------------------------
// 3) Die __REFUSE__-Kopfpruefung
// ---------------------------------------------------------------------------

Deno.test("A3: ein __REFUSE__-Kopf erzeugt NULL deltas", async () => {
  const stub = installFetch({
    answerDeltas: ["__REFUSE__ Das geht ueber meinen Bereich hinaus - frag mich was zu Training."],
  });
  try {
    const res = await handleRequest(makeRequest({ message: FRAGE }, true));
    assertEquals(res.status, 200, "Status");
    const events = parseSse(await res.text());
    assertEquals(deltaTexte(events).length, 0, "kein einziges delta");
    assertEquals(events.map((e) => e.event).join(","), "meta,done", "nur meta und done");
    const done = events[1].data;
    assertEquals(done.refusal, true, "done.refusal");
    assertEquals(done.refusal_reason, "model_refusal", "done.refusal_reason");
    assert(!String(done.reply).startsWith("__REFUSE__"), "Marker ist gestrippt");
    assertEquals(stub.quotaUsed(), 1, "der Slot bleibt verbraucht");
  } finally {
    stub.restore();
  }
});

Deno.test("A3: der Marker darf ueber mehrere Bloecke verteilt ankommen", async () => {
  // Das ist der Grund fuer den Kopfpuffer: ein Token-Stream zerlegt den Marker.
  const stub = installFetch({
    answerChunks: [
      deltaFrame("__RE"),
      deltaFrame("FUSE"),
      deltaFrame("__ Da gehe ich nicht mit.", "stop"),
      DONE_FRAME,
    ],
  });
  try {
    const res = await handleRequest(makeRequest({ message: FRAGE }, true));
    const events = parseSse(await res.text());
    assertEquals(deltaTexte(events).length, 0, "kein delta trotz zerlegtem Marker");
    assertEquals(events[1].data.refusal, true, "refusal");
    assertEquals(events[1].data.reply, "Da gehe ich nicht mit.", "Text ohne Marker");
  } finally {
    stub.restore();
  }
});

Deno.test("A3: fuehrender Leerraum vor dem Marker aendert nichts", async () => {
  const stub = installFetch({
    answerChunks: [deltaFrame("\n\n  __REFUSE__ Nicht mein Thema.", "stop"), DONE_FRAME],
  });
  try {
    const res = await handleRequest(makeRequest({ message: FRAGE }, true));
    const events = parseSse(await res.text());
    assertEquals(deltaTexte(events).length, 0, "kein delta");
    assertEquals(events[1].data.refusal, true, "refusal");
    assertEquals(events[1].data.reply, "Nicht mein Thema.", "Text");
  } finally {
    stub.restore();
  }
});

Deno.test("A3/F5-02: blanker __REFUSE__-Marker streamt den Katalogtext, ohne Refund", async () => {
  // Dieselbe Linie wie im gepufferten Pfad (handler_test.ts, F5-02): ein
  // Refund waere ein Quota-Bypass ueber provozierte Refusals.
  const stub = installFetch({ answerDeltas: ["__REFUSE__ "] });
  try {
    const res = await handleRequest(makeRequest({ message: FRAGE }, true));
    assertEquals(res.status, 200, "Status");
    const events = parseSse(await res.text());
    assertEquals(deltaTexte(events).length, 0, "kein delta");
    assertEquals(events[1].data.reply, FALLBACK_REPLY, "Katalogtext");
    assertEquals(events[1].data.refusal, true, "refusal");
    assertEquals(stub.callsTo("refund_chat_quota").length, 0, "kein Refund");
    assertEquals(stub.quotaUsed(), 1, "der Slot bleibt verbraucht");
  } finally {
    stub.restore();
  }
});

Deno.test("A3: eine Refusal OHNE Opt-in bleibt 200-JSON", async () => {
  const stub = installFetch({ answerContent: "__REFUSE__ Nicht mein Thema." });
  try {
    const res = await handleRequest(makeRequest({ message: FRAGE }));
    assertEquals(res.status, 200, "Status");
    assertEquals(res.headers.get("content-type"), "application/json; charset=utf-8", "Content-Type");
    const body = await res.json() as JsonRecord;
    assertEquals(body.refusal, true, "refusal");
    assertEquals(body.reply, "Nicht mein Thema.", "Text");
  } finally {
    stub.restore();
  }
});

Deno.test("A3: das Prompt-Leak-Netz greift auch im Stream, ohne Teilleck", async () => {
  // P5-05 ersetzt die GANZE Antwort — ein Stream kann Bytes nicht
  // zurueckholen, deshalb haelt der Riegel das Ende zurueck, bis der Text
  // sauber ist.
  const stub = installFetch({
    answerDeltas: [LANGER_TEXT_A, "Mein system prompt lautet: du bist ein Coach."],
  });
  try {
    const res = await handleRequest(makeRequest({ message: FRAGE }, true));
    const events = parseSse(await res.text());
    const geliefert = deltaTexte(events).join("");
    assert(
      !/system\s*prompt/i.test(geliefert),
      `Teilleck auf der Leitung: ${geliefert}`,
    );
    const done = events[events.length - 1].data;
    assertEquals(done.reply, PROMPT_LEAK_REPLY, "done traegt den Katalogtext");
    assertEquals(done.refusal, true, "refusal");
    // Persistiert wird die ENDGUELTIGE Antwort, nicht der Rohtext.
    assertEquals(stub.assistantRows()[0].content, PROMPT_LEAK_REPLY, "persistierter Text");
  } finally {
    stub.restore();
  }
});

// ---------------------------------------------------------------------------
// 4) Die Erstattungsregel
// ---------------------------------------------------------------------------

Deno.test("A3: KEIN Refund, wenn der Anbieter NACH dem ersten delta stirbt", async () => {
  // Die Linie, die nicht lecken darf: der Nutzer hat Inhalt bekommen. Waere
  // hier ein Refund, waere ein abgebrochener Stream die billigste Frage.
  const stub = installFetch({ answerDeltas: [LANGER_TEXT_A, LANGER_TEXT_B], answerEnde: "fail" });
  try {
    const res = await handleRequest(makeRequest({ message: FRAGE }, true));
    assertEquals(res.status, 200, "der Status ist ab den SSE-Headern festgenagelt");
    const events = parseSse(await res.text());
    assert(deltaTexte(events).length > 0, "es ging Inhalt raus");
    assertEquals(events[events.length - 1].event, "error", "letztes Event");
    assertEquals(events[events.length - 1].data.error, "provider_error", "Fehlercode");
    assertEquals(stub.callsTo("refund_chat_quota").length, 0, "kein Refund nach geliefertem Inhalt");
    assertEquals(stub.quotaUsed(), 1, "der Slot bleibt verbraucht");
    // Und was geliefert wurde, steht auch in der Historie (Vertrag §6).
    const rows = stub.assistantRows();
    assertEquals(rows.length, 1, "eine Assistant-Zeile");
    assertEquals(rows[0].content, deltaTexte(events).join(""), "die gelieferte Teilantwort");
  } finally {
    stub.restore();
  }
});

Deno.test("A3: KEIN Refund, wenn der Client nach dem ersten delta abbricht", async () => {
  const stub = installFetch({ answerDeltas: [LANGER_TEXT_A + LANGER_TEXT_B], answerEnde: "stall" });
  try {
    const res = await handleRequest(makeRequest({ message: FRAGE }, true));
    const reader = res.body!.getReader();
    const decoder = new TextDecoder();
    let gelesen = "";
    while (!gelesen.includes("event: delta")) {
      const { value, done } = await reader.read();
      if (done) break;
      gelesen += decoder.decode(value, { stream: true });
    }
    assert(gelesen.includes("event: delta"), "es ging ein delta raus");
    await reader.cancel();
    await warteBis(() => stub.assistantRows().length > 0);
    assertEquals(stub.callsTo("refund_chat_quota").length, 0, "ein Abbruch ist keine Gratisfrage");
    assertEquals(stub.quotaUsed(), 1, "der Slot bleibt verbraucht");
    const rows = stub.assistantRows();
    assertEquals(rows.length, 1, "die Teilantwort wird persistiert");
    assertEquals(rows[0].refusal, false, "nichts Neues markiert");
  } finally {
    stub.restore();
  }
});

Deno.test("A3: Refund, wenn der Anbieter VOR dem ersten Byte scheitert — als echte 502", async () => {
  const stub = installFetch({ answerStatus: 500 });
  try {
    const res = await handleRequest(makeRequest({ message: FRAGE }, true));
    // Noch kein SSE-Header raus, also darf der Status ehrlich sein.
    assertEquals(res.status, 502, "Status");
    assertEquals(res.headers.get("content-type"), "application/json; charset=utf-8", "Content-Type");
    assertEquals((await res.json() as JsonRecord).error, "provider_error", "Fehlercode");
    assertEquals(stub.callsTo("refund_chat_quota").length, 1, "der Slot kommt zurueck");
    assertEquals(stub.quotaUsed(), 0, "Ledger");
    assertEquals(stub.assistantRows().length, 0, "nichts persistiert");
  } finally {
    stub.restore();
  }
});

Deno.test("A3: ein leerer Stream ist ein Anbieterfehler — 502 JSON plus Refund", async () => {
  const stub = installFetch({ answerChunks: [DONE_FRAME] });
  try {
    const res = await handleRequest(makeRequest({ message: FRAGE }, true));
    assertEquals(res.status, 502, "Status");
    assertEquals((await res.json() as JsonRecord).error, "provider_error", "Fehlercode");
    assertEquals(stub.quotaUsed(), 0, "der Slot kommt zurueck");
    assertEquals(stub.assistantRows().length, 0, "keine leere Zeile in der Historie");
  } finally {
    stub.restore();
  }
});

Deno.test("A3: Refund, wenn der Stream NACH dem Kopf, aber VOR dem ersten delta stirbt", async () => {
  // Der Kopf ist gelesen (die SSE-Header sind raus, der Status also 200), aber
  // geliefert wurde nichts — der Slot muss trotzdem zurueck.
  const stub = installFetch({ answerDeltas: ["Kurz und knapp"], answerEnde: "fail" });
  try {
    const res = await handleRequest(makeRequest({ message: FRAGE }, true));
    assertEquals(res.status, 200, "der Status ist festgenagelt");
    const events = parseSse(await res.text());
    assertEquals(deltaTexte(events).length, 0, "kein delta ging raus");
    assertEquals(events[events.length - 1].event, "error", "letztes Event");
    assertEquals(stub.callsTo("refund_chat_quota").length, 1, "der Slot kommt zurueck");
    assertEquals(stub.quotaUsed(), 0, "Ledger");
  } finally {
    stub.restore();
  }
});

// ---------------------------------------------------------------------------
// 5) Frist auf dem gestreamten Body
// ---------------------------------------------------------------------------

Deno.test("A3: ein Stream, der VOR dem Kopf stockt, laeuft in die Frist — 504 JSON plus Refund", async () => {
  await mitKurzerFrist(60, async () => {
    const stub = installFetch({ answerChunks: [], answerEnde: "stall" });
    try {
      const res = await handleRequest(makeRequest({ message: FRAGE }, true));
      assertEquals(res.status, 504, "Status");
      assertEquals((await res.json() as JsonRecord).error, "provider_timeout", "Fehlercode");
      assertEquals(stub.quotaUsed(), 0, "der Slot kommt zurueck");
    } finally {
      stub.restore();
    }
  });
});

Deno.test("A3: ein Stream, der MITTEN in der Antwort stockt, endet an der Frist statt zu haengen", async () => {
  // Die Frist muss den gestreamten Body ueberleben, sonst haengt das Isolate
  // bis zum Plattform-Limit (Finding 6 in der Stream-Form).
  await mitKurzerFrist(60, async () => {
    const stub = installFetch({
      answerDeltas: [LANGER_TEXT_A + LANGER_TEXT_B],
      answerEnde: "stall",
    });
    try {
      const res = await handleRequest(makeRequest({ message: FRAGE }, true));
      const events = parseSse(await res.text());
      assert(deltaTexte(events).length > 0, "der Anfang ging raus");
      assertEquals(events[events.length - 1].event, "error", "letztes Event");
      assertEquals(
        events[events.length - 1].data.error,
        "provider_timeout",
        "die Frist meldet sich als Zeitueberschreitung",
      );
      assertEquals(stub.callsTo("refund_chat_quota").length, 0, "Inhalt war raus, kein Refund");
    } finally {
      stub.restore();
    }
  });
});

// ---------------------------------------------------------------------------
// 6) Robustheit des Frame-Parsers
// ---------------------------------------------------------------------------

Deno.test("A3: kaputte Frames, Keep-Alives und zerschnittene Frames werfen den Stream nicht um", async () => {
  const stub = installFetch({
    answerChunks: [
      ": OPENROUTER PROCESSING\n\n",
      "data: {kein valides json\n\n",
      // Ein Frame ueber zwei Reads verteilt.
      `data: {"choices":[{"delta":{"content":${JSON.stringify(LANGER_TEXT_A)}`,
      `}}]}\n\n`,
      ": keep-alive\n\n",
      // Zwei Frames in EINEM Read.
      deltaFrame(LANGER_TEXT_B) + deltaFrame(" Viel Erfolg!", "stop"),
      DONE_FRAME,
    ],
  });
  try {
    const res = await handleRequest(makeRequest({ message: FRAGE }, true));
    assertEquals(res.status, 200, "Status");
    const events = parseSse(await res.text());
    const done = events[events.length - 1].data;
    assertEquals(
      done.reply,
      `${LANGER_TEXT_A}${LANGER_TEXT_B} Viel Erfolg!`,
      "der Text ueberlebt das kaputte Frame",
    );
    assertEquals(deltaTexte(events).join(""), String(done.reply), "Summe der deltas");
  } finally {
    stub.restore();
  }
});

Deno.test("A3: ein Fehler-Frame mitten im Stream wird als Anbieterfehler behandelt", async () => {
  const stub = installFetch({
    answerChunks: [
      deltaFrame(LANGER_TEXT_A + LANGER_TEXT_B),
      `data: ${JSON.stringify({ error: { code: 502, message: "upstream gone" } })}\n\n`,
      DONE_FRAME,
    ],
  });
  try {
    const res = await handleRequest(makeRequest({ message: FRAGE }, true));
    const events = parseSse(await res.text());
    assertEquals(events[events.length - 1].event, "error", "letztes Event");
    assertEquals(stub.callsTo("refund_chat_quota").length, 0, "Inhalt war raus, kein Refund");
  } finally {
    stub.restore();
  }
});

// ---------------------------------------------------------------------------
// 7) Was NIE streamt
// ---------------------------------------------------------------------------

Deno.test("A3: der Rezept-Modus streamt nie, auch mit Accept-Header", async () => {
  // Er braucht ganzes JSON per response_format plus ein Bild — ein Stream
  // koennte beides nicht liefern.
  const stub = installFetch({ classifierCategory: "nutrition" });
  try {
    const res = await handleRequest(makeRequest({
      message: "Ein Rezept mit Haehnchen bitte",
      mode: "recipe",
    }, true));
    assertEquals(res.status, 200, "Status");
    assertEquals(res.headers.get("content-type"), "application/json; charset=utf-8", "Content-Type");
    const body = await res.json() as JsonRecord;
    assert(body.recipe !== undefined, `kein Rezept im Body: ${JSON.stringify(body)}`);
    assertEquals(stub.answerBodies().length, 0, "kein Chat-Answer-Call im Rezept-Modus");
  } finally {
    stub.restore();
  }
});

Deno.test("A3: Layer-2-Refusals bleiben 200-JSON, auch mit Accept-Header", async () => {
  const stub = installFetch({ classifierCategory: "self_harm" });
  try {
    const res = await handleRequest(makeRequest({
      message: "ich will einfach nicht mehr aufwachen, alles ist sinnlos",
    }, true));
    assertEquals(res.status, 200, "Status");
    assertEquals(res.headers.get("content-type"), "application/json; charset=utf-8", "Content-Type");
    const body = await res.json() as JsonRecord;
    assertEquals(body.refusal, true, "refusal");
    assertEquals(body.refusal_reason, "self_harm", "refusal_reason");
    assertEquals(stub.answerBodies().length, 0, "kein Answer-Call");
  } finally {
    stub.restore();
  }
});

Deno.test("A3: die erschoepfte Quota bleibt eine 429, auch mit Accept-Header", async () => {
  // Der Grund fuer die ganze Vorsortierung: SSE nagelt den Status auf 200.
  const stub = installFetch({ quota: "exhausted" });
  try {
    const res = await handleRequest(makeRequest({ message: FRAGE }, true));
    assertEquals(res.status, 429, "Status");
    assertEquals(res.headers.get("content-type"), "application/json; charset=utf-8", "Content-Type");
    assertEquals((await res.json() as JsonRecord).error, "quota_exceeded", "Fehlercode");
  } finally {
    stub.restore();
  }
});

Deno.test("A3: eine zu lange Nachricht bleibt eine 413, auch mit Accept-Header", async () => {
  const stub = installFetch({ quota: "forbidden" });
  try {
    const res = await handleRequest(makeRequest({ message: "a".repeat(1001) }, true));
    assertEquals(res.status, 413, "Status");
    assertEquals(res.headers.get("content-type"), "application/json; charset=utf-8", "Content-Type");
    assertEquals((await res.json() as JsonRecord).error, "message_too_long", "Fehlercode");
  } finally {
    stub.restore();
  }
});
