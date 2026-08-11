// Normalisierung der rohen Modell-Antwort auf den Wire-Vertrag der Function.
//
// Bewusst aus index.ts herausgeloest (gleiches Muster wie coach-chat:
// index.ts = nur Deno.serve, Logik daneben), damit normalize_test.ts die
// Funktion importieren kann, OHNE dass beim Modul-Load ein Server startet
// und ohne --allow-net.
//
// LEITSATZ (Review 2026-08-08, B1): Fuer eine ZAHL, die eine
// Gesundheitsangabe traegt, gibt es genau zwei ehrliche Antworten — den Wert
// des Modells oder "fehlt". Ein Default ist die dritte, unehrliche: er sieht
// aus wie eine Messung, ist aber eine Erfindung des Servers.
//
// Bis 2026-08-08 gab clampNumber/clampInt bei unparsebarem Input `min` = 0
// zurueck. Lieferte das Modell "186 kcal/100g" als String statt als Zahl,
// stand `kcalPer100G: 0` im Wire-Vertrag: die Karte zeigte 780 kcal, das
// Tagebuch bekam nach "Portion anpassen" (kcalPer100G * g / 100) aber 0.
// Seitdem: null statt min. Das Klemmen PARSEBARER Werte auf [min, max]
// bleibt unveraendert — das ist echte Validierung, keine Erfindung.

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
      // Ein Name ist ein Label, keine Messung: ein Fallback-Text erzeugt keine
      // falsche Zahl, deshalb bleibt clampString hier richtig.
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
    // Sentinel-Rest E7: confidence ist die Aussage des Modells ueber die
    // eigene Sicherheit, kein Label — fehlt sie, ist sie nicht "medium",
    // sondern fehlt (Leitsatz dieser Datei). Der Client zeigt dann
    // "Unbekannt" statt eines erfundenen Vertrauensgrads.
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
 * Streng: nur echte, endliche Zahlen und Strings, die als GANZES eine Zahl
 * sind ("186", " 420 ", "185.7"). Alles andere -> null.
 *
 * Warum nicht `Number(value)` allein: Number() macht aus einer ganzen Reihe
 * von "keine Zahl"-Werten still eine 0 —
 *   Number('') === 0, Number('  ') === 0, Number(null) === 0,
 *   Number(false) === 0, Number([]) === 0, Number([186]) === 186.
 * Genau diese stillen Nullen sind der B1-Bug.
 *
 * Warum KEINE Regex-Extraktion der ersten Ziffernfolge (wie es die Dart-Seite
 * in ihrer Fallback-Kette tut): aus "1/2 Tasse" wuerde 1, aus "100-150 g"
 * wuerde 100, aus "ca. 2 Portionen" wuerde 2. Das sind selbstbewusst falsche
 * Zahlen — dieselbe Fehlerklasse, die wir gerade schliessen. Der Server raet
 * nicht; er meldet "fehlt" und ueberlaesst dem Client die dokumentierte,
 * sichtbare Fallback-Kette.
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

/** Unparsebar -> null. Parsebar -> auf [min, max] geklemmt (unveraendert). */
export function optionalNumber(value: unknown, min: number, max: number): number | null {
  const number = toFiniteNumber(value);
  if (number === null) return null;
  return Math.min(max, Math.max(min, number));
}

/** Wie optionalNumber, zusaetzlich auf eine ganze Zahl gerundet. */
export function optionalInt(value: unknown, min: number, max: number): number | null {
  const number = optionalNumber(value, min, max);
  return number === null ? null : Math.round(number);
}

export interface KcalRatioMismatch {
  /** Was das Modell als kcalPer100G behauptet hat. */
  reported: number;
  /** Was caloriesKcal/estimatedGrams implizieren. */
  implied: number;
  deviationPct: number;
}

/**
 * Zweiter Fehlermodus aus B1: das Modell liefert drei Zahlen, die sich
 * widersprechen ({caloriesKcal: 850, estimatedGrams: 300, kcalPer100G: 260} —
 * 260 * 300 / 100 = 780, nicht 850).
 *
 * Diese Funktion MELDET den Widerspruch nur (index.ts loggt ihn); sie
 * korrigiert nichts. Begruendung siehe Kopf von index.ts beim Aufruf.
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
  // Absoluter UND relativer Korridor: das Modell rundet auf ganze kcal/Gramm,
  // was bei kleinen Portionen prozentual gross aussieht, ohne ein Widerspruch
  // zu sein. Nur wenn BEIDE Korridore gerissen werden, ist es einer.
  if (deviation <= 5 || deviation / implied <= 0.05) return null;

  return { reported: kcalPer100G, implied, deviationPct: (deviation / implied) * 100 };
}

export function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

// ---------------------------------------------------------------------------
// Log-Redaktion fuer rohen Provider-Content (Security-Review 2026-08-11,
// Finding 4, CWE-532): Modell-Output und Provider-Fehler-Bodies sind aus dem
// Essensfoto + Nutzer-Hint abgeleitet — private Ernaehrungs-/Gesundheits-/
// Freitext-Infos gehoeren nicht in operative Logs. index.ts loggt statt des
// Inhalts nur die Allowlist-Metadaten aus diesen zwei Helfern; hier
// ausgelagert (gleiches Muster wie der Rest der Datei), damit
// normalize_test.ts absichern kann, dass der Inhalt selbst nie im
// Log-Objekt landet.
// ---------------------------------------------------------------------------

export type UnparseableShape = 'empty' | 'not_json' | 'not_object';

/**
 * Grobe Form-Kategorie des unparsebaren Modell-Outputs — genug, um im Log
 * "leer nach extractJson" von "kein JSON" oder "JSON, aber kein Objekt" zu
 * unterscheiden, ohne den Inhalt zu zeigen. `parseError` ist der Fehler aus
 * dem JSON.parse/isRecord-Block in index.ts: JSON.parse wirft SyntaxError
 * (-> not_json), der isRecord-Guard einen gewoehnlichen Error (-> not_object).
 */
export function unparseableShape(jsonText: string, parseError: unknown): UnparseableShape {
  if (!jsonText.trim()) return 'empty';
  return parseError instanceof SyntaxError ? 'not_json' : 'not_object';
}

/**
 * Redaktions-Ersatz fuer den frueheren `raw:`-Slice: Laenge + SHA-256-Praefix
 * (12 Hex-Zeichen). Der Digest erlaubt Dedupe/Korrelation ("dieselbe kaputte
 * Antwort wie in Request X?") und den Abgleich mit einer konkret vorliegenden
 * Antwort, verraet aber nichts ueber den Inhalt.
 */
export async function redactedContentMeta(content: string): Promise<{ len: number; sha256: string }> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(content));
  const hex = Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, '0')).join('');
  return { len: content.length, sha256: hex.slice(0, 12) };
}
