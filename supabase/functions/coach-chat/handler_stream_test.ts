import { userToken } from "../_shared/auth_test_fixtures.ts";
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
// Attrappen-Stream statt Netz; `deno test --allow-env`. Der Anbieter spricht
// das Messages-API-Streamformat (message_start, content_block_*, message_delta,
// message_stop, ping, error); der SSE-Draht zur App (meta/delta/done/error)
// bleibt davon unberuehrt.

import {
  claudeErrorBody,
  claudeErrorEvent,
  claudeEvent,
  claudeResponse,
  claudeStreamHead,
  claudeStreamTail,
  claudeTextDelta,
  isClaudeCall,
  isClassifierRequest,
  outputSchema,
} from "../_shared/claude_test_fixtures.ts";
import { claudeErrorTypeFor, isDraftRequest, simulatedThinkingTokens } from "./claude_mode_test_helpers.ts";
import { handleRequest, PROMPT_LEAK_GUARD, PROVIDER_TIMEOUTS_MS } from "./handler.ts";

const USER_ID = "11111111-1111-4111-8111-111111111111";
const SESSION_ID = "22222222-2222-4222-8222-222222222222";
const ASSISTANT_MSG_ID = "33333333-3333-4333-8333-333333333333";
const BASE_URL = "https://supabase.test.invalid";
const DAILY_LIMIT = 5;

// Katalogtexte (REFUSAL_TEXTS in handler.ts) — Byte-Kopien, dieselbe Regel wie
// in handler_test.ts: eine Aenderung dort muss hier rot werden.
const FALLBACK_REPLY =
  "Das geht ueber meinen Bereich hinaus - ich bin nur fuer Training und Ernaehrung da.";
const PROVIDER_REFUSAL_REPLY =
  "Dabei kann ich dir nicht helfen. Falls dich gerade etwas belastet: Die Telefonseelsorge ist rund um die Uhr " +
  "unter 0800 111 0 111 erreichbar. Bei Training und Ernaehrung helfe ich dir gern weiter.";
const PROVIDER_REFUSAL_REPLY_EN =
  "I can't help with that. If something is weighing on you, the Telefonseelsorge crisis line is available " +
  "around the clock at 0800 111 0 111 (free of charge in Germany); outside Germany, findahelpline.com lists " +
  "helplines for your country. I'm happy to help with training and nutrition.";
const PROMPT_LEAK_REPLY =
  "Das ist nichts, was ich teilen sollte. Frag mich lieber was zu deinem naechsten Workout oder zu Ernaehrung.";
const PROMPT_LEAK_REPLY_EN =
  "That's not something I should share. Ask me about your next workout or about nutrition instead.";

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
Deno.env.set("ANTHROPIC_API_KEY", "test-anthropic-key");
// Recipe images only.
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

// Jedes Array-Element ist EIN Read des Anbieter-Bodys.

/** message_start plus Denkblock (nur Signatur) bis zum geoeffneten Textblock. */
const KOPF = claudeStreamHead();

/** Ein Textdelta des Antwortblocks. */
const textDelta = claudeTextDelta;

/** Blockende und stop_reason (finish_reason-Vokabular), OHNE message_stop. */
function ende(finishReason: string | null): string[] {
  return claudeStreamTail(finishReason).slice(0, 2);
}

/** Der vollstaendige Abschluss: Blockende, stop_reason, message_stop. */
const abschluss = claudeStreamTail;

/** Kopf, ein Delta pro Text, Abschluss. */
function antwort(teile: string[], finishReason: string | null = "stop"): string[] {
  return [...KOPF, ...teile.map(textDelta), ...abschluss(finishReason)];
}

/** Keep-Alive des Messages API. */
const PING = claudeEvent({ type: "ping" });

/** Ein Denk-Delta; mit display "summarized" oder "updates" traegt es Text. */
function denkDelta(index: number, gedanke: string): string {
  return claudeEvent({ type: "content_block_delta", index, delta: { type: "thinking_delta", thinking: gedanke } });
}

function signaturDelta(index: number, signatur: string): string {
  return claudeEvent({ type: "content_block_delta", index, delta: { type: "signature_delta", signature: signatur } });
}

/** Ein error-Event mitten im Stream (F2); `type` ist ein API-Fehlertyp. */
const fehlerEvent = claudeErrorEvent;

/** Holds the provider before block `before` until `gate` resolves (COACH-4). */
interface AnswerHalt {
  before: number;
  gate: Promise<void>;
}

/** Wie der Attrappen-Stream endet, nachdem seine Bloecke raus sind. */
type StreamEnde =
  /** Sauber geschlossen. */
  | "close"
  /** Anbieter-Ausfall mitten in der Antwort. */
  | "fail"
  /** Stiller Upstream: nur die Frist beendet das noch. */
  | "stall"
  /** Haelt an, bis der Test das Tor oeffnet — dann sauber geschlossen. */
  | "tor";

/**
 * Antwort-Body des Anbieters. Die Bloecke sind BYTE-Bloecke, keine Frames —
 * genau so laesst sich nachstellen, was ein echter Stream tut: mehrere Events
 * in einem Read, ein Event ueber zwei Reads verteilt, ping-Keep-Alives.
 *
 * `beiCancel` meldet, dass der Handler den Anbieter-Reader freigegeben hat —
 * eine offene Verbindung waere sonst unsichtbar.
 */
function providerBody(
  bloecke: string[],
  ende: StreamEnde,
  signal: AbortSignal | null | undefined,
  beiCancel: () => void,
  tor?: Promise<void>,
  halt?: AnswerHalt,
): ReadableStream<Uint8Array> {
  const enc = new TextEncoder();
  let i = 0;
  let gehalten = false;
  return new ReadableStream<Uint8Array>({
    pull(controller) {
      if (halt && i === halt.before && !gehalten) {
        gehalten = true;
        // Like a real fetch body: an aborted signal fails the pending read.
        return new Promise<void>((resolve, reject) => {
          if (signal?.aborted) {
            reject(signal.reason);
            return;
          }
          signal?.addEventListener("abort", () => reject(signal.reason), { once: true });
          halt.gate.then(resolve);
        }).then(() => this.pull!(controller));
      }
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
      if (ende === "tor") {
        return (tor ?? Promise.resolve()).then(() => controller.close());
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
    cancel() {
      beiCancel();
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
  /** Bequemer: je ein Textdelta pro Text, mit message_stop am Ende. */
  answerDeltas?: string[];
  /** stop_reason im message_delta, im finish_reason-Vokabular. */
  answerFinishReason?: string | null;
  /** Wie der Stream nach seinen Bloecken endet (Standard: sauber). */
  answerEnde?: StreamEnde;
  /** Tor fuer answerEnde: "tor" — der Anbieter haelt an, bis das aufloest. */
  answerTor?: Promise<void>;
  /** Holds the provider mid-answer, honouring its abort signal. */
  answerHalt?: AnswerHalt;
  /** HTTP-Status des Antwort-Calls (Ausfall vor jedem Byte). */
  answerStatus?: number;
  /** Inhalt des GEPUFFERTEN Antwort-Calls (Pfad ohne Opt-in). */
  answerContent?: string;
  /** Ganzer gepufferter Messages-API-Body statt answerContent. */
  answerEnvelope?: JsonRecord;
  /** Simulate a provider whose completion (including reasoning) exceeds 800 tokens. */
  answerNeedsHeadroom?: boolean;
  /** Inhalt des strukturierten Rezept-Entwurfs. */
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
  /** Wurde der Anbieter-Reader freigegeben? (offene Verbindung sonst blind) */
  providerCancelled(): boolean;
  providerAborted(): boolean;
  restore(): void;
}

function installFetch(options: StubOptions = {}): FetchStub {
  const calls: RecordedCall[] = [];
  const original = globalThis.fetch;
  let quotaUsed = 0;
  let providerCancelled = false;
  let providerSignal: AbortSignal | null | undefined;

  function streamedAnswer(signal: AbortSignal | null | undefined): Response {
    providerSignal = signal;
    const streamEnde = options.answerEnde ?? "close";
    const finishReason = options.answerFinishReason === undefined ? "stop" : options.answerFinishReason;
    const bloecke = options.answerChunks ??
      [
        ...KOPF,
        ...(options.answerDeltas ?? ["Klar, machen wir das."]).map(textDelta),
        // message_stop nur im sauberen Fall: ein Ausfall/Haenger passiert per
        // Definition, BEVOR der Anbieter sein Ende schickt.
        ...(streamEnde === "close" ? abschluss(finishReason) : ende(finishReason)),
      ];
    return new Response(
      providerBody(bloecke, streamEnde, signal, () => {
        providerCancelled = true;
      }, options.answerTor, options.answerHalt),
      { status: 200, headers: { "content-type": "text/event-stream" } },
    );
  }

  function route(
    url: string,
    method: string,
    body: string,
    signal: AbortSignal | null | undefined,
  ): Response {
    if (url.endsWith("/rest/v1/rpc/reserve_ai_provider_call")) return jsonRes({ allowed: true, reason: "allowed" });
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
      return jsonRes([{ used: quotaUsed, remaining: DAILY_LIMIT - quotaUsed, quota_day: "2026-09-08" }]);
    }
    if (url.includes("/rest/v1/rpc/refund_chat_quota")) {
      quotaUsed = Math.max(0, quotaUsed - 1);
      return new Response(null, { status: 204 });
    }
    if (url.includes("openrouter.ai/api/v1/images")) {
      return jsonRes({ data: [{ b64_json: IMAGE_B64, media_type: "image/jpeg" }] });
    }
    if (isClaudeCall(url)) {
      const parsed = JSON.parse(body) as JsonRecord;
      // Classifier and drafts are told apart by their output schema, never by
      // an output budget.
      if (isClassifierRequest(parsed)) {
        return jsonRes(claudeResponse(JSON.stringify({
          category: options.classifierCategory ?? "fitness",
          confidence: "high",
        })));
      }
      if (isDraftRequest(parsed)) return jsonRes(claudeResponse(options.draftContent ?? RECIPE_JSON));
      if (options.answerStatus !== undefined) {
        return new Response(claudeErrorBody(claudeErrorTypeFor(options.answerStatus)), {
          status: options.answerStatus,
          headers: { "content-type": "application/json" },
        });
      }
      if (options.answerNeedsHeadroom) {
        // Live reproduction (Gemini era): 528 reasoning tokens left only ~270
        // visible tokens in an 800-token cap. Adaptive thinking also counts
        // against max_tokens; this fixture needs 700 visible tokens.
        const truncated = Number(parsed.max_tokens) < simulatedThinkingTokens(parsed) + 700;
        const content = truncated ? COMPLETE_RECIPE.slice(0, 526) : COMPLETE_RECIPE;
        const finishReason = truncated ? "length" : "stop";
        if (parsed.stream === true) {
          return new Response(
            providerBody(antwort([content.slice(0, 400), content.slice(400)], finishReason), "close", signal, () => {
              providerCancelled = true;
            }),
            { headers: { "content-type": "text/event-stream" } },
          );
        }
        return jsonRes(claudeResponse(content, finishReason));
      }
      if (parsed.stream === true) return streamedAnswer(signal);
      return jsonRes(options.answerEnvelope ?? claudeResponse(
        options.answerContent ?? "Klar, machen wir das.",
        options.answerFinishReason === undefined ? "stop" : options.answerFinishReason,
      ));
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
    // Answer calls are the Claude calls without an output schema.
    answerBodies: () =>
      calls
        .filter((call) => isClaudeCall(call.url))
        .map((call) => JSON.parse(call.body) as JsonRecord)
        .filter((parsed) => outputSchema(parsed) === undefined),
    assistantRows: () =>
      calls
        .filter((call) => call.url.includes("/rest/v1/chat_messages") && call.method === "POST")
        .map((call) => JSON.parse(call.body) as JsonRecord)
        .filter((row) => row.role === "assistant"),
    quotaUsed: () => quotaUsed,
    providerCancelled: () => providerCancelled,
    providerAborted: () => providerSignal?.aborted === true,
    restore: () => {
      globalThis.fetch = original;
    },
  };
}

// 1x1 PNG: with a photo in the request, an input-fault error stays the user's.
const FOTO = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==";

function makeRequest(payload: JsonRecord, stream = false, signal?: AbortSignal): Request {
  return new Request("https://edge.test.invalid/coach-chat", {
    method: "POST",
    signal,
    headers: {
      "authorization": `Bearer ${userToken(USER_ID)}`,
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

interface EdgeRuntimeStub {
  /** Work registered via waitUntil, in order. */
  registered: Promise<unknown>[];
  /** Resolves once everything registered so far (and anything it adds) settled. */
  settled(): Promise<void>;
  restore(): void;
}

/** Stands in for Supabase's EdgeRuntime: collects what the handler asks the
 *  worker to wait for, so a test can await exactly that work (COACH-4). */
function installEdgeRuntime(): EdgeRuntimeStub {
  const g = globalThis as { EdgeRuntime?: unknown };
  const before = g.EdgeRuntime;
  const registered: Promise<unknown>[] = [];
  g.EdgeRuntime = { waitUntil: (work: Promise<unknown>) => { registered.push(work); } };
  return {
    registered,
    settled: async () => {
      for (let seen = -1; seen !== registered.length;) {
        seen = registered.length;
        await Promise.all(registered);
      }
    },
    restore: () => {
      if (before === undefined) delete g.EdgeRuntime;
      else g.EdgeRuntime = before;
    },
  };
}

/** Reads until `marker` arrived; returns what was read. */
async function liesBis(reader: ReadableStreamDefaultReader<Uint8Array>, marker: string): Promise<string> {
  const decoder = new TextDecoder();
  let gelesen = "";
  while (!gelesen.includes(marker)) {
    const { value, done } = await reader.read();
    if (done) break;
    gelesen += decoder.decode(value, { stream: true });
  }
  return gelesen;
}

/** Everything left in the body. */
async function liesRest(reader: ReadableStreamDefaultReader<Uint8Array>): Promise<string> {
  const decoder = new TextDecoder();
  let rest = "";
  for (;;) {
    const { value, done } = await reader.read();
    if (done) return rest;
    rest += decoder.decode(value, { stream: true });
  }
}

// Lang genug, dass der Kopfpuffer sicher freigegeben wird (der Leck-Riegel
// haelt die letzten 64 Zeichen zurueck, solange der Stream offen ist).
const LANGER_TEXT_A =
  "Nach dem Training sind 25 bis 30 g Protein ein guter Richtwert, damit die Muskulatur ";
const LANGER_TEXT_B =
  "gut versorgt ist und du deine Tagesbilanz nicht sprengst. Quark oder Huehnchen passen.";

const COMPLETE_RECIPE =
  "Fuer eine leichte Sauce im Cane's-Stil verruehrst du 100 g Naturjoghurt, " +
  "20 g leichte Mayonnaise und 20 g Ketchup. Gib etwas Worcestershire-Sauce, " +
  "Knoblauchpulver und schwarzen Pfeffer dazu. Schmecke erst danach mit Salz ab.\n\n" +
  "Verruehre alles mit einer Gabel, bis die Sauce glatt ist. Lass sie eine halbe " +
  "Stunde abgedeckt im Kuehlschrank ziehen. Die Gewuerze entwickeln ihren " +
  "Geschmack dabei noch weiter. Probiere deshalb vor dem Nachwuerzen erneut.\n\n" +
  "Fuer eine duennere Konsistenz gibst du teeloeffelweise Wasser dazu. Ist sie " +
  "zu fluessig, hilft etwas mehr Joghurt. Die Naehrwerte haengen von deinen " +
  "Produkten ab; teile die Summe der Zutaten durch die Anzahl der Portionen. " +
  "Die fertige Sauce passt zu Ofenkartoffeln und gebratenem Haehnchen.";

for (const streaming of [false, true]) {
  Deno.test(`completion headroom: Rezept kommt vollstaendig an (${streaming ? "SSE" : "JSON"})`, async () => {
    const stub = installFetch({ classifierCategory: "nutrition", answerNeedsHeadroom: true });
    try {
      const res = await handleRequest(makeRequest({
        message: "Eine leichte Raising Canes Sauce mit Zutaten, Zubereitung und Konsistenz-Tipps bitte.",
      }, streaming));
      assertEquals(res.status, 200, "Status");
      let body: JsonRecord;
      if (streaming) {
        const events = parseSse(await res.text());
        assertEquals(events.at(-1)?.event, "done", "sauberer Streamabschluss");
        body = events.at(-1)!.data;
        assertEquals(deltaTexte(events).join(""), COMPLETE_RECIPE, "vollstaendige Deltas");
      } else {
        body = await res.json();
      }
      assertEquals(body.reply, COMPLETE_RECIPE, "auch das Ende muss ankommen");
      assertEquals(body.refusal, false, "keine Ablehnung");
      assertEquals(stub.assistantRows().length, 1, "eine gespeicherte Antwort");
      assertEquals(stub.assistantRows()[0].content, COMPLETE_RECIPE, "vollstaendig gespeichert");
      assertEquals(stub.quotaUsed(), 1, "ein Quota-Slot");
      const answers = stub.answerBodies();
      assertEquals(answers.length, 1, "keine weiteren bezahlten Antwortaufrufe");
      assertEquals(answers[0].max_tokens, 4096, "Antwort-Budget deckt Denken plus Text");
      assertEquals(
        JSON.stringify(answers[0].output_config),
        JSON.stringify({ effort: "high" }),
        "Coach-Denkstufe (COACH_EFFORT-Standard), kein Schema",
      );
      // Ohne display "summarized" bleibt der Denktext beim Anbieter.
      assertEquals(JSON.stringify(answers[0].thinking), JSON.stringify({ type: "adaptive" }), "adaptives Denken");
      for (const key of ["temperature", "top_p", "top_k", "reasoning"]) {
        assert(!(key in answers[0]), `kein ${key}: Sonnet 5.5 lehnt Sampling-Parameter ab`);
      }
    } finally {
      stub.restore();
    }
  });
}

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
    // English locale on both: a streamed path that dropped it would fall back
    // to German and differ here.
    await handleRequest(makeRequest({ message: FRAGE, user_context: "Ziel: 2000 kcal", locale: "en" }));
    ohneStream = gepuffert.answerBodies()[0];
  } finally {
    gepuffert.restore();
  }
  const gestreamt = installFetch({ answerDeltas: [LANGER_TEXT_A] });
  try {
    const res = await handleRequest(
      makeRequest({ message: FRAGE, user_context: "Ziel: 2000 kcal", locale: "en" }, true),
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
  // Approved answers keep the existing chunked SSE wire contract.
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
    answerChunks: antwort(["__RE", "FUSE", "__ Da gehe ich nicht mit."]),
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
    answerChunks: antwort(["\n\n  __REFUSE__ Nicht mein Thema."]),
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

Deno.test("Security: provider failure after generated text releases nothing and refunds once", async () => {
  const stub = installFetch({ answerDeltas: [LANGER_TEXT_A, LANGER_TEXT_B], answerEnde: "fail" });
  try {
    const response = await handleRequest(makeRequest({ message: FRAGE }, true));
    const events = parseSse(await response.text());
    assertEquals(deltaTexte(events).length, 0, "unapproved text is never released");
    assertEquals(events[events.length - 1].data.error, "provider_error", "honest stream failure");
    assertEquals(stub.callsTo("refund_chat_quota").length, 1, "one outage refund");
    assertEquals(stub.assistantRows().length, 0, "no unapproved history");
  } finally { stub.restore(); }
});

Deno.test("Security: cancel after approved deltas never refunds", async () => {
  const stub = installFetch({ answerDeltas: [LANGER_TEXT_A + LANGER_TEXT_B] });
  try {
    const response = await handleRequest(makeRequest({ message: FRAGE }, true));
    const reader = response.body!.getReader();
    const decoder = new TextDecoder();
    let seen = "";
    while (!seen.includes("event: delta")) {
      const item = await reader.read();
      if (item.done) break;
      seen += decoder.decode(item.value, { stream: true });
    }
    assert(seen.includes("event: delta"), "approved text was released");
    await reader.cancel();
    await warteBis(() => stub.assistantRows().length > 0);
    assertEquals(stub.callsTo("refund_chat_quota").length, 0, "cancel is not a free question");
    assertEquals(stub.quotaUsed(), 1, "paid slot retained");
  } finally { stub.restore(); }
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
  // Sauber abgeschlossen (end_turn, message_stop), aber ohne ein Zeichen Text.
  const stub = installFetch({ answerChunks: antwort([]) });
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
      assertEquals(deltaTexte(events).length, 0, "no unapproved prefix");
      assertEquals(events[events.length - 1].event, "error", "letztes Event");
      assertEquals(
        events[events.length - 1].data.error,
        "provider_timeout",
        "die Frist meldet sich als Zeitueberschreitung",
      );
      assertEquals(stub.callsTo("refund_chat_quota").length, 1, "unapproved content stays internal, outage refunded");
    } finally {
      stub.restore();
    }
  });
});

// ---------------------------------------------------------------------------
// 6) Robustheit des Frame-Parsers
// ---------------------------------------------------------------------------

Deno.test("A3: Keep-Alives und zerschnittene Frames erhalten die vollstaendige Antwort", async () => {
  const geteilt = textDelta(LANGER_TEXT_A);
  // Mitten im JSON der data:-Zeile, nicht an einer Zeilengrenze.
  const schnitt = geteilt.indexOf("Protein");
  const stub = installFetch({
    answerChunks: [
      PING,
      ...KOPF,
      PING,
      // Ein Event ueber zwei Reads verteilt.
      geteilt.slice(0, schnitt),
      geteilt.slice(schnitt),
      // SSE-Kommentar: der Parser ueberspringt ihn wie ein ping.
      ": keep-alive\n\n",
      // Zwei Events plus ping in EINEM Read.
      textDelta(LANGER_TEXT_B) + PING + textDelta(" Viel Erfolg!"),
      // Das Ende in einem Read, ueber CRLF-Zeilenenden.
      abschluss("stop").join("").replaceAll("\n", "\r\n"),
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
      "der Text ueberlebt die Chunkgrenzen",
    );
    assertEquals(deltaTexte(events).join(""), String(done.reply), "Summe der deltas");
  } finally {
    stub.restore();
  }
});

Deno.test("A3: ein Fehler-Frame mitten im Stream wird als Anbieterfehler behandelt", async () => {
  // Der Abschluss nach dem error-Event wird nie mehr gelesen.
  const stub = installFetch({
    answerChunks: [
      ...KOPF,
      textDelta(LANGER_TEXT_A + LANGER_TEXT_B),
      fehlerEvent("api_error", "upstream gone"),
      ...abschluss("stop"),
    ],
  });
  try {
    const res = await handleRequest(makeRequest({ message: FRAGE }, true));
    const events = parseSse(await res.text());
    assertEquals(events[events.length - 1].event, "error", "letztes Event");
    assertEquals(stub.callsTo("refund_chat_quota").length, 1, "unapproved content stays internal, outage refunded");
  } finally {
    stub.restore();
  }
});

// ---------------------------------------------------------------------------
// 7) Was NIE streamt
// ---------------------------------------------------------------------------

Deno.test("A3: der Rezept-Modus streamt nie, auch mit Accept-Header", async () => {
  // Er braucht ganzes JSON per Output-Schema plus ein Bild — ein Stream
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
    const claude = stub.calls.filter((call) => isClaudeCall(call.url)).map((call) => JSON.parse(call.body) as JsonRecord);
    assertEquals(claude.length, 2, "Classifier plus Entwurf");
    assert(claude.every((call) => call.stream === undefined), "kein Anbieter-Stream im Rezept-Modus");
  } finally {
    stub.restore();
  }
});

Deno.test("A3: der Log-Modus streamt nie, auch mit Accept-Header", async () => {
  // Der ganze Vorschlag wird vor der Auslieferung validiert, wie bei /plan.
  const draftContent = JSON.stringify({ status: "ok", refuse_reason: null, workout: {
    title: "Workout", performed_on: null, duration_minutes: null, other_days_omitted: false, note: "",
    exercises: [{ name: "Squat", kind: "reps", duration_seconds: null, weight_unit: "kg", sets: [{ reps: 5, weight: 100 }] }],
  } });
  const stub = installFetch({ draftContent });
  try {
    const res = await handleRequest(makeRequest({
      message: "today squats 5 at 100 kg",
      mode: "log",
      local_date: new Date(Date.now()).toISOString().slice(0, 10),
    }, true));
    assertEquals(res.status, 200, "Status");
    assertEquals(res.headers.get("content-type"), "application/json; charset=utf-8", "Content-Type");
    const body = await res.json() as JsonRecord;
    assert(body.workout_log !== undefined, `kein Log im Body: ${JSON.stringify(body)}`);
    assertEquals(stub.answerBodies().length, 0, "kein Chat-Answer-Call im Log-Modus");
    const claude = stub.calls.filter((call) => isClaudeCall(call.url)).map((call) => JSON.parse(call.body) as JsonRecord);
    assertEquals(claude.length, 2, "Classifier plus Extraktion");
    assert(claude.every((call) => call.stream === undefined), "kein Anbieter-Stream im Log-Modus");
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

// ---------------------------------------------------------------------------
// 8) F1 — das Leck-Netz greift auf INHALT, nicht nur auf die Phrase
//
// PROMPT_LEAK_RE feuert erst, wenn das Modell den Prompt BENENNT, also am ENDE
// eines Lecks. Gepuffert reicht das (die ganze Antwort wird getauscht),
// gestreamt nicht: wer erst zitiert und zuletzt "das war mein system prompt"
// schreibt, hat den Inhalt laengst auf der Leitung — zurueckgehalten werden nur
// LEAK_GUARD_TAIL Zeichen. Keine Riegelgroesse schliesst das, die Trigger-
// Phrase kann beliebig spaet kommen. Deshalb prueft das Netz jetzt auch auf die
// WORTFOLGEN des Prompts selbst.
//
// Die Gegenrichtung ist das teurere Risiko: eine faelschlich als Leck erkannte
// Antwort kostet einen von fuenf Tagesslots und sieht aus wie ein Fehler. Die
// Matrix und die letzten beiden Tests halten genau das fest.
// ---------------------------------------------------------------------------

// Byte-Kopien aus ANSWER_SYSTEM_PROMPT (handler.ts) — dieselbe Regel wie bei
// den Katalogtexten: wird der Prompt umformuliert, muss das hier rot werden.
const PROMPT_ZEILE_1 =
  "You are Eatova Coach - a friendly fitness and nutrition coach inside a mobile app. " +
  "The app's primary user-language is German but you must adapt.";
const PROMPT_ZEILE_2 =
  "- Detect the user's message language and ALWAYS reply in that same language.";
const PROMPT_STIL_ZEILE =
  "- Plain text only: the app renders your reply verbatim. No Markdown, no asterisks, " +
  "no bullet symbols, no headings, no tables, no code fences.";

// COACH-1: an English crisis reply that copies the CRISIS RULE wording
// ("German helpline number 0800 111 0 111"). The rule ORDERS the number, so
// this is no leak.
const KRISE_EN = "I'm really sorry you're going through this. Please talk to someone you trust, " +
  "or call the German helpline number 0800 111 0 111, available around the clock. You are not alone.";
// Byte copy of REFUSAL_TEXTS.self_harm.en.
const SELF_HARM_REPLY_EN =
  "Please talk to someone about this - the Telefonseelsorge crisis line is available around the clock " +
  "at 0800 111 0 111 (free of charge in Germany). Outside Germany, findahelpline.com lists helplines " +
  "for your country. You are not alone.";
// The app's caption for a photo sent without words (app_en.arb).
const BILD_STANDARD_EN = "Analyze this image in a fitness context.";

Deno.test("F1: Prompt-Inhalt zuerst, Trigger-Phrase zuletzt — nichts davon geht raus", async () => {
  // Der Angriff aus dem Review: das Modell zitiert erst den Prompt und benennt
  // ihn erst im letzten Satz. Vorher gingen 151 Zeichen Prompt raus, weil nur
  // die letzten 64 Zeichen zurueckgehalten wurden.
  const stub = installFetch({
    answerDeltas: [
      "Klar, ich erklaere dir gern, wie ich arbeite. ",
      PROMPT_ZEILE_1,
      PROMPT_ZEILE_2,
      " Das war mein system prompt.",
    ],
  });
  try {
    const res = await handleRequest(makeRequest({ message: FRAGE }, true));
    const events = parseSse(await res.text());
    const geliefert = deltaTexte(events).join("");
    for (const teil of ["Eatova Coach", "friendly fitness", "Detect the user", "ALWAYS reply"]) {
      assert(!geliefert.includes(teil), `Prompt-Inhalt auf der Leitung: ${geliefert}`);
    }
    assertEquals(deltaTexte(events).length, 0, "gar kein delta");
    const done = events[events.length - 1].data;
    assertEquals(done.reply, PROMPT_LEAK_REPLY, "done traegt den Katalogtext");
    assertEquals(done.refusal, true, "refusal");
    assertEquals(stub.assistantRows()[0].content, PROMPT_LEAK_REPLY, "persistierter Text");
    // Dieselbe Buchhaltung wie beim Phrasen-Treffer: kein Refund.
    assertEquals(stub.callsTo("refund_chat_quota").length, 0, "kein Refund");
    assertEquals(stub.quotaUsed(), 1, "der Slot bleibt verbraucht");
  } finally {
    stub.restore();
  }
});

Deno.test("F1: ein Leck WORT FUER WORT trippt die Tabelle trotzdem", async () => {
  // Die Luecke, die der obige Test nicht sieht: dort kommt die Prompt-Zeile in
  // EINEM Block, also liegt jedes 7-Wort-Fenster komplett im neuen Text. Der
  // Cursor `leakFrom` haelt deshalb genau die Fenster offen, die ueber die
  // Blockgrenze reichen — `words.length - SHINGLE_WORDS`, nicht `words.length`.
  // Ein Modell, das Token fuer Token zitiert (der Normalfall beim Streaming),
  // erzeugt AUSSCHLIESSLICH grenzueberschreitende Fenster: mit dem falschen
  // Cursor feuert die Tabelle nie, und der Prompt geht bis auf die letzten
  // LEAK_GUARD_TAIL Zeichen raus.
  const stub = installFetch({
    answerDeltas: PROMPT_ZEILE_1.split(" ").map((wort) => `${wort} `),
  });
  try {
    const res = await handleRequest(makeRequest({ message: FRAGE }, true));
    const events = parseSse(await res.text());
    const geliefert = deltaTexte(events).join("");
    for (const teil of ["Eatova Coach", "friendly fitness", "nutrition coach", "mobile app"]) {
      assert(!geliefert.includes(teil), `Prompt-Inhalt auf der Leitung: ${geliefert}`);
    }
    assertEquals(deltaTexte(events).length, 0, "gar kein delta");
    const done = events[events.length - 1].data;
    assertEquals(done.reply, PROMPT_LEAK_REPLY, "done traegt den Katalogtext");
    assertEquals(done.refusal, true, "refusal");
    assertEquals(stub.quotaUsed(), 1, "der Slot bleibt verbraucht");
  } finally {
    stub.restore();
  }
});



Deno.test("F1: das Netz trennt Prompt-Wortlaut von echten Coach-Antworten", () => {
  // Die Matrix, die die Ausnahmen festhaelt: was der Prompt dem Modell
  // woertlich BEFIEHLT, ist kein Leck.
  const faelle: { text: string; leck: boolean; was: string }[] = [
    { text: PROMPT_ZEILE_1, leck: true, was: "die Persona-Zeile" },
    { text: PROMPT_ZEILE_2, leck: true, was: "die Sprachregel" },
    {
      text: "Ich sage dir gleich: mein system prompt bleibt bei mir.",
      leck: true,
      was: "die benannte Phrase (Verteidigung in der Tiefe)",
    },
    {
      text:
        "Nach dem Training sind 25 bis 30 g Protein ein guter Richtwert. Ein Magerquark mit " +
        "Beeren liegt bei ungefaehr 250 bis 300 kcal und passt in dein Abendessen, ohne deine " +
        "Tagesbilanz zu sprengen. Wenn du magst, rechnen wir das gleich auf deine Slots um.",
      leck: false,
      was: "eine normale deutsche Coach-Antwort",
    },
    {
      text:
        "I can help with calories, macros, portion sizes, meal timing, hydration, whole foods, " +
        "food swaps, eating out and cravings, and with strength, hypertrophy, endurance, " +
        "mobility, recovery, sleep and stress in the context of sport.",
      leck: false,
      was: "die englische Themenliste (YOUR SCOPE ist ausgenommen)",
    },
    {
      text:
        "I can look at your photo when it is about fitness, body progress, exercise form, " +
        "nutrition, meals, recovery, or coaching.",
      leck: false,
      was: "die Bild-Themenliste (VISUAL INPUT RULES ist ausgenommen)",
    },
    {
      text:
        "Bitte sprich mit jemandem darueber - die Telefonseelsorge ist unter 0800 111 0 111 " +
        "rund um die Uhr erreichbar. Du bist nicht allein.",
      leck: false,
      was: "der Krisen-Wortlaut, den der Prompt woertlich verlangt",
    },
    {
      text: "That is outside what I can help with - I am just your coach for training and nutrition.",
      leck: false,
      was: "das Refusal-Beispiel aus dem Prompt",
    },
    {
      text: KRISE_EN,
      leck: false,
      was: "englische Krisenantwort mit der Formulierung aus der CRISIS RULE",
    },
    {
      text: "I will not analyze, rate or comment on the image. " + KRISE_EN,
      leck: false,
      was: "Krisenantwort, die die Bildregel der CRISIS RULE wiederholt",
    },
    {
      text: "That has nothing to do with fitness, nutrition, or being a coach, so I can't help with it.",
      leck: false,
      was: "englische Off-Topic-Ablehnung mit der Begruendung aus Punkt 4",
    },
    {
      text: PROMPT_STIL_ZEILE,
      leck: true,
      was: "eine STYLE-Zeile bleibt in der Tabelle",
    },
    {
      text: "1. NO medical diagnoses, medication- or steroid recommendations. If they describe " +
        "symptoms, point them to a doctor / physio.",
      leck: true,
      was: "der Rest von WHAT YOU DO NOT DO bleibt in der Tabelle",
    },
  ];
  for (const fall of faelle) {
    assertEquals(PROMPT_LEAK_GUARD.leaks(fall.text), fall.leck, fall.was);
  }
});

Deno.test("F1: eine lange, saubere Coach-Antwort streamt vollstaendig", async () => {
  const teile = [
    "Nach dem Training sind 25 bis 30 g Protein ein guter Richtwert, damit die Muskulatur gut ",
    "versorgt ist. Ein Magerquark mit Beeren liegt bei ungefaehr 250 bis 300 kcal und passt ",
    "damit gut in dein Abendessen, ohne deine Tagesbilanz zu sprengen. Wenn dir das zu wenig ",
    "ist, nimm noch eine Scheibe Vollkornbrot dazu - das sind rund 100 kcal mehr und ein paar ",
    "langsame Kohlenhydrate, die dich bis zum Schlafen satt halten.",
  ];
  const stub = installFetch({ answerDeltas: teile });
  try {
    const res = await handleRequest(makeRequest({ message: FRAGE }, true));
    const events = parseSse(await res.text());
    const deltas = deltaTexte(events);
    assert(deltas.length > 1, `nicht wirklich gestreamt: ${deltas.length} delta(s)`);
    assertEquals(deltas.join(""), teile.join(""), "die Deltas ergeben den ganzen Text");
    const done = events[events.length - 1].data;
    assertEquals(done.reply, teile.join(""), "done traegt denselben Text");
    assertEquals(done.refusal, false, "keine Refusal");
  } finally {
    stub.restore();
  }
});

Deno.test("F1: die Krisen-Antwort im woertlichen Wortlaut ist kein Leck", async () => {
  // Der teuerste Fehlalarm, den dieses Netz produzieren koennte: der Prompt
  // verlangt diesen Satz woertlich, er darf nie zum Katalogtext werden.
  const KRISE = "Bitte sprich mit jemandem darueber - die Telefonseelsorge ist unter " +
    "0800 111 0 111 rund um die Uhr erreichbar. Du bist nicht allein.";
  const stub = installFetch({ answerDeltas: [`__REFUSE__ ${KRISE}`] });
  try {
    const res = await handleRequest(makeRequest({ message: FRAGE }, true));
    const events = parseSse(await res.text());
    const done = events[events.length - 1].data;
    assertEquals(done.reply, KRISE, "der Krisentext bleibt stehen");
    assertEquals(done.refusal, true, "als Refusal markiert");
  } finally {
    stub.restore();
  }
});

Deno.test("COACH-1: die englische Krisenantwort auf ein Foto behaelt die Nummer, auch im Stream", async () => {
  // A photo without words carries only the default caption; the classifier
  // never sees the image and passes it as fitness. Only the CRISIS RULE
  // catches it, and its reply must not become the leak catalogue text.
  const stub = installFetch({ answerDeltas: [`__REFUSE__ ${KRISE_EN}`] });
  try {
    const res = await handleRequest(
      makeRequest({ message: BILD_STANDARD_EN, image_base64: FOTO, locale: "en" }, true),
    );
    const events = parseSse(await res.text());
    assertEquals(deltaTexte(events).length, 0, "eine Refusal kommt ohne delta");
    const done = events[events.length - 1].data;
    assertEquals(done.reply, KRISE_EN, "die Krisenantwort des Modells bleibt stehen");
    assertEquals(done.refusal, true, "als Refusal markiert");
    const rows = stub.assistantRows();
    assertEquals(rows.length, 1, "eine Assistant-Zeile");
    assertEquals(rows[0].content, KRISE_EN, "gespeichert wird die Krisenantwort");
    assertEquals(stub.callsTo("refund_chat_quota").length, 0, "kein Refund");
  } finally {
    stub.restore();
  }
});

Deno.test("COACH-1: ein Leck mit der Krisennummer wird zum Krisen-Katalogtext, nie zum Leck-Text", async () => {
  // Second safeguard: a leak is still replaced completely (otherwise an
  // appended 0800 111 0 111 would carry any dump through), but the
  // replacement keeps the helpline.
  for (const nummer of ["0800 111 0 111", "0800-111-0-111"]) {
    const stub = installFetch({ answerDeltas: [`__REFUSE__ ${PROMPT_STIL_ZEILE} Call ${nummer}.`] });
    try {
      const res = await handleRequest(
        makeRequest({ message: BILD_STANDARD_EN, image_base64: FOTO, locale: "en" }, true),
      );
      const events = parseSse(await res.text());
      assertEquals(deltaTexte(events).length, 0, `${nummer}: kein delta`);
      const done = events[events.length - 1].data;
      assertEquals(done.reply, SELF_HARM_REPLY_EN, `${nummer}: Krisen-Katalogtext statt Dump`);
      assertEquals(done.refusal, true, `${nummer}: refusal`);
      assertEquals(stub.assistantRows()[0].content, SELF_HARM_REPLY_EN, `${nummer}: gespeicherter Text`);
    } finally {
      stub.restore();
    }
  }
});

Deno.test("EDGE-FUNCTIONS-1: ein gestreamter Prompt-Dump mit der Krisenregel bekommt den Leck-Text", async () => {
  // The CRISIS RULE carries the helpline, so a dump that reaches it used to
  // end as crisis signposting for someone who asked for the prompt (W1).
  const erfasst = installFetch();
  let prompt: string;
  try {
    await (await handleRequest(makeRequest({ message: FRAGE }, true))).text();
    prompt = String((erfasst.answerBodies()[0].system as JsonRecord[])[0].text);
  } finally {
    erfasst.restore();
  }
  assert(prompt.includes("0800 111 0 111"), "der Prompt traegt die Nummer");
  const dumps = [
    { was: "ganzer Prompt", text: prompt },
    {
      was: "WHAT YOU DO NOT DO bis CRISIS RULE",
      text: prompt.slice(prompt.indexOf("WHAT YOU DO NOT DO"), prompt.indexOf("\nSTYLE:")),
    },
  ];
  for (const { was, text } of dumps) {
    for (const { locale, expected } of [
      { locale: "de", expected: PROMPT_LEAK_REPLY },
      { locale: "en", expected: PROMPT_LEAK_REPLY_EN },
    ]) {
      // Line by line, the way a model recites.
      const stub = installFetch({ answerDeltas: text.split("\n").map((zeile) => `${zeile}\n`) });
      try {
        const res = await handleRequest(makeRequest({ message: FRAGE, locale }, true));
        const events = parseSse(await res.text());
        assertEquals(deltaTexte(events).length, 0, `${was}, ${locale}: kein delta`);
        const done = events[events.length - 1].data;
        assertEquals(done.reply, expected, `${was}, ${locale}: Leck-Text statt Krisentext`);
        assertEquals(done.refusal, true, `${was}, ${locale}: refusal`);
        assertEquals(stub.assistantRows()[0].content, expected, `${was}, ${locale}: gespeicherter Text`);
      } finally {
        stub.restore();
      }
    }
  }
});

// ---------------------------------------------------------------------------
// 9) F2 — das error-Event bringt seinen eigenen Fehlertyp mit
//
// Ein Fehler-Frame mitten im Stream war pauschal eine 502; damit war
// isClientFaultFailure() fuer gestreamte Ausfaelle unerreichbar, und eine vom
// Client verursachte 4xx bekam den Slot zurueck, den der gepufferte Pfad
// verbraucht laesst. Der Fehlertyp wird auf seinen HTTP-Status abgebildet;
// vertraut wird nur die Allowlist {400,413,415,422}, und auch die nur, wenn
// ein Foto mitlief: jeden Text prueft der Server selbst, also ist ein
// Eingabefehler auf einem reinen Text-Call unser Fehler. 403
// (permission_error) ist seit dem Wechsel auf Claude UNSER Ausfall.
// ---------------------------------------------------------------------------

/** Ein error-Event ohne Fehlertyp oder ganz ohne error-Objekt. */
function fehlerEventRoh(error: unknown): string {
  return claudeEvent({ type: "error", ...(error === undefined ? {} : { error }) });
}

Deno.test("F2: der Fehlertyp des error-Events entscheidet ueber die Erstattung", async () => {
  const faelle: { event: string; refund: boolean; was: string }[] = [
    { event: fehlerEvent("invalid_request_error"), refund: false, was: "invalid_request_error (400) ist Client-Schuld" },
    { event: fehlerEvent("request_too_large"), refund: false, was: "request_too_large (413) ist Client-Schuld" },
    { event: fehlerEvent("permission_error"), refund: true, was: "permission_error (403) ist unser Key" },
    { event: fehlerEvent("authentication_error"), refund: true, was: "authentication_error (401) ist unser Key" },
    { event: fehlerEvent("billing_error"), refund: true, was: "billing_error (402) ist unser Kredit" },
    { event: fehlerEvent("not_found_error"), refund: true, was: "not_found_error (404) ist unser Modellname" },
    { event: fehlerEvent("rate_limit_error"), refund: true, was: "rate_limit_error (429) ist unsere Drossel" },
    { event: fehlerEvent("api_error"), refund: true, was: "api_error (500) ist ein Ausfall" },
    { event: fehlerEvent("overloaded_error"), refund: true, was: "overloaded_error (529) ist ein Ausfall" },
    { event: fehlerEvent("rate_limit"), refund: true, was: "ein unbekannter Typ beweist nichts" },
    { event: fehlerEventRoh({ type: 400, message: "x" }), refund: true, was: "ein Nicht-String-Typ beweist nichts" },
    { event: fehlerEventRoh({ message: "x" }), refund: true, was: "ohne Typ bleibt es die 502" },
    { event: fehlerEventRoh(undefined), refund: true, was: "ohne error-Objekt bleibt es die 502" },
  ];
  for (const fall of faelle) for (const mitFoto of [true, false]) {
    // Erst ein Delta ueber die Kopfpruefung (10 Zeichen), aber unter dem
    // Riegel: der Kopf ist durch, die SSE-Header sind raus, und trotzdem ging
    // noch kein delta raus — genau die Stelle, an der die Erstattungsregel
    // haengt.
    const refund = fall.refund || !mitFoto;
    const was = `${fall.was}, ${mitFoto ? "mit" : "ohne"} Foto`;
    const stub = installFetch({
      answerChunks: [...KOPF, textDelta("Klar, gerne."), fall.event],
    });
    try {
      const res = await handleRequest(makeRequest({ message: FRAGE, ...(mitFoto ? { image_base64: FOTO } : {}) }, true));
      assertEquals(res.status, 200, `Status (${was})`);
      const events = parseSse(await res.text());
      assertEquals(deltaTexte(events).length, 0, `kein delta (${was})`);
      assertEquals(
        events[events.length - 1].data.error,
        "provider_error",
        `Fehlercode (${was})`,
      );
      assertEquals(
        stub.callsTo("refund_chat_quota").length,
        refund ? 1 : 0,
        `Erstattung (${was})`,
      );
      assertEquals(stub.quotaUsed(), refund ? 0 : 1, `Ledger (${was})`);
    } finally {
      stub.restore();
    }
  }
});

Deno.test("F2: ein Fehler-Frame VOR dem Kopf bleibt eine ehrliche 502 ohne Erstattung", async () => {
  // Noch kein SSE-Header raus, also darf der Status ehrlich sein — und ein
  // Client-Fehler auf einem Foto kostet den Slot, exakt wie im gepufferten Pfad.
  const stub = installFetch({ answerChunks: [...KOPF, fehlerEvent("invalid_request_error")] });
  try {
    const res = await handleRequest(makeRequest({ message: FRAGE, image_base64: FOTO }, true));
    assertEquals(res.status, 502, "Status");
    assertEquals(res.headers.get("content-type"), "application/json; charset=utf-8", "Content-Type");
    assertEquals((await res.json() as JsonRecord).error, "provider_error", "Fehlercode");
    assertEquals(stub.callsTo("refund_chat_quota").length, 0, "kein Refund");
    assertEquals(stub.quotaUsed(), 1, "der Slot bleibt verbraucht");
  } finally {
    stub.restore();
  }
});

Deno.test("Claude: overloaded_error erstattet, invalid_request_error nur mit Foto nicht — vor und nach dem Kopf", async () => {
  // Ueberlast ist der haeufigste Fehler mitten im Stream und UNSER Ausfall;
  // ein abgelehntes Foto hat die Eingabe des Nutzers bezahlt verbrannt, ein
  // abgelehnter reiner Text-Request dagegen unsere Anfrage.
  for (const { typ, mitFoto, refund } of [
    { typ: "overloaded_error", mitFoto: true, refund: true },
    { typ: "invalid_request_error", mitFoto: true, refund: false },
    { typ: "invalid_request_error", mitFoto: false, refund: true },
  ]) {
    for (const nachDemKopf of [false, true]) {
      const was = `${typ}, ${mitFoto ? "mit" : "ohne"} Foto, ${nachDemKopf ? "nach" : "vor"} dem Kopf`;
      const stub = installFetch({
        answerChunks: [...KOPF, ...(nachDemKopf ? [textDelta(LANGER_TEXT_A)] : []), fehlerEvent(typ)],
      });
      try {
        const res = await handleRequest(makeRequest({ message: FRAGE, ...(mitFoto ? { image_base64: FOTO } : {}) }, true));
        let fehler: unknown;
        if (nachDemKopf) {
          assertEquals(res.status, 200, `${was}: SSE-Status festgenagelt`);
          const events = parseSse(await res.text());
          assertEquals(deltaTexte(events).length, 0, `${was}: kein delta`);
          assertEquals(events[events.length - 1].event, "error", `${was}: letztes Event`);
          fehler = events[events.length - 1].data.error;
        } else {
          assertEquals(res.status, 502, `${was}: ehrlicher Status`);
          fehler = (await res.json() as JsonRecord).error;
        }
        assertEquals(fehler, "provider_error", `${was}: Fehlercode`);
        assertEquals(stub.callsTo("refund_chat_quota").length, refund ? 1 : 0, `${was}: Erstattung`);
        assertEquals(stub.quotaUsed(), refund ? 0 : 1, `${was}: Ledger`);
        assertEquals(stub.assistantRows().length, 0, `${was}: nichts gespeichert`);
      } finally {
        stub.restore();
      }
    }
  }
});

// ---------------------------------------------------------------------------
// 10) Was der Vertrag verspricht, aber bisher niemand festgehalten hat
//
// Aus dem Test-Review: die folgenden Zusicherungen liessen sich mutieren, ohne
// dass ein einziger Test rot wurde. Alle sechs Muster haben eines gemeinsam —
// sie haengen an der SSE-Antwort, waehrend die gleichwertige Zusicherung im
// gepufferten Pfad laengst gepinnt war.
// ---------------------------------------------------------------------------

Deno.test("A3/§5: der ERFOLGREICHE Stream erstattet nie und gibt den Anbieter frei", async () => {
  // Ein `refund()` vor dem done-Event machte jede gestreamte Antwort gratis,
  // ohne dass ein Test es merkte: alle Erstattungs-Zusicherungen sassen auf
  // scheiternden Streams. Und der Reader-Release am Ende der Pumpe war
  // ebenfalls unbeobachtet — eine offene Anbieter-Verbindung sieht man nicht.
  // Das Tor bleibt OFFEN stehen: nur ein Anbieter-Stream, der noch nicht von
  // selbst geschlossen hat, kann ueberhaupt freigegeben werden — bei einem
  // geschlossenen ist cancel() laut Spec ein No-op und beweist nichts.
  const stub = installFetch({
    answerChunks: antwort([LANGER_TEXT_A, LANGER_TEXT_B]),
    answerEnde: "tor",
    answerTor: new Promise<void>(() => {}),
  });
  try {
    const res = await handleRequest(makeRequest({ message: FRAGE }, true));
    const events = parseSse(await res.text());
    assertEquals(events[events.length - 1].event, "done", "letztes Event");
    assertEquals(stub.callsTo("refund_chat_quota").length, 0, "keine Erstattung");
    assertEquals(stub.quotaUsed(), 1, "der Slot bleibt verbraucht");
    assert(stub.providerCancelled(), "der Anbieter-Reader wurde nicht freigegeben");
  } finally {
    stub.restore();
  }
});

// COACH-4: a client that hangs up before approval no longer aborts the
// provider. The answer is read to its end, judged, stored once and never
// refunded; nothing reaches the dead wire. These replace the #90 tests that
// pinned the old abort.

/** Opens a gate that holds the provider mid-answer. */
function tor(): { gate: Promise<void>; open: () => void } {
  let open: () => void = () => {};
  const gate = new Promise<void>((resolve) => { open = resolve; });
  return { gate, open };
}

Deno.test("COACH-4: a cancel after meta, before approval, reads the provider to the end and stores the answer once", async () => {
  const halt = tor();
  const edge = installEdgeRuntime();
  const stub = installFetch({
    answerChunks: antwort([LANGER_TEXT_A, LANGER_TEXT_B]),
    answerHalt: { before: KOPF.length + 1, gate: halt.gate },
  });
  try {
    const res = await handleRequest(makeRequest({ message: FRAGE }, true));
    const reader = res.body!.getReader();
    assertEquals(deltaTexte(parseSse(await liesBis(reader, "event: meta"))).length, 0, "no delta before approval");
    await reader.cancel();
    assert(!stub.providerAborted(), "the disconnect must not abort the provider");
    assert(!stub.providerCancelled(), "the provider reader stays open");
    assertEquals(stub.assistantRows().length, 0, "nothing stored before the provider finished");
    // [handler, pump]: the pump is what outlives the response.
    assertEquals(edge.registered.length, 2, "handler and pump are both kept alive");
    let rowsWhenPumpSettled = -1;
    void edge.registered[1].then(() => { rowsWhenPumpSettled = stub.assistantRows().length; });
    halt.open();
    await edge.settled();
    assertEquals(rowsWhenPumpSettled, 1, "the kept-alive pump covers the store");
    const rows = stub.assistantRows();
    assertEquals(rows.length, 1, "stored exactly once");
    assertEquals(rows[0].content, LANGER_TEXT_A + LANGER_TEXT_B, "the whole approved answer");
    assertEquals(stub.callsTo("touch_chat_session").length, 1, "one session touch");
    assertEquals(stub.callsTo("refund_chat_quota").length, 0, "no refund: the slot bought a stored answer");
    assertEquals(stub.quotaUsed(), 1, "slot spent");
    // Same row shape as the buffered path writes for the same answer.
    const gepuffert = installFetch({ answerContent: LANGER_TEXT_A + LANGER_TEXT_B });
    try {
      await (await handleRequest(makeRequest({ message: FRAGE }, false))).json();
      assertEquals(JSON.stringify(rows[0]), JSON.stringify(gepuffert.assistantRows()[0]), "identical to the buffered row");
    } finally { gepuffert.restore(); }
  } finally { halt.open(); stub.restore(); edge.restore(); }
});

for (const phase of ["before the SSE head", "during approval"] as const) {
  Deno.test(`COACH-4: request abort ${phase} keeps the provider going, sends no byte and stores the answer once`, async () => {
    const halt = tor();
    const edge = installEdgeRuntime();
    const stub = installFetch({
      answerChunks: antwort([LANGER_TEXT_A, LANGER_TEXT_B]),
      answerHalt: { before: phase === "before the SSE head" ? 0 : KOPF.length + 1, gate: halt.gate },
    });
    const abort = new AbortController();
    let pending: Promise<Response> | undefined;
    try {
      pending = handleRequest(makeRequest({ message: FRAGE }, true, abort.signal));
      assertEquals(edge.registered.length, 1, "the handler is kept alive from the start");
      let rest: string;
      if (phase === "before the SSE head") {
        await warteBis(() => stub.answerBodies().length > 0);
        abort.abort();
        assert(!stub.providerAborted(), "the disconnect must not abort the provider");
        halt.open();
        rest = await (await pending).text();
      } else {
        const reader = (await pending).body!.getReader();
        await liesBis(reader, "event: meta");
        abort.abort();
        assert(!stub.providerAborted(), "the disconnect must not abort the provider");
        halt.open();
        rest = await liesRest(reader);
      }
      assertEquals(rest, "", "not one byte after the disconnect");
      await edge.settled();
      const rows = stub.assistantRows();
      assertEquals(rows.length, 1, "stored exactly once");
      assertEquals(rows[0].content, LANGER_TEXT_A + LANGER_TEXT_B, "the whole approved answer");
      assertEquals(rows[0].refusal, false, "an ordinary answer");
      assertEquals(stub.callsTo("refund_chat_quota").length, 0, "no refund");
      assertEquals(stub.quotaUsed(), 1, "slot spent");
    } finally {
      halt.open();
      // Let the handler finish against the stub, whatever the verdict.
      await pending?.catch(() => {});
      stub.restore();
      edge.restore();
    }
  });
}

Deno.test("A3: message_stop beendet den Stream, statt am Anbieter haengen zu bleiben", async () => {
  // Ohne die message_stop-Behandlung liefe die Pumpe weiter, bis der Anbieter
  // von sich aus schliesst — live haelt das die Verbindung offen. Hier stockt
  // der Anbieter nach message_stop absichtlich: wer das Event ignoriert, laeuft
  // in die Frist und schickt ein error-Event statt done.
  await mitKurzerFrist(300, async () => {
    const stub = installFetch({
      answerChunks: antwort([LANGER_TEXT_A + LANGER_TEXT_B]),
      answerEnde: "stall",
    });
    try {
      const res = await handleRequest(makeRequest({ message: FRAGE }, true));
      const events = parseSse(await res.text());
      assertEquals(events[events.length - 1].event, "done", "letztes Event");
      assertEquals(
        events[events.length - 1].data.reply,
        LANGER_TEXT_A + LANGER_TEXT_B,
        "der ganze Text",
      );
    } finally {
      stub.restore();
    }
  });
});

Deno.test("A3: beide SSE-Antworten tragen den Riegel gegen puffernde Zwischenstellen", async () => {
  // X-Accel-Buffering: no ist der einzige Header, der eine Zwischenstelle
  // davon abhaelt, den ganzen Body zu sammeln — und damit das Streamen still
  // rueckgaengig zu machen.
  const gestreamt = installFetch({ answerDeltas: [LANGER_TEXT_A, LANGER_TEXT_B] });
  try {
    const res = await handleRequest(makeRequest({ message: FRAGE }, true));
    assertEquals(res.headers.get("X-Accel-Buffering"), "no", "gestreamte Antwort");
    await res.text();
  } finally {
    gestreamt.restore();
  }
  const nurDone = installFetch({ answerDeltas: ["__REFUSE__ Nicht mein Thema."] });
  try {
    const res = await handleRequest(makeRequest({ message: FRAGE }, true));
    assertEquals(res.headers.get("X-Accel-Buffering"), "no", "done-only-Antwort");
    await res.text();
  } finally {
    nurDone.restore();
  }
});

Deno.test("A3: auch die Refusal ohne deltas gibt den Anbieter-Reader frei", async () => {
  const stub = installFetch({
    answerChunks: antwort(["__REFUSE__ Nicht mein Thema."]),
    answerEnde: "tor",
    answerTor: new Promise<void>(() => {}),
  });
  try {
    const res = await handleRequest(makeRequest({ message: FRAGE }, true));
    await res.text();
    assert(stub.providerCancelled(), "der Anbieter-Reader wurde nicht freigegeben");
  } finally {
    stub.restore();
  }
});

Deno.test("L4: scheitert der Kopf, wird der Anbieter-Reader trotzdem freigegeben", async () => {
  // Der Pfad, der ohnehin schon schiefgegangen ist, hielt die Verbindung als
  // einziger offen: nur die done-only-Abzweigung und die Pumpe raeumten auf.
  const stub = installFetch({
    answerChunks: [...KOPF, fehlerEvent("api_error")],
    answerEnde: "tor",
    answerTor: new Promise<void>(() => {}),
  });
  try {
    const res = await handleRequest(makeRequest({ message: FRAGE }, true));
    assertEquals(res.status, 502, "Status");
    assert(stub.providerCancelled(), "der Anbieter-Reader wurde nicht freigegeben");
    // Und das Urteil bleibt, was es war: Ausfall -> Slot zurueck.
    assertEquals(stub.callsTo("refund_chat_quota").length, 1, "Erstattung");
    assertEquals(stub.quotaUsed(), 0, "Ledger");
  } finally {
    stub.restore();
  }
});

Deno.test("Security S01: filtered answers never leave JSON or SSE and never enter accepted history", async () => {
  for (const stream of [false, true]) {
    for (const content of ["", "Synthetic provider-filtered audit answer. ".repeat(8)]) {
      const stub = installFetch({ answerContent: content, answerDeltas: [content], answerFinishReason: "content_filter" });
      try {
        const response = await handleRequest(makeRequest({ message: FRAGE }, stream));
        assertEquals(response.status, 200, "safe refusal response");
        const events = stream ? parseSse(await response.text()) : [];
        const result = stream ? events[events.length - 1].data : await response.json();
        assertEquals(result.refusal, true, "provider safety refusal preserved");
        assertEquals(result.reply, PROVIDER_REFUSAL_REPLY, "signposting catalogue text");
        assertEquals(deltaTexte(events).length, 0, "no rejected text leaves as deltas");
        assertEquals(stub.assistantRows().filter(row => row.refusal === false).length, 0, "no accepted assistant row");
        assertEquals(stub.callsTo("refund_chat_quota").length, 0, "paid safety refusal is not refunded");
      } finally { stub.restore(); }
    }
  }
});

Deno.test("Security S06: expanded whitespace cannot leak a prompt prefix before final refusal", async () => {
  const words = [...PROMPT_LEAK_GUARD.shingles][0].split(" ");
  const stub = installFetch({ answerChunks: antwort(words.map(word => word + " ".repeat(100))) });
  try {
    const response = await handleRequest(makeRequest({ message: FRAGE }, true));
    const events = parseSse(await response.text());
    assertEquals(deltaTexte(events).join(""), "", "no prompt prefix released");
    assertEquals(events[events.length - 1].data.refusal, true, "safe final refusal");
    assertEquals(stub.assistantRows()[0].refusal, true, "history keeps only refusal");
    assertEquals(stub.callsTo("refund_chat_quota").length, 0, "safety refusal remains charged");
  } finally { stub.restore(); }
});

Deno.test("Security: oversized provider stream is bounded before any text is released", async () => {
  const chunk = "Synthetic bounded response. ".repeat(6000);
  const stub = installFetch({ answerChunks: antwort([chunk, chunk, chunk, chunk]) });
  try {
    const response = await handleRequest(makeRequest({ message: FRAGE }, true));
    const events = parseSse(await response.text());
    assertEquals(deltaTexte(events).length, 0, "oversized answer remains internal");
    assertEquals(events[events.length - 1].data.error, "provider_error", "bounded failure");
    assertEquals(stub.callsTo("refund_chat_quota").length, 1, "one refund");
    assertEquals(stub.assistantRows().length, 0, "no unapproved history");
  } finally { stub.restore(); }
});

Deno.test("Security: missing completion sentinel never releases an incomplete answer", async () => {
  // end_turn arrived, message_stop did not: the stream closed early.
  const stub = installFetch({ answerChunks: [...KOPF, textDelta(LANGER_TEXT_A + LANGER_TEXT_B), ...ende("stop")] });
  try {
    const response = await handleRequest(makeRequest({ message: FRAGE }, true));
    const events = parseSse(await response.text());
    assertEquals(deltaTexte(events).length, 0, "no incomplete text");
    assertEquals(events[events.length - 1].data.error, "provider_error", "missing completion fails closed");
    assertEquals(stub.callsTo("refund_chat_quota").length, 1, "outage refunded");
  } finally { stub.restore(); }
});

Deno.test("Security: completion metadata must explicitly approve an answer", async () => {
  // "unexpected" and "error" pass through as unknown stop reasons; tool_calls
  // and pause_turn are real Claude stop reasons that are no finished answer.
  for (const reason of [null, "unexpected", "tool_calls", "error", "pause_turn"]) {
    const stub = installFetch({ answerChunks: antwort([LANGER_TEXT_A + LANGER_TEXT_B], reason) });
    try {
      const response = await handleRequest(makeRequest({ message: FRAGE }, true));
      const events = parseSse(await response.text());
      assertEquals(deltaTexte(events).length, 0, "unapproved completion never publishes");
      assertEquals(events[events.length - 1].data.error, "provider_error", "unknown or failed completion is an outage");
      assertEquals(stub.assistantRows().length, 0, "no accepted history");
      assertEquals(stub.callsTo("refund_chat_quota").length, 1, "one outage refund");
    } finally { stub.restore(); }
  }
});

Deno.test("Security: malformed provider data cannot hide a safety decision", async () => {
  const stub = installFetch({
    answerChunks: [
      ...KOPF,
      textDelta(LANGER_TEXT_A + LANGER_TEXT_B),
      "event: content_block_delta\ndata: {invalid\n\n",
      ...abschluss("stop"),
    ],
  });
  try {
    const response = await handleRequest(makeRequest({ message: FRAGE }, true));
    const events = parseSse(await response.text());
    assertEquals(deltaTexte(events).length, 0, "incomplete safety metadata fails closed");
    assertEquals(events[events.length - 1].data.error, "provider_error", "invalid frame is an outage");
    assertEquals(stub.assistantRows().length, 0, "no accepted history");
  } finally { stub.restore(); }
});

Deno.test("Security: a provider safety rejection remains final before later failure", async () => {
  // stop_reason refusal, then an outage event that must never be read.
  const stub = installFetch({
    answerChunks: [...KOPF, textDelta(LANGER_TEXT_A), ...ende("content_filter"), fehlerEvent("api_error")],
    answerEnde: "stall",
  });
  try {
    const response = await handleRequest(makeRequest({ message: FRAGE }, true));
    const events = parseSse(await response.text());
    assertEquals(deltaTexte(events).length, 0, "no rejected text");
    assertEquals(events[events.length - 1].data.refusal, true, "safety refusal is final");
    assertEquals(stub.callsTo("refund_chat_quota").length, 0, "paid rejection never becomes a free retry");
    assert(stub.providerCancelled(), "provider reader is cancelled after rejection");
  } finally { stub.restore(); }
});

Deno.test("Security: approved SSE chunks preserve supplementary Unicode", async () => {
  const content = "a".repeat(63) + String.fromCodePoint(0x1f34e) + " Approved fruit suggestion.";
  const stub = installFetch({ answerDeltas: [content] });
  try {
    const response = await handleRequest(makeRequest({ message: FRAGE }, true));
    const events = parseSse(await response.text());
    for (const chunk of deltaTexte(events)) {
      assert(!/[\uD800-\uDBFF]$/.test(chunk), "no trailing high surrogate");
      assert(!/^[\uDC00-\uDFFF]/.test(chunk), "no leading low surrogate");
    }
    assertEquals(deltaTexte(events).join(""), content, "approved text remains identical");
  } finally { stub.restore(); }
});

Deno.test("Security completion: JSON requires valid terminal metadata", async () => {
  for (const reason of [null, "unexpected", "tool_calls", "error", "pause_turn"]) {
    const stub = installFetch({ answerContent: "Synthetic valid-looking answer", answerFinishReason: reason });
    try {
      const response = await handleRequest(makeRequest({ message: FRAGE }, false));
      assertEquals(response.status, 502, "invalid completion is not a successful answer");
      assertEquals(stub.assistantRows().length, 0, "no unapproved history");
      assertEquals(stub.callsTo("refund_chat_quota").length, 1, "outage refunded once");
    } finally { stub.restore(); }
  }
});

// COACH-4: what happens after a disconnect when the provider fails or the
// verdict blocks is what a connected request gets, minus the refund (a client
// abort never refunds, unchanged) and minus every byte on the wire.
const NACH_ABBRUCH_FEHLER: Array<{ name: string; chunks: string[]; ende: StreamEnde }> = [
  { name: "provider error", chunks: [...KOPF, textDelta(LANGER_TEXT_A)], ende: "fail" },
  { name: "provider timeout", chunks: [...KOPF, textDelta(LANGER_TEXT_A)], ende: "stall" },
  { name: "invalid completion", chunks: antwort([LANGER_TEXT_A, LANGER_TEXT_B], "tool_calls"), ende: "close" },
];

for (const fall of NACH_ABBRUCH_FEHLER) {
  Deno.test(`COACH-4: ${fall.name} after a disconnect stores nothing and refunds nothing, as before`, async () => {
    await mitKurzerFrist(150, async () => {
      const halt = tor();
      const edge = installEdgeRuntime();
      const stub = installFetch({
        answerChunks: fall.chunks,
        answerEnde: fall.ende,
        answerHalt: { before: KOPF.length + 1, gate: halt.gate },
      });
      const logs: string[] = [];
      const originalError = console.error;
      console.error = (...args: unknown[]) => { logs.push(args.map(String).join(" ")); };
      const abort = new AbortController();
      try {
        const reader = (await handleRequest(makeRequest({ message: FRAGE }, true, abort.signal))).body!.getReader();
        await liesBis(reader, "event: meta");
        abort.abort();
        halt.open();
        assertEquals(await liesRest(reader), "", "not one byte after the disconnect");
        await edge.settled();
        assertEquals(stub.assistantRows().length, 0, "no unapproved history");
        assertEquals(stub.callsTo("refund_chat_quota").length, 0, "a client abort never refunds");
        assertEquals(stub.quotaUsed(), 1, "slot spent");
        const log = logs.filter((line) => line.startsWith("answer stream failed"));
        assertEquals(log.length, 1, "a real provider failure is logged once");
        assert(!log[0].includes(LANGER_TEXT_A.slice(0, 20)), "the log carries no answer text");
      } finally { console.error = originalError; halt.open(); stub.restore(); edge.restore(); }
    });
  });
}

const NACH_ABBRUCH_URTEIL: Array<{ name: string; chunks: string[]; reply: string }> = [
  {
    name: "provider safety filter",
    chunks: [...KOPF, textDelta(LANGER_TEXT_A), ...abschluss("content_filter")],
    reply: PROVIDER_REFUSAL_REPLY,
  },
  {
    name: "prompt leak",
    chunks: antwort([LANGER_TEXT_A, " " + [...PROMPT_LEAK_GUARD.shingles][0]]),
    reply: PROMPT_LEAK_REPLY,
  },
];

for (const fall of NACH_ABBRUCH_URTEIL) {
  Deno.test(`COACH-4: a ${fall.name} verdict after a disconnect stores the refusal, never the text`, async () => {
    const halt = tor();
    const edge = installEdgeRuntime();
    const stub = installFetch({
      answerChunks: fall.chunks,
      answerHalt: { before: KOPF.length + 1, gate: halt.gate },
    });
    const abort = new AbortController();
    try {
      const reader = (await handleRequest(makeRequest({ message: FRAGE }, true, abort.signal))).body!.getReader();
      await liesBis(reader, "event: meta");
      abort.abort();
      halt.open();
      assertEquals(await liesRest(reader), "", "not one byte after the disconnect");
      await edge.settled();
      const rows = stub.assistantRows();
      assertEquals(rows.length, 1, "one refusal row, as for a connected client");
      assertEquals(rows[0].refusal, true, "a refusal");
      assertEquals(rows[0].refusal_reason, "model_refusal", "same reason as connected");
      assertEquals(rows[0].content, fall.reply, "the catalogue text, never the blocked answer");
      assertEquals(stub.callsTo("refund_chat_quota").length, 0, "a paid refusal is not refunded");
    } finally { halt.open(); stub.restore(); edge.restore(); }
  });
}

// ---------------------------------------------------------------------------
// 11) Messages-API-Eigenheiten: Denkbloecke, stop_reason refusal und ein
//     Stream ohne message_stop
// ---------------------------------------------------------------------------

const GEDANKE = "PRIVATER_GEDANKE: Nutzer wiegt 80 kg, also rechne ich";
const GEDANKE_2 = "PRIVATE_FORTSCHRITTSNOTIZ zwischen zwei Textbloecken";
const SIGNATUR = "PRIVATE_SIGNATUR_c2lnbmF0dXI";

Deno.test("Claude: Denk- und Signatur-Deltas erreichen weder delta noch done noch Historie", async () => {
  // Unter display "omitted" ist der Denktext leer; mit "summarized" oder
  // "updates" traegt er Text, auch als Notiz ZWISCHEN zwei Textbloecken. Nur
  // text_delta ist Antworttext.
  const block = (index: number, type: "thinking" | "text") =>
    claudeEvent({
      type: "content_block_start",
      index,
      content_block: type === "thinking" ? { type, thinking: "", signature: "" } : { type, text: "" },
    });
  const stop = (index: number) => claudeEvent({ type: "content_block_stop", index });
  const textIn = (index: number, t: string) =>
    claudeEvent({ type: "content_block_delta", index, delta: { type: "text_delta", text: t } });
  const stub = installFetch({
    answerChunks: [
      KOPF[0],
      block(0, "thinking"),
      denkDelta(0, GEDANKE),
      denkDelta(0, " und noch ein Gedanke"),
      signaturDelta(0, SIGNATUR),
      stop(0),
      block(1, "text"),
      textIn(1, LANGER_TEXT_A),
      stop(1),
      block(2, "thinking"),
      denkDelta(2, GEDANKE_2),
      signaturDelta(2, SIGNATUR),
      stop(2),
      block(3, "text"),
      textIn(3, LANGER_TEXT_B),
      stop(3),
      ...abschluss("stop").slice(1),
    ],
  });
  try {
    const res = await handleRequest(makeRequest({ message: FRAGE }, true));
    const roh = await res.text();
    const events = parseSse(roh);
    assertEquals(events[events.length - 1].event, "done", "letztes Event");
    assertEquals(deltaTexte(events).join(""), LANGER_TEXT_A + LANGER_TEXT_B, "deltas nur aus text_delta");
    const done = events[events.length - 1].data;
    assertEquals(done.reply, LANGER_TEXT_A + LANGER_TEXT_B, "done.reply nur aus text_delta");
    assertEquals(done.refusal, false, "keine Refusal");
    assertEquals(stub.assistantRows()[0].content, LANGER_TEXT_A + LANGER_TEXT_B, "gespeicherte Antwort");
    for (const privat of ["PRIVATER_GEDANKE", "PRIVATE_FORTSCHRITTSNOTIZ", "noch ein Gedanke", SIGNATUR]) {
      assert(!roh.includes(privat), `${privat} auf der Leitung`);
      assert(!JSON.stringify(stub.assistantRows()).includes(privat), `${privat} in der Historie`);
    }
  } finally {
    stub.restore();
  }
  // Der gepufferte Pfad liest dieselben Bloecke aus content[].
  const gepuffert = installFetch({
    answerEnvelope: {
      ...claudeResponse(""),
      content: [
        { type: "thinking", thinking: GEDANKE, signature: SIGNATUR },
        { type: "text", text: LANGER_TEXT_A },
        { type: "thinking", thinking: GEDANKE_2, signature: SIGNATUR },
        { type: "text", text: LANGER_TEXT_B },
      ],
    },
  });
  try {
    const res = await handleRequest(makeRequest({ message: FRAGE }));
    const roh = await res.text();
    assertEquals((JSON.parse(roh) as JsonRecord).reply, LANGER_TEXT_A + LANGER_TEXT_B, "gepufferte Antwort");
    for (const privat of ["PRIVATER_GEDANKE", "PRIVATE_FORTSCHRITTSNOTIZ", SIGNATUR]) {
      assert(!roh.includes(privat), `${privat} im JSON`);
      assert(!JSON.stringify(gepuffert.assistantRows()).includes(privat), `${privat} in der Historie (JSON)`);
    }
  } finally {
    gepuffert.restore();
  }
});

Deno.test("Claude: stop_reason refusal liefert den lokalisierten Katalogtext ohne ein delta", async () => {
  // Die Sicherheitsklassifikatoren des Anbieters lehnen per stop_reason ab,
  // mitunter nach Text. Nichts davon darf raus, der Slot bleibt bezahlt.
  // COACH-2: nothing is known about the declined content, so the text is the
  // classifier's provider_refusal text with the helpline. For a photo the
  // answer call is the only stage that saw it.
  const faelle = [
    { locale: "de", katalog: PROVIDER_REFUSAL_REPLY, bild: "Analysiere dieses Bild im Fitness-Kontext." },
    { locale: "en", katalog: PROVIDER_REFUSAL_REPLY_EN, bild: BILD_STANDARD_EN },
  ];
  for (const { locale, katalog, bild } of faelle) {
    for (const mitText of [false, true]) {
      for (const mitFoto of [false, true]) {
        const was = `${locale}, ${mitText ? "nach Text" : "ohne Text"}, ${mitFoto ? "Foto" : "nur Text"}`;
        const stub = installFetch({
          answerChunks: [...KOPF, ...(mitText ? [textDelta(LANGER_TEXT_A)] : []), ...abschluss("content_filter")],
        });
        try {
          const payload = mitFoto ? { message: bild, image_base64: FOTO, locale } : { message: FRAGE, locale };
          const res = await handleRequest(makeRequest(payload, true));
          assertEquals(res.status, 200, `${was}: Status`);
          const roh = await res.text();
          const events = parseSse(roh);
          assertEquals(events.map((e) => e.event).join(","), "meta,done", `${was}: nur meta und done`);
          const done = events[1].data;
          assertEquals(done.reply, katalog, `${was}: Katalogtext`);
          assert(String(done.reply).includes("0800 111 0 111"), `${was}: Hilfe-Nummer`);
          assertEquals(done.refusal, true, `${was}: refusal`);
          assertEquals(done.refusal_reason, "model_refusal", `${was}: refusal_reason`);
          assert(!roh.includes("Muskulatur"), `${was}: abgelehnter Text auf der Leitung`);
          const rows = stub.assistantRows();
          assertEquals(rows.length, 1, `${was}: eine Zeile`);
          assertEquals(rows[0].content, katalog, `${was}: gespeicherter Katalogtext`);
          assertEquals(rows[0].refusal, true, `${was}: gespeicherte Refusal`);
          assertEquals(stub.callsTo("refund_chat_quota").length, 0, `${was}: kein Refund`);
          assertEquals(stub.quotaUsed(), 1, `${was}: Slot bleibt verbraucht`);
        } finally {
          stub.restore();
        }
      }
    }
  }
});

Deno.test("Claude: ein Stream, der ohne message_stop schliesst, ist ein Anbieterfehler mit Refund", async () => {
  // message_stop ist das einzige Ende. Ohne es fehlt womoeglich der Rest der
  // Antwort oder eine spaete Sicherheitsentscheidung — nichts wird geliefert.
  const faelle: { was: string; chunks: string[]; vorDemKopf: boolean }[] = [
    { was: "nach message_start", chunks: [KOPF[0]], vorDemKopf: true },
    { was: "mitten im Textblock", chunks: [...KOPF, textDelta(LANGER_TEXT_A)], vorDemKopf: false },
    { was: "nach end_turn", chunks: [...KOPF, textDelta(LANGER_TEXT_A), ...ende("stop")], vorDemKopf: false },
  ];
  for (const fall of faelle) {
    const stub = installFetch({ answerChunks: fall.chunks, answerEnde: "close" });
    try {
      const res = await handleRequest(makeRequest({ message: FRAGE }, true));
      let fehler: unknown;
      if (fall.vorDemKopf) {
        assertEquals(res.status, 502, `${fall.was}: ehrlicher Status`);
        fehler = (await res.json() as JsonRecord).error;
      } else {
        assertEquals(res.status, 200, `${fall.was}: SSE-Status`);
        const events = parseSse(await res.text());
        assertEquals(deltaTexte(events).length, 0, `${fall.was}: kein delta`);
        assertEquals(events[events.length - 1].event, "error", `${fall.was}: letztes Event`);
        fehler = events[events.length - 1].data.error;
      }
      assertEquals(fehler, "provider_error", `${fall.was}: Fehlercode`);
      assertEquals(stub.callsTo("refund_chat_quota").length, 1, `${fall.was}: genau ein Refund`);
      assertEquals(stub.quotaUsed(), 0, `${fall.was}: Slot zurueck`);
      assertEquals(stub.assistantRows().length, 0, `${fall.was}: nichts gespeichert`);
    } finally {
      stub.restore();
    }
  }
});
