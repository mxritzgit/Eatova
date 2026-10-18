// One structured log line per paid provider call, `{"event":"ai_call",...}`,
// for cost, prompt-cache, latency and truncation analysis in the Supabase
// Logs Explorer (docs/OPERATIONS.md, "AI call telemetry").
//
// Content-free by construction (CWE-532): the line has a fixed key set, and
// every value is an enum member, a bounded integer, a boolean or null. A value
// outside its enum becomes 'other'; anything else becomes null. No prompt,
// answer, user id, IP, request id or provider-chosen string can reach it.
//
// Telemetry never throws: a broken logger or a malformed usage object must not
// turn a paid answer into an error.

export const AI_CALL_EVENT = 'ai_call';

export type AiFunction = 'coach-chat' | 'analyze-meal' | 'recipe-import';
export type AiRoute = 'chat' | 'classifier' | 'recipe' | 'plan' | 'log' | 'image' | 'analyze' | 'describe' | 'import';
export type AiProvider = 'anthropic' | 'openrouter';
/**
 * Provider-level result. `refused` is the provider's safety stop
 * (stop_reason "refusal"); a refusal the app derives from an answer is `ok`.
 * `aborted` means the caller's client went away mid-call.
 */
export type AiOutcome = 'ok' | 'refused' | 'timeout' | 'aborted' | 'error';

const FUNCTIONS: readonly string[] = ['coach-chat', 'analyze-meal', 'recipe-import'];
const ROUTES: readonly string[] = ['chat', 'classifier', 'recipe', 'plan', 'log', 'image', 'analyze', 'describe', 'import'];
const PROVIDERS: readonly string[] = ['anthropic', 'openrouter'];
const OUTCOMES: readonly string[] = ['ok', 'refused', 'timeout', 'aborted', 'error'];
const EFFORTS: readonly string[] = ['low', 'medium', 'high', 'xhigh', 'max'];
/** Messages API stop_reason values, plus OpenAI-style finish_reason values. */
const STOP_REASONS: readonly string[] = [
  'end_turn', 'max_tokens', 'stop_sequence', 'tool_use', 'pause_turn', 'refusal',
  'model_context_window_exceeded', 'stop', 'length', 'content_filter', 'tool_calls', 'error',
];
/** Model ids are operator configuration (secrets), never user input. */
const MODEL_ID = /^[A-Za-z0-9][A-Za-z0-9._:/-]{0,99}$/;
const MAX_TOKENS_COUNT = 100_000_000;
const MAX_LATENCY_MS = 3_600_000;

export interface AiCallMeta {
  route: AiRoute;
  provider: AiProvider;
  model: string;
  /** Thinking effort; null for calls without one (image generation). */
  effort?: string | null;
  stream?: boolean;
  /** 1-based attempt of a retried call. */
  attempt?: number;
}

export interface AiCallResult {
  outcome: AiOutcome;
  /** The provider's HTTP status; null if no response arrived. */
  httpStatus?: number | null;
  /** The provider's raw stop_reason/finish_reason; only allowlisted values are kept. */
  stopReason?: unknown;
  /** The provider's raw usage object; only the token counters are kept. */
  usage?: unknown;
}

/** The line, exactly. Adding a key means adding it here and to the test. */
export interface AiCallLine {
  event: typeof AI_CALL_EVENT;
  fn: string;
  route: string;
  provider: string;
  model: string;
  effort: string | null;
  stream: boolean;
  attempt: number;
  outcome: string;
  http_status: number | null;
  latency_ms: number;
  stop_reason: string | null;
  input_tokens: number | null;
  output_tokens: number | null;
  cache_creation_input_tokens: number | null;
  cache_read_input_tokens: number | null;
  refunded: boolean;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function member(value: unknown, allowed: readonly string[]): string {
  return typeof value === 'string' && allowed.includes(value) ? value : 'other';
}

function optionalMember(value: unknown, allowed: readonly string[]): string | null {
  return value === undefined || value === null ? null : member(value, allowed);
}

function count(value: unknown): number | null {
  return typeof value === 'number' && Number.isSafeInteger(value) && value >= 0 && value <= MAX_TOKENS_COUNT
    ? value
    : null;
}

function firstCount(...values: unknown[]): number | null {
  for (const value of values) {
    const parsed = count(value);
    if (parsed !== null) return parsed;
  }
  return null;
}

/**
 * Token counters from a Messages API usage object; an OpenAI-style one
 * (prompt_tokens, completion_tokens, prompt_tokens_details.cached_tokens) maps
 * onto the same fields. Claude's input_tokens excludes cached tokens, so the
 * whole prompt is input + cache_creation + cache_read.
 */
function tokenCounters(usage: unknown): Pick<
  AiCallLine,
  'input_tokens' | 'output_tokens' | 'cache_creation_input_tokens' | 'cache_read_input_tokens'
> {
  const record = isRecord(usage) ? usage : {};
  const details = isRecord(record.prompt_tokens_details) ? record.prompt_tokens_details : {};
  return {
    input_tokens: firstCount(record.input_tokens, record.prompt_tokens),
    output_tokens: firstCount(record.output_tokens, record.completion_tokens),
    cache_creation_input_tokens: firstCount(record.cache_creation_input_tokens),
    cache_read_input_tokens: firstCount(record.cache_read_input_tokens, details.cached_tokens),
  };
}

/** Builds the allowlisted line. Pure; exported for the tests. */
export function aiCallLine(
  fn: AiFunction,
  meta: AiCallMeta,
  result: AiCallResult,
  latencyMs: number,
  refunded: boolean,
): AiCallLine {
  const status = result.httpStatus;
  const attempt = meta.attempt;
  return {
    event: AI_CALL_EVENT,
    fn: member(fn, FUNCTIONS),
    route: member(meta.route, ROUTES),
    provider: member(meta.provider, PROVIDERS),
    model: typeof meta.model === 'string' && MODEL_ID.test(meta.model) ? meta.model : 'other',
    effort: optionalMember(meta.effort, EFFORTS),
    stream: meta.stream === true,
    attempt: typeof attempt === 'number' && Number.isSafeInteger(attempt) && attempt >= 1 && attempt <= 10 ? attempt : 1,
    outcome: member(result.outcome, OUTCOMES),
    http_status: typeof status === 'number' && Number.isInteger(status) && status >= 100 && status <= 599 ? status : null,
    latency_ms: Number.isFinite(latencyMs) ? Math.min(MAX_LATENCY_MS, Math.max(0, Math.round(latencyMs))) : 0,
    stop_reason: optionalMember(result.stopReason, STOP_REASONS),
    ...tokenCounters(result.usage),
    refunded: refunded === true,
  };
}

/** Outcome of a call that threw: deadline, caller abort, or anything else. */
export function aiOutcomeOf(error: unknown): AiOutcome {
  if (error instanceof DOMException && error.name === 'TimeoutError') return 'timeout';
  if (error instanceof DOMException && error.name === 'AbortError') return 'aborted';
  return 'error';
}

/** Outcome of a call that answered: the provider's safety stop, or ok. */
export function aiAnswerOutcome(stopReason: unknown): AiOutcome {
  return stopReason === 'refusal' || stopReason === 'content_filter' ? 'refused' : 'ok';
}

function writeLine(line: AiCallLine): void {
  try {
    console.log(JSON.stringify(line));
  } catch {
    // A failing logger must not fail the request.
  }
}

type SettledCall = { meta: AiCallMeta; result: AiCallResult; latencyMs: number };

/** One provider call, from just before the request to its settled result. */
export class AiCall {
  readonly #meta: AiCallMeta;
  readonly #started = performance.now();
  readonly #onSettle: (call: SettledCall) => void;
  #settled = false;

  constructor(meta: AiCallMeta, onSettle: (call: SettledCall) => void) {
    this.#meta = meta;
    this.#onSettle = onSettle;
  }

  get settled(): boolean {
    return this.#settled;
  }

  /** Records the result once; later calls are ignored. Never throws. */
  settle(result: AiCallResult): void {
    if (this.#settled) return;
    this.#settled = true;
    try {
      this.#onSettle({ meta: this.#meta, result, latencyMs: performance.now() - this.#started });
    } catch {
      // Telemetry never throws.
    }
  }
}

export interface AiCallLogOptions {
  /**
   * Hold every line until flush(), so `refunded` describes the request's final
   * state. For handlers that may give the user's slot back after a call.
   */
  deferUntilFlush?: boolean;
}

/**
 * The AI calls of one request. Without deferral every call is written when
 * it settles. With deferral, lines wait for flush() and for every hold() to be
 * released, so a stream that outlives its response still reports its refund.
 */
export class AiCallLog {
  readonly #fn: AiFunction;
  readonly #deferred: boolean;
  readonly #pending: SettledCall[] = [];
  #refunded = false;
  #holds = 0;
  #flushRequested = false;

  constructor(fn: AiFunction, options: AiCallLogOptions = {}) {
    this.#fn = fn;
    this.#deferred = options.deferUntilFlush === true;
  }

  start(meta: AiCallMeta): AiCall {
    return new AiCall(meta, (call) => {
      this.#pending.push(call);
      if (!this.#deferred || (this.#flushRequested && this.#holds === 0)) this.#write();
    });
  }

  /** The user's quota slot for this request was given back. */
  markRefunded(): void {
    this.#refunded = true;
  }

  /** Delays writing until the returned release runs (idempotent). */
  hold(): () => void {
    this.#holds++;
    let released = false;
    return () => {
      if (released) return;
      released = true;
      this.#holds--;
      if (this.#flushRequested) this.flush();
    };
  }

  /** Writes every settled call unless a hold is active; later calls write on settle. */
  flush(): void {
    this.#flushRequested = true;
    if (this.#holds > 0) return;
    this.#write();
  }

  #write(): void {
    for (const call of this.#pending.splice(0)) {
      try {
        writeLine(aiCallLine(this.#fn, call.meta, call.result, call.latencyMs, this.#refunded));
      } catch {
        // Telemetry never throws.
      }
    }
  }
}
