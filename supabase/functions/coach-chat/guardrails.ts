// Layer 2 - categories and decision logic of the topic classifier, plus the
// Layer-1 check of the app context (sanitizeUserContext, bottom).
//
// Side-effect-free on purpose: this is the most security-relevant switch of
// the function and must be testable without network, env or Deno.serve.

import { BANNED_PATTERNS } from "./prefilter.ts";

export const CLASSIFIER_CATEGORIES = [
  "fitness",
  "nutrition",
  "smalltalk",
  "self_harm",
  "eating_disorder",
  "medical_risk",
  "off_topic",
  "injection",
] as const;

export type ClassifierCategory = (typeof CLASSIFIER_CATEGORIES)[number];

export interface ClassifierResult {
  category: ClassifierCategory;
  confidence: "low" | "medium" | "high";
  /**
   * true = the output was UNUSABLE and `category` is only the fail-closed
   * `off_topic` default, i.e. nothing was classified. Without the flag broken
   * JSON silently disabled the crisis check in every set lacking off_topic
   * (W1); layer2RefusalReason() decides who reacts.
   */
  parseFailed: boolean;
}

// Categories Layer 2 refuses. A refusal still costs the daily slot: the
// handler claims BEFORE the classifier call, or an exhausted quota would
// still buy classifier calls (CWE-770). self_harm and eating_disorder route
// to the Layer-1 crisis answers, since Layer 1 is deliberately lax.
export const REFUSAL_CATEGORIES: ReadonlySet<ClassifierCategory> = new Set([
  "self_harm",
  "eating_disorder",
  "medical_risk",
  "off_topic",
  "injection",
]);

// IMAGE path: REFUSAL_CATEGORIES without "off_topic". The classifier only
// sees the TEXT, and short deictic captions would land in off_topic and break
// the vision flow; off-topic IMAGES are Layer 3's job via `__REFUSE__`.
//
// This path also ignores ClassifierResult.parseFailed, since Layer 3 carries
// its own CRISIS RULE and the actual image.
export const IMAGE_REFUSAL_CATEGORIES: ReadonlySet<ClassifierCategory> =
  new Set([
    "self_harm",
    "eating_disorder",
    "medical_risk",
    "injection",
  ]);

// RECIPE path: REFUSAL_CATEGORIES without "off_topic", since recipe wishes
// are often bare dish names; the recipe prompt's own JSON refusal catches
// non-recipe wishes. There is NO second crisis layer here, so a parse failure
// is refused separately (layer2RefusalReason below).
export const RECIPE_REFUSAL_CATEGORIES: ReadonlySet<ClassifierCategory> =
  new Set([
    "self_harm",
    "eating_disorder",
    "medical_risk",
    "injection",
  ]);

/**
 * Does Layer 2 run? The only exclusion is empty text, not the presence of an
 * image: a blind classify(key, "") would hit the fail-closed `off_topic`
 * default and reject every caption-less upload.
 */
export function shouldRunClassifier(message: string): boolean {
  return message.trim().length > 0;
}

/** Active refusal set for the request (image -> without off_topic). */
export function refusalCategoriesFor(
  hasImage: boolean,
): ReadonlySet<ClassifierCategory> {
  return hasImage ? IMAGE_REFUSAL_CATEGORIES : REFUSAL_CATEGORIES;
}

/** The model's category, or "classifier_unusable" when nothing classified. */
export type Layer2RefusalReason = ClassifierCategory | "classifier_unusable";

/**
 * Does Layer 2 refuse, and why? null = let through. With `parseFailed` only
 * set membership counts; without it nothing classified, so paths whose set
 * lacks off_topic would skip the crisis check — `refuseOnUnusableOutput` is
 * the CALLER's switch for that (image path: no, recipe path: yes).
 */
export function layer2RefusalReason(options: {
  result: ClassifierResult;
  categories: ReadonlySet<ClassifierCategory>;
  refuseOnUnusableOutput: boolean;
}): Layer2RefusalReason | null {
  const { result, categories, refuseOnUnusableOutput } = options;
  if (result.parseFailed && refuseOnUnusableOutput) return "classifier_unusable";
  return categories.has(result.category) ? result.category : null;
}

// ---------------------------------------------------------------------------
// Layer 1 over the app context (security fix 2026-08-14)
// ---------------------------------------------------------------------------
// `user_context` comes from the request body yet reaches the model at the
// prompt's highest trust level, and is reachable without a tampered client
// (_todaysFoodSummary feeds in user-chosen meal names). On a hit the CONTEXT
// is dropped, not the request — the slot is claimed either way.

export const MAX_USER_CONTEXT_CHARS = 1200;

/**
 * Cleans the app context. `dropped` carries the Layer-1 reason for the server
 * log, NEVER the content; `context` is then empty.
 */
export function sanitizeUserContext(
  raw: string,
): { context: string; dropped: string | null } {
  const cleaned = Array.from(raw)
    // Control characters out, plus angle brackets: the context is framed in
    // <app_context>…</app_context> and must not close that frame from inside.
    .filter((ch) => {
      const code = ch.charCodeAt(0);
      return code >= 32 && code !== 127 && ch !== "<" && ch !== ">";
    })
    .join("")
    .trim()
    .slice(0, MAX_USER_CONTEXT_CHARS);
  if (cleaned.length === 0) return { context: "", dropped: null };
  // The TRUNCATED text is checked; anything past the cap never leaves.
  for (const { pattern, reason } of BANNED_PATTERNS) {
    if (pattern.test(cleaned)) return { context: "", dropped: reason };
  }
  return { context: cleaned, dropped: null };
}
