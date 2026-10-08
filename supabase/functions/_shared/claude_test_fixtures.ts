// Messages API shapes for the offline handler tests. Tests keep the
// finish_reason vocabulary the handlers decide on ("stop", "length",
// "content_filter"); these helpers translate it into Claude's wire format.

export const CLAUDE_URL = "https://api.anthropic.com/v1/messages";

type JsonRecord = Record<string, unknown>;

/** True for a Messages API call (recipe images still go to OpenRouter). */
export function isClaudeCall(url: string): boolean {
  return url.startsWith(CLAUDE_URL);
}

const STOP_REASONS: Record<string, string> = {
  stop: "end_turn",
  length: "max_tokens",
  content_filter: "refusal",
  tool_calls: "tool_use",
};

/**
 * Claude stop_reason for a test's finish_reason. Known values translate;
 * any other string passes through unchanged, so provider-chosen values still
 * reach the handler's allowlist. null/undefined mean "no stop_reason".
 */
export function stopReasonFor(finishReason: string | null | undefined): string | null {
  if (finishReason === null || finishReason === undefined) return null;
  return STOP_REASONS[finishReason] ?? finishReason;
}

/**
 * Buffered Messages API response. A leading thinking block with empty text is
 * what adaptive thinking returns under the default display; it must never be
 * read as answer text.
 */
export function claudeResponse(text: string, finishReason: string | null = "stop", usage: JsonRecord = {}): JsonRecord {
  const stopReason = stopReasonFor(finishReason);
  return {
    id: "msg_test",
    type: "message",
    role: "assistant",
    model: "claude-sonnet-5-5",
    content: [
      { type: "thinking", thinking: "", signature: "sig-test" },
      ...(text.length > 0 ? [{ type: "text", text }] : []),
    ],
    stop_reason: stopReason,
    stop_details: stopReason === "refusal" ? { type: "refusal", category: null, explanation: null } : null,
    usage: { input_tokens: 10, output_tokens: 5, ...usage },
  };
}

/** One SSE frame in the Messages API format. */
export function claudeEvent(data: JsonRecord): string {
  return `event: ${String(data.type)}\ndata: ${JSON.stringify(data)}\n\n`;
}

/** Frames up to and including the opened text block (thinking first). */
export function claudeStreamHead(): string[] {
  return [
    claudeEvent({
      type: "message_start",
      message: { id: "msg_test", type: "message", role: "assistant", model: "claude-sonnet-5-5", content: [], stop_reason: null, usage: { input_tokens: 10, output_tokens: 1 } },
    }),
    claudeEvent({ type: "content_block_start", index: 0, content_block: { type: "thinking", thinking: "", signature: "" } }),
    claudeEvent({ type: "content_block_delta", index: 0, delta: { type: "signature_delta", signature: "sig-test" } }),
    claudeEvent({ type: "content_block_stop", index: 0 }),
    claudeEvent({ type: "content_block_start", index: 1, content_block: { type: "text", text: "" } }),
  ];
}

/** A text delta of the answer block. */
export function claudeTextDelta(text: string): string {
  return claudeEvent({ type: "content_block_delta", index: 1, delta: { type: "text_delta", text } });
}

/** Closing frames: block stop, stop_reason, message_stop. */
export function claudeStreamTail(finishReason: string | null = "stop"): string[] {
  return [
    claudeEvent({ type: "content_block_stop", index: 1 }),
    claudeEvent({ type: "message_delta", delta: { stop_reason: stopReasonFor(finishReason), stop_sequence: null }, usage: { output_tokens: 5 } }),
    claudeEvent({ type: "message_stop" }),
  ];
}

/** A complete stream: head, one delta per piece, tail. */
export function claudeStream(pieces: string[], finishReason: string | null = "stop"): string {
  return [...claudeStreamHead(), ...pieces.map(claudeTextDelta), ...claudeStreamTail(finishReason)].join("");
}

/** Mid-stream error event; `type` is a Messages API error type. */
export function claudeErrorEvent(type: string, message = "provider error"): string {
  return claudeEvent({ type: "error", error: { type, message } });
}

/** Error body of a non-ok response. */
export function claudeErrorBody(type: string, message = "provider error"): string {
  return JSON.stringify({ type: "error", error: { type, message } });
}

/** All system prompt text of a request body. */
export function systemText(body: JsonRecord): string {
  const system = body.system;
  if (typeof system === "string") return system;
  return Array.isArray(system) ? system.map((block) => String((block as JsonRecord).text ?? "")).join("\n") : "";
}

/** The JSON schema a request asks for, if any. */
export function outputSchema(body: JsonRecord): JsonRecord | undefined {
  const format = (body.output_config as JsonRecord | undefined)?.format as JsonRecord | undefined;
  return format?.schema as JsonRecord | undefined;
}

/** The Layer-2 classifier asks for the category schema. */
export function isClassifierRequest(body: JsonRecord): boolean {
  const properties = outputSchema(body)?.properties as JsonRecord | undefined;
  return properties !== undefined && "category" in properties && "confidence" in properties;
}

/** Text of every text block in the messages, in order. */
export function messagesText(body: JsonRecord): string {
  const messages = Array.isArray(body.messages) ? body.messages as JsonRecord[] : [];
  return messages.map((message) => {
    const content = message.content;
    if (typeof content === "string") return content;
    return Array.isArray(content)
      ? content.map((block) => (block as JsonRecord).type === "text" ? String((block as JsonRecord).text) : "").join("\n")
      : "";
  }).join("\n");
}

/** True for any paid provider call: Claude or the OpenRouter image API. */
export function isProviderCall(url: string): boolean {
  return isClaudeCall(url) || url.startsWith("https://openrouter.ai/");
}

const ERROR_TYPES: Record<number, string> = {
  400: "invalid_request_error",
  401: "authentication_error",
  402: "billing_error",
  403: "permission_error",
  404: "not_found_error",
  413: "request_too_large",
  429: "rate_limit_error",
  529: "overloaded_error",
};

/** Messages API error type the API sends with an HTTP status. */
export function claudeErrorTypeFor(status: number): string {
  return ERROR_TYPES[status] ?? "api_error";
}

/** The API's wording for an empty credit balance; it arrives as a 400. */
export const CREDIT_BALANCE_MESSAGE =
  "Your credit balance is too low to access the Anthropic API. Please go to Plans & Billing to upgrade or purchase credits.";

/** Every image block in the messages, in order. */
export function imageBlocks(body: JsonRecord): JsonRecord[] {
  const messages = Array.isArray(body.messages) ? body.messages as JsonRecord[] : [];
  return messages.flatMap((message) =>
    Array.isArray(message.content)
      ? (message.content as JsonRecord[]).filter((block) => block.type === "image")
      : []
  );
}
