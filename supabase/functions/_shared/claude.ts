// Anthropic Messages API wire contract for coach-chat, analyze-meal and
// recipe-import. Raw fetch on purpose: the functions stay dependency-free, every
// provider body read stays byte-bounded, and each caller keeps its own deadline,
// retry and refund policy (an SDK would retry and read bodies on its own).
// Recipe images stay on OpenRouter: Claude cannot generate images.

export const CLAUDE_MESSAGES_URL = 'https://api.anthropic.com/v1/messages';
const CLAUDE_API_VERSION = '2023-06-01';

/** Every text and vision route; an operator may pin another model by secret. */
export const CLAUDE_MODEL = Deno.env.get('CLAUDE_MODEL')?.trim() || 'claude-sonnet-5-5';

/** Claude rejects images whose width or height exceeds this (measured 2026-10-08). */
export const CLAUDE_MAX_IMAGE_EDGE_PX = 8000;

const EFFORTS = ['low', 'medium', 'high', 'xhigh', 'max'] as const;
export type ClaudeEffort = (typeof EFFORTS)[number];

/** Thinking depth per route. A set but unknown value is reported and ignored. */
export function effortFromEnv(name: string, fallback: ClaudeEffort): ClaudeEffort {
  const raw = Deno.env.get(name)?.trim();
  if (!raw) return fallback;
  if ((EFFORTS as readonly string[]).includes(raw)) return raw as ClaudeEffort;
  console.warn(`${name} ignored: expected one of ${EFFORTS.join(', ')}`);
  return fallback;
}

export function claudeHeaders(apiKey: string): Record<string, string> {
  return { 'x-api-key': apiKey, 'anthropic-version': CLAUDE_API_VERSION, 'content-type': 'application/json' };
}

export type ClaudeTextBlock = { type: 'text'; text: string; cache_control?: { type: 'ephemeral' } };
export type ClaudeImageBlock = {
  type: 'image';
  source: { type: 'base64'; media_type: string; data: string };
};
export type ClaudeMessage = {
  role: 'user' | 'assistant';
  content: string | (ClaudeTextBlock | ClaudeImageBlock)[];
};

/**
 * System prompt as content blocks. The stable part carries the cache
 * breakpoint, so every user and request with the same prompt reads it from the
 * prompt cache; a request-specific tail stays after the breakpoint.
 */
export function cachedSystem(stable: string, tail?: string): ClaudeTextBlock[] {
  return [
    { type: 'text', text: stable, cache_control: { type: 'ephemeral' } },
    ...(tail ? [{ type: 'text' as const, text: tail }] : []),
  ];
}

export function claudeImage(base64: string, mediaType: string): ClaudeImageBlock {
  return { type: 'image', source: { type: 'base64', media_type: mediaType, data: base64 } };
}

export interface ClaudeRequest {
  system: ClaudeTextBlock[];
  messages: ClaudeMessage[];
  /** Covers thinking AND visible text; thinking counts against it. */
  maxTokens: number;
  effort: ClaudeEffort;
  /** JSON schema for structured output: exactly one valid object, no prose. */
  schema?: Record<string, unknown>;
  stream?: boolean;
}

/**
 * A lone UTF-16 surrogate (an emoji cut by a length cap, in app context, a
 * meal name or a history row) makes the whole body invalid JSON for the API:
 * a 400 that would repeat on every request. It becomes U+FFFD instead.
 */
function wellFormedContent(content: ClaudeMessage['content']): ClaudeMessage['content'] {
  if (typeof content === 'string') return content.toWellFormed();
  return content.map((block) => block.type === 'text' ? { ...block, text: block.text.toWellFormed() } : block);
}

export function claudeRequestBody(request: ClaudeRequest): Record<string, unknown> {
  return {
    model: CLAUDE_MODEL,
    max_tokens: request.maxTokens,
    system: request.system.map((block) => ({ ...block, text: block.text.toWellFormed() })),
    messages: request.messages.map((message) => ({ ...message, content: wellFormedContent(message.content) })),
    // Explicit, so a pinned older model does not silently run without thinking.
    // Sampling parameters are not sent: Sonnet 5.5 rejects non-default values.
    thinking: { type: 'adaptive' },
    output_config: {
      effort: request.effort,
      ...(request.schema ? { format: { type: 'json_schema', schema: request.schema } } : {}),
    },
    ...(request.stream ? { stream: true } : {}),
  };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

/**
 * The answer text of a Messages API response: its `text` blocks in order.
 * Thinking blocks (empty under the default display) are never answer text.
 */
export function claudeText(message: unknown): string {
  if (!isRecord(message) || !Array.isArray(message.content)) return '';
  return message.content
    .map((block) => isRecord(block) && block.type === 'text' && typeof block.text === 'string' ? block.text : '')
    .join('');
}

/**
 * Claude's stop_reason in the finish_reason vocabulary the handlers decide on:
 * a complete answer is "stop", the token cap "length", a safety decline
 * "content_filter". Unknown values become "other", never a provider string.
 */
export function finishReasonFromStop(stopReason: unknown): string | undefined {
  switch (stopReason) {
    case undefined:
    case null:
      return undefined;
    case 'end_turn':
    case 'stop_sequence':
      return 'stop';
    case 'max_tokens':
    case 'model_context_window_exceeded':
      return 'length';
    case 'refusal':
      return 'content_filter';
    case 'tool_use':
      return 'tool_calls';
    default:
      return 'other';
  }
}

const ERROR_TYPE_STATUS: Record<string, number> = {
  invalid_request_error: 400,
  authentication_error: 401,
  billing_error: 402,
  permission_error: 403,
  not_found_error: 404,
  request_too_large: 413,
  rate_limit_error: 429,
  api_error: 500,
  overloaded_error: 529,
};

/** HTTP status equivalent of an error event inside a stream; 502 if unknown. */
export function claudeErrorStatus(error: unknown): number {
  const type = isRecord(error) ? error.type : undefined;
  return typeof type === 'string' ? ERROR_TYPE_STATUS[type] ?? 502 : 502;
}

/**
 * Status that decides who pays for a failed call. The API reports an empty
 * credit balance as a 400 invalid_request_error, which callers would otherwise
 * charge to the user's input; it is our outage, reported as 402. The body is
 * only inspected here, never returned or logged.
 */
export function claudeFailureStatus(status: number, rawBody: string | null): number {
  if (status !== 400 || rawBody === null) return status;
  try {
    const error = (JSON.parse(rawBody) as { error?: unknown }).error;
    if (!isRecord(error)) return status;
    if (error.type === 'billing_error') return 402;
    // The documented wording ("Your credit balance is too low ..."), anchored
    // at the start so no echoed request text can turn a 400 into a refund.
    return typeof error.message === 'string' && /^your credit balance is too low/i.test(error.message) ? 402 : status;
  } catch {
    return status;
  }
}
