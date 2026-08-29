// What may be written to `function_logs` from a provider answer.
//
// Everything an LLM provider hands back is provider-controlled: the model
// output derives from the food photo and the user hint, and the metadata next
// to it (`finish_reason`) is a free string the provider chooses. Logging it
// verbatim is CWE-532.
//
// P6-04c (review 2026-08-29): this lived in analyze-meal/normalize.ts while
// coach-chat/handler.ts solved the same problem a second time, and worse — it
// only capped `finish_reason` at 32 characters, so 32 provider-chosen
// characters still reached the log. One definition, one import path.

/** The finish_reason values the OpenAI/OpenRouter contract defines. */
const KNOWN_FINISH_REASONS = [
  'stop',
  'length',
  'content_filter',
  'tool_calls',
  'function_call',
  'error',
];

/**
 * P6-04b: `finish_reason` is as provider-controlled as the model output next
 * to it, and the "the model gave us nothing usable" log lines wrote it
 * through unfiltered. Reported as an allowlist: the contract's enum value, or
 * the category 'other' for anything else. An unlisted value stays visible as
 * 'other' — enough to notice, without letting a provider-chosen string into
 * the log (CWE-532).
 *
 * Truncating instead of categorising is NOT equivalent: a cap keeps the first
 * n provider-chosen characters, and n characters of the user's hint are still
 * the user's hint.
 */
export function loggableFinishReason(value: unknown): string | undefined {
  if (value === undefined || value === null) return undefined;
  return typeof value === 'string' && KNOWN_FINISH_REASONS.includes(value) ? value : 'other';
}
