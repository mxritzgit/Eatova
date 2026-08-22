// Normalises the raw model answer onto the function's wire contract. Split out
// of index.ts so normalize_test.ts can import it without starting a server.
//
// Guiding rule (Review 2026-08-08, B1): a NUMBER carrying a health claim has
// two honest answers, the model's value or "missing" — a default looks like a
// measurement but is the server's invention. Unparseable input therefore
// yields null, never `min`; clamping PARSEABLE values stays.

export interface NormalizedMealItem {
  name: string;
  grams: number | null;
  caloriesKcal: number | null;
  kcalPer100G: number | null;
}

export interface NormalizedMealResult {
  mealName: string;
  caloriesKcal: number | null;
  estimatedGrams: number | null;
  kcalPer100G: number | null;
  proteinG: number | null;
  carbsG: number | null;
  fatG: number | null;
  confidence: string | null;
  explanation: string;
  items: NormalizedMealItem[];
}

export function normalizeMealResult(raw: Record<string, unknown>): NormalizedMealResult {
  const itemsRaw = Array.isArray(raw.items) ? raw.items : [];
  const items = itemsRaw
    .filter(isRecord)
    .slice(0, 20)
    .map((item) => ({
      // A name is a label, not a measurement: a fallback text invents no
      // number, so clampString stays right here.
      name: clampString(item.name, 'Lebensmittel', 80),
      grams: optionalInt(item.grams, 0, 10000),
      caloriesKcal: optionalInt(item.caloriesKcal, 0, 10000),
      kcalPer100G: optionalNumber(item.kcalPer100G, 0, 1000),
    }));

  return {
    mealName: clampString(raw.mealName, 'Mahlzeit', 160),
    caloriesKcal: optionalInt(raw.caloriesKcal, 0, 10000),
    estimatedGrams: optionalInt(raw.estimatedGrams, 0, 10000),
    kcalPer100G: optionalNumber(raw.kcalPer100G, 0, 1000),
    proteinG: optionalInt(raw.proteinG, 0, 1000),
    carbsG: optionalInt(raw.carbsG, 0, 1000),
    fatG: optionalInt(raw.fatG, 0, 1000),
    // E7: confidence is the model's statement about itself, not a label — if
    // it is missing it is missing, not "medium". The client says so.
    confidence: ['high', 'medium', 'low'].includes(String(raw.confidence))
      ? String(raw.confidence)
      : null,
    explanation: clampString(raw.explanation, '', 500),
    items,
  };
}

export function clampString(value: unknown, fallback: string, maxLength: number): string {
  const text = typeof value === 'string' ? value.trim() : fallback;
  return (text || fallback).slice(0, maxLength);
}

/**
 * Strict: only finite numbers and strings that are a number AS A WHOLE;
 * everything else -> null. Not plain `Number(value)`, which turns '', null,
 * false and [] silently into 0 (the B1 bug), and no regex extraction of the
 * first digit run either — "1/2 cup" would become 1.
 */
function toFiniteNumber(value: unknown): number | null {
  if (typeof value === 'number') {
    return Number.isFinite(value) ? value : null;
  }
  if (typeof value === 'string') {
    const trimmed = value.trim();
    if (!trimmed) return null;
    const parsed = Number(trimmed);
    return Number.isFinite(parsed) ? parsed : null;
  }
  return null;
}

/** Unparseable -> null; parseable -> clamped to [min, max]. */
export function optionalNumber(value: unknown, min: number, max: number): number | null {
  const number = toFiniteNumber(value);
  if (number === null) return null;
  return Math.min(max, Math.max(min, number));
}

/** Like optionalNumber, additionally rounded to an integer. */
export function optionalInt(value: unknown, min: number, max: number): number | null {
  const number = optionalNumber(value, min, max);
  return number === null ? null : Math.round(number);
}

export interface KcalRatioMismatch {
  /** What the model claimed as kcalPer100G. */
  reported: number;
  /** What caloriesKcal/estimatedGrams imply. */
  implied: number;
  deviationPct: number;
}

/**
 * Second B1 failure mode: the model returns three numbers that contradict
 * each other (850 kcal at 300 g is not 260 kcal/100 g).
 *
 * This only REPORTS the contradiction; index.ts logs it, nothing corrects it.
 */
export function kcalPer100GMismatch(
  caloriesKcal: number | null,
  estimatedGrams: number | null,
  kcalPer100G: number | null,
): KcalRatioMismatch | null {
  if (caloriesKcal == null || estimatedGrams == null || kcalPer100G == null) return null;
  if (caloriesKcal <= 0 || estimatedGrams <= 0 || kcalPer100G <= 0) return null;

  const implied = (caloriesKcal * 100) / estimatedGrams;
  const deviation = Math.abs(implied - kcalPer100G);
  // Absolute AND relative corridor: the model rounds to whole kcal/grams,
  // which looks large in percent on small portions. Only breaking both counts.
  if (deviation <= 5 || deviation / implied <= 0.05) return null;

  return { reported: kcalPer100G, implied, deviationPct: (deviation / implied) * 100 };
}

export function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

// ---------------------------------------------------------------------------
// Log redaction for raw provider content (Security review 2026-08-11,
// finding 4, CWE-532): model output and provider error bodies derive from the
// food photo and user hint, so index.ts logs only the allowlisted metadata
// from these two helpers, kept here so normalize_test.ts can prove it.
// ---------------------------------------------------------------------------

export type UnparseableShape = 'empty' | 'not_json' | 'not_object';

/**
 * Coarse shape category of unparseable model output — enough to tell "empty",
 * "no JSON" and "JSON but no object" apart in the log without showing the
 * content. `parseError` comes from the JSON.parse/isRecord block in index.ts:
 * JSON.parse throws SyntaxError, the isRecord guard a plain Error.
 */
export function unparseableShape(jsonText: string, parseError: unknown): UnparseableShape {
  if (!jsonText.trim()) return 'empty';
  return parseError instanceof SyntaxError ? 'not_json' : 'not_object';
}

/**
 * Redacted stand-in for the former `raw:` slice: length plus a 12-hex-char
 * SHA-256 prefix. The digest allows dedupe and correlation without revealing
 * anything about the content.
 */
export async function redactedContentMeta(content: string): Promise<{ len: number; sha256: string }> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(content));
  const hex = Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, '0')).join('');
  return { len: content.length, sha256: hex.slice(0, 12) };
}
