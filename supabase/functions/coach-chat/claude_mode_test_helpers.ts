// Shared helpers for the coach-chat mode tests (stream, recipe, plan, log) on
// top of ../_shared/claude_test_fixtures.ts. No network, no dependencies.

import { CLAUDE_URL, isClassifierRequest, outputSchema, systemText } from "../_shared/claude_test_fixtures.ts";

type JsonRecord = Record<string, unknown>;

/** A structured draft (recipe, plan or log): a schema that is not the classifier's. */
export function isDraftRequest(body: JsonRecord): boolean {
  return outputSchema(body) !== undefined && !isClassifierRequest(body);
}

/** True if the request asks for exactly this output schema. */
export function asksForSchema(body: JsonRecord, schema: unknown): boolean {
  return JSON.stringify(outputSchema(body)) === JSON.stringify(schema);
}

/**
 * Simulated thinking spend before the visible text, per effort. Adaptive
 * thinking counts against max_tokens; "high" (the coach default) is assumed to
 * think the longest of the three, an unknown effort the worst case.
 */
export function simulatedThinkingTokens(body: JsonRecord): number {
  const effort = (body.output_config as JsonRecord | undefined)?.effort;
  if (effort === "low") return 128;
  if (effort === "medium") return 528;
  if (effort === "high") return 1024;
  return 2048;
}

/** Messages API error type for a non-ok status, as the API names it. */
export function claudeErrorTypeFor(status: number): string {
  switch (status) {
    case 400: return "invalid_request_error";
    case 401: return "authentication_error";
    case 402: return "billing_error";
    case 403: return "permission_error";
    case 404: return "not_found_error";
    case 413: return "request_too_large";
    case 429: return "rate_limit_error";
    case 529: return "overloaded_error";
    default: return "api_error";
  }
}

/** The API reports an empty credit balance as a 400 invalid_request_error. */
export const CREDIT_BALANCE_MESSAGE =
  "Your credit balance is too low to access the Anthropic API. Please go to Plans & Billing to upgrade or purchase credits.";

/** An error body whose read fails and whose cancel throws, quoting private text. */
export function brokenBody(privateText: string): ReadableStream<Uint8Array> {
  return new ReadableStream<Uint8Array>({
    pull() {
      throw new TypeError(privateText);
    },
    cancel() {
      throw new TypeError(privateText);
    },
  });
}

export interface ClaudeContract {
  maxTokens: number;
  /** Exported output schema the request must carry; undefined = free text. */
  schema?: unknown;
  /** Text the cached system prompt must contain. */
  systemIncludes?: string[];
}

/**
 * Throws unless a recorded request follows the Messages API contract of
 * ../_shared/claude.ts: Claude endpoint and headers, adaptive thinking, effort
 * and schema inside output_config, a cached system block, no sampling or
 * OpenRouter parameters.
 */
export function assertClaudeContract(
  call: { url: string; headers: Headers; body: JsonRecord },
  expected: ClaudeContract,
  label: string,
): void {
  const fail = (what: string, actual: unknown, wanted: unknown) => {
    throw new Error(`${label}: ${what}: ${JSON.stringify(actual)} != ${JSON.stringify(wanted)}`);
  };
  const same = (what: string, actual: unknown, wanted: unknown) => {
    if (JSON.stringify(actual) !== JSON.stringify(wanted)) fail(what, actual, wanted);
  };
  const { body } = call;
  same("url", call.url, CLAUDE_URL);
  same("x-api-key", call.headers.get("x-api-key"), "test-anthropic-key");
  same("anthropic-version", call.headers.get("anthropic-version"), "2023-06-01");
  same("no bearer token", call.headers.get("authorization"), null);
  same("model", body.model, "claude-sonnet-5-5");
  same("max_tokens", body.max_tokens, expected.maxTokens);
  same("thinking", body.thinking, { type: "adaptive" });
  same(
    "output_config",
    body.output_config,
    expected.schema === undefined
      ? { effort: "high" }
      : { effort: "high", format: { type: "json_schema", schema: expected.schema } },
  );
  for (const key of ["temperature", "top_p", "top_k", "reasoning", "response_format", "provider"]) {
    if (key in body) fail(`no ${key}`, body[key], undefined);
  }
  const system = body.system as JsonRecord[] | undefined;
  if (!Array.isArray(system) || system.length === 0) fail("system blocks", body.system, "[...]");
  same("cached stable system block", system![0].cache_control, { type: "ephemeral" });
  for (const part of expected.systemIncludes ?? []) {
    if (!systemText(body).includes(part)) fail("system text", systemText(body).slice(0, 80), part);
  }
  const messages = body.messages as JsonRecord[];
  if (messages.some((message) => message.role === "system")) fail("no system role in messages", messages, []);
}
