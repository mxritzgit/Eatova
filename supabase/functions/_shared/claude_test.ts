// Tests for the Messages API wire contract (claude.ts). Without external test
// dependencies, like the other files here.

import {
  cachedSystem,
  CLAUDE_MAX_IMAGE_EDGE_PX,
  claudeErrorStatus,
  claudeFailureStatus,
  claudeRequestBody,
  claudeText,
  effortFromEnv,
  finishReasonFromStop,
} from "./claude.ts";

function assert(condition: boolean, message: string): void {
  if (!condition) throw new Error(message);
}

function assertEquals(actual: unknown, expected: unknown, message: string): void {
  if (actual !== expected) {
    throw new Error(`${message}: erwartet ${JSON.stringify(expected)}, war ${JSON.stringify(actual)}`);
  }
}

Deno.test("stop_reason maps onto the handlers' finish_reason vocabulary", () => {
  assertEquals(finishReasonFromStop("end_turn"), "stop", "complete answer");
  assertEquals(finishReasonFromStop("stop_sequence"), "stop", "stop sequence");
  assertEquals(finishReasonFromStop("max_tokens"), "length", "token cap");
  assertEquals(finishReasonFromStop("model_context_window_exceeded"), "length", "context cap");
  assertEquals(finishReasonFromStop("refusal"), "content_filter", "safety decline");
  assertEquals(finishReasonFromStop("tool_use"), "tool_calls", "tool call");
  assertEquals(finishReasonFromStop(undefined), undefined, "missing");
  assertEquals(finishReasonFromStop(null), undefined, "null");
  // A provider-chosen string never reaches a log as itself.
  assertEquals(finishReasonFromStop("pause_turn"), "other", "unknown value");
  assertEquals(finishReasonFromStop("Wie viel Protein brauche ich?"), "other", "free text");
});

Deno.test("only text blocks are answer text; thinking and other blocks are ignored", () => {
  const message = {
    content: [
      { type: "thinking", thinking: "internal reasoning", signature: "s" },
      { type: "text", text: "Hallo " },
      { type: "redacted_thinking", data: "x" },
      { type: "text", text: "Welt" },
    ],
  };
  assertEquals(claudeText(message), "Hallo Welt", "text blocks in order, nothing else");
  assertEquals(claudeText({ content: [] }), "", "pre-output refusal has no text");
  assertEquals(claudeText({ content: "kein Array" }), "", "malformed content");
  assertEquals(claudeText(null), "", "no message");
});

Deno.test("request body: adaptive thinking, explicit effort, no sampling parameters", () => {
  const body = claudeRequestBody({
    system: cachedSystem("STABLE", "tail"),
    messages: [{ role: "user", content: "Hi" }],
    maxTokens: 1234,
    effort: "high",
    schema: { type: "object" },
  });
  assertEquals(body.model, "claude-sonnet-5-5", "default model");
  assertEquals(body.max_tokens, 1234, "token cap");
  assertEquals(JSON.stringify(body.thinking), '{"type":"adaptive"}', "adaptive thinking");
  assertEquals(
    JSON.stringify(body.output_config),
    '{"effort":"high","format":{"type":"json_schema","schema":{"type":"object"}}}',
    "effort and structured output",
  );
  for (const forbidden of ["temperature", "top_p", "top_k", "stream", "response_format", "reasoning"]) {
    assert(!(forbidden in body), `${forbidden} must not be sent`);
  }
  assertEquals(claudeRequestBody({ system: [], messages: [], maxTokens: 1, effort: "low", stream: true }).stream, true, "stream flag");
  assert(!("format" in (claudeRequestBody({ system: [], messages: [], maxTokens: 1, effort: "low" }).output_config as object)), "no schema, no format");
});

Deno.test("only the stable system prefix carries the cache breakpoint", () => {
  const blocks = cachedSystem("STABLE", "tail");
  assertEquals(blocks.length, 2, "two blocks");
  assertEquals(JSON.stringify(blocks[0].cache_control), '{"type":"ephemeral"}', "prefix cached");
  assert(blocks[1].cache_control === undefined, "tail after the breakpoint");
  assertEquals(cachedSystem("STABLE").length, 1, "no empty tail block");
});

Deno.test("an empty credit balance is our outage (402), other 400s stay input faults", () => {
  const credit = JSON.stringify({ type: "error", error: { type: "invalid_request_error", message: "Your credit balance is too low to access the Anthropic API." } });
  assertEquals(claudeFailureStatus(400, credit), 402, "credit balance");
  assertEquals(claudeFailureStatus(400, JSON.stringify({ error: { type: "billing_error", message: "x" } })), 402, "billing type");
  assertEquals(claudeFailureStatus(400, JSON.stringify({ error: { type: "invalid_request_error", message: "image too large" } })), 400, "input fault");
  assertEquals(claudeFailureStatus(400, "not json"), 400, "unreadable body");
  assertEquals(claudeFailureStatus(400, null), 400, "oversized body");
  assertEquals(claudeFailureStatus(529, credit), 529, "only a 400 is reinterpreted");
});

Deno.test("stream error events carry the matching HTTP status", () => {
  assertEquals(claudeErrorStatus({ type: "overloaded_error" }), 529, "overloaded");
  assertEquals(claudeErrorStatus({ type: "invalid_request_error" }), 400, "invalid request");
  assertEquals(claudeErrorStatus({ type: "request_too_large" }), 413, "too large");
  assertEquals(claudeErrorStatus({ type: "permission_error" }), 403, "permission");
  assertEquals(claudeErrorStatus({ type: "unbekannt" }), 502, "unknown type");
  assertEquals(claudeErrorStatus("kaputt"), 502, "no object");
});

Deno.test("an unknown effort secret falls back instead of reaching the API", () => {
  const name = "CLAUDE_TEST_EFFORT";
  const warn = console.warn;
  const lines: string[] = [];
  console.warn = (...args: unknown[]) => { lines.push(args.map(String).join(" ")); };
  try {
    Deno.env.delete(name);
    assertEquals(effortFromEnv(name, "medium"), "medium", "unset");
    Deno.env.set(name, " low ");
    assertEquals(effortFromEnv(name, "medium"), "low", "valid value");
    Deno.env.set(name, "turbo");
    assertEquals(effortFromEnv(name, "high"), "high", "invalid value");
    assertEquals(lines.length, 1, "the invalid value is reported once");
    assert(!lines[0].includes("turbo"), "the configured value is not echoed");
  } finally {
    console.warn = warn;
    Deno.env.delete(name);
  }
});

Deno.test("the image edge limit matches the provider's measured maximum", () => {
  assertEquals(CLAUDE_MAX_IMAGE_EDGE_PX, 8000, "8000 px accepted, 8600 px rejected (2026-10-08)");
});
