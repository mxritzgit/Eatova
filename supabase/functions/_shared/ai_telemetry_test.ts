// Tests for the ai_call telemetry line (ai_telemetry.ts).
//
// The line is an allowlist: a fixed key set whose values are enums, bounded
// integers, booleans or null. Content handed in through ANY field must not
// reach it (CWE-532), and telemetry must never throw into a request.

import { AiCallLog, aiAnswerOutcome, aiCallLine, aiOutcomeOf } from "./ai_telemetry.ts";
import type { AiCallMeta, AiFunction, AiOutcome, AiProvider, AiRoute } from "./ai_telemetry.ts";

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

function assertEquals(actual: unknown, expected: unknown, message: string): void {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(`${message}: erwartet ${JSON.stringify(expected)}, war ${JSON.stringify(actual)}`);
  }
}

const KEYS = [
  "event", "fn", "route", "provider", "model", "effort", "stream", "attempt", "outcome", "http_status",
  "latency_ms", "stop_reason", "input_tokens", "output_tokens", "cache_creation_input_tokens",
  "cache_read_input_tokens", "refunded",
];

const META: AiCallMeta = { route: "chat", provider: "anthropic", model: "claude-sonnet-5-5", effort: "high" };

/** Captures console.log while `run` executes. */
async function captureLog(run: () => void | Promise<void>): Promise<string[]> {
  const lines: string[] = [];
  const original = console.log;
  console.log = (...args: unknown[]) => lines.push(args.map(String).join(" "));
  try {
    await run();
  } finally {
    console.log = original;
  }
  return lines;
}

Deno.test("ai_call: a complete Claude call becomes exactly the allowlisted line", () => {
  const line = aiCallLine("coach-chat", { ...META, stream: true }, {
    outcome: "ok",
    httpStatus: 200,
    stopReason: "max_tokens",
    usage: { input_tokens: 12, output_tokens: 4096, cache_creation_input_tokens: 0, cache_read_input_tokens: 2048 },
  }, 1234.6, false);
  assertEquals(Object.keys(line), KEYS, "Schluessel und Reihenfolge");
  assertEquals(line, {
    event: "ai_call", fn: "coach-chat", route: "chat", provider: "anthropic", model: "claude-sonnet-5-5",
    effort: "high", stream: true, attempt: 1, outcome: "ok", http_status: 200, latency_ms: 1235,
    stop_reason: "max_tokens", input_tokens: 12, output_tokens: 4096, cache_creation_input_tokens: 0,
    cache_read_input_tokens: 2048, refunded: false,
  }, "Zeile");
});

Deno.test("ai_call: content in any input field never reaches the line", () => {
  const marker = "Diabetes Typ 2 seit 2019, Metformin";
  const line = aiCallLine(marker as AiFunction, {
    route: marker as AiRoute,
    provider: marker as AiProvider,
    model: marker,
    effort: marker,
    stream: marker as unknown as boolean,
    attempt: marker as unknown as number,
  }, {
    outcome: marker as AiOutcome,
    httpStatus: marker as unknown as number,
    stopReason: marker,
    usage: {
      input_tokens: marker,
      output_tokens: { text: marker },
      cache_read_input_tokens: [marker],
      [marker]: 7,
      prompt_tokens_details: { cached_tokens: marker },
    },
  }, Number.NaN, marker as unknown as boolean);
  const text = JSON.stringify(line);
  assert(!text.includes("Diabetes") && !text.includes("Metformin"), `Inhalt in der Zeile: ${text}`);
  assertEquals(Object.keys(line), KEYS, "kein zusaetzlicher Schluessel");
  assertEquals([line.fn, line.route, line.provider, line.model, line.effort, line.outcome, line.stop_reason],
    ["other", "other", "other", "other", "other", "other", "other"], "Fremdwerte werden zur Kategorie");
  assertEquals([line.stream, line.attempt, line.http_status, line.latency_ms, line.refunded],
    [false, 1, null, 0, false], "Fremdtypen fallen auf sichere Defaults");
  assertEquals([line.input_tokens, line.output_tokens, line.cache_creation_input_tokens, line.cache_read_input_tokens],
    [null, null, null, null], "keine Zaehler aus Fremdtypen");
});

Deno.test("ai_call: OpenAI-style usage maps onto the same counters; bad numbers become null", () => {
  const openRouter = aiCallLine("coach-chat", { route: "image", provider: "openrouter", model: "google/gemini-3.1-flash-image" }, {
    outcome: "ok", httpStatus: 200,
    usage: { prompt_tokens: 30, completion_tokens: 1290, prompt_tokens_details: { cached_tokens: 0 }, cost: 0.04 },
  }, 9000, false);
  assertEquals([openRouter.input_tokens, openRouter.output_tokens, openRouter.cache_read_input_tokens, openRouter.effort],
    [30, 1290, 0, null], "OpenRouter-Zaehler");
  for (const bad of [-1, 1.5, Number.POSITIVE_INFINITY, 1e12, "12"]) {
    assertEquals(aiCallLine("analyze-meal", META, { outcome: "ok", usage: { input_tokens: bad } }, 0, false).input_tokens,
      null, `ungueltig: ${String(bad)}`);
  }
  const bounds = aiCallLine("recipe-import", { ...META, attempt: 2 }, { outcome: "error", httpStatus: 99 }, 99_999_999, false);
  assertEquals([bounds.attempt, bounds.http_status, bounds.latency_ms], [2, null, 3_600_000], "Grenzen");
});

Deno.test("ai_call: outcomes from errors and stop reasons", () => {
  assertEquals(aiOutcomeOf(new DOMException("t", "TimeoutError")), "timeout", "Deadline");
  assertEquals(aiOutcomeOf(new DOMException("a", "AbortError")), "aborted", "Abbruch");
  assertEquals(aiOutcomeOf(new TypeError("network")), "error", "Rest");
  assertEquals(aiAnswerOutcome("refusal"), "refused", "Claude-Sicherheitsstopp");
  assertEquals(aiAnswerOutcome("content_filter"), "refused", "finish_reason-Vokabular");
  assertEquals(aiAnswerOutcome("end_turn"), "ok", "fertig");
  assertEquals(aiAnswerOutcome(undefined), "ok", "ohne stop_reason");
});

Deno.test("AiCallLog: one line per settled call, written as JSON on settle", async () => {
  const lines = await captureLog(() => {
    const log = new AiCallLog("analyze-meal");
    const call = log.start({ ...META, route: "analyze", effort: "medium" });
    call.settle({ outcome: "ok", httpStatus: 200, stopReason: "end_turn", usage: { input_tokens: 1, output_tokens: 2 } });
    call.settle({ outcome: "error", httpStatus: 500 });
    assert(call.settled, "settled");
  });
  assertEquals(lines.length, 1, "genau eine Zeile, auch bei doppeltem settle");
  const line = JSON.parse(lines[0]);
  assertEquals([line.event, line.fn, line.route, line.outcome, line.http_status], ["ai_call", "analyze-meal", "analyze", "ok", 200], "erste Abrechnung gilt");
});

Deno.test("AiCallLog: deferred lines wait for flush and carry the request's refund", async () => {
  const log = new AiCallLog("coach-chat", { deferUntilFlush: true });
  const early = await captureLog(() => {
    log.start({ ...META, route: "classifier" }).settle({ outcome: "ok", httpStatus: 200 });
    log.start(META).settle({ outcome: "error", httpStatus: 529 });
    log.markRefunded();
  });
  assertEquals(early.length, 0, "vor flush wird nichts geschrieben");
  const flushed = await captureLog(() => log.flush());
  assertEquals(flushed.map((line) => JSON.parse(line).refunded), [true, true], "beide Zeilen tragen die Erstattung");
  const late = await captureLog(() => log.start({ ...META, route: "image", provider: "openrouter" }).settle({ outcome: "ok" }));
  assertEquals(late.length, 1, "nach flush schreibt ein Aufruf sofort");
  const again = await captureLog(() => log.flush());
  assertEquals(again.length, 0, "keine Zeile doppelt");
});

Deno.test("AiCallLog: a hold keeps lines back until it is released, in either order", async () => {
  const log = new AiCallLog("coach-chat", { deferUntilFlush: true });
  const release = log.hold();
  const stream = log.start({ ...META, stream: true });
  const atFlush = await captureLog(() => log.flush());
  assertEquals(atFlush.length, 0, "Stream laeuft noch");
  const atRelease = await captureLog(() => {
    stream.settle({ outcome: "timeout" });
    log.markRefunded();
    release();
    release();
  });
  assertEquals(atRelease.length, 1, "nach dem Loslassen genau einmal");
  assertEquals(JSON.parse(atRelease[0]).refunded, true, "Erstattung nach dem Streamende");

  const other = new AiCallLog("coach-chat", { deferUntilFlush: true });
  const done = other.hold();
  other.start(META).settle({ outcome: "ok" });
  const releasedFirst = await captureLog(() => done());
  assertEquals(releasedFirst.length, 0, "ohne flush bleibt die Zeile liegen");
  assertEquals((await captureLog(() => other.flush())).length, 1, "flush schreibt sie");
});

Deno.test("AiCallLog: a failing logger never throws into the request", () => {
  const original = console.log;
  console.log = () => {
    throw new Error("logger down");
  };
  try {
    const log = new AiCallLog("recipe-import");
    log.start({ ...META, route: "import" }).settle({ outcome: "ok", usage: { get input_tokens(): number { throw new Error("getter"); } } });
    const deferred = new AiCallLog("coach-chat", { deferUntilFlush: true });
    deferred.start(META).settle({ outcome: "ok" });
    deferred.flush();
  } finally {
    console.log = original;
  }
});
