// Tests for normalizeMealResult (normalize.ts).
//
// Core regression (B1): clampNumber/clampInt returned `min` = 0 for an
// unparseable value, so a model answering "186 kcal/100g" as a STRING produced
// `kcalPer100G: 0` and silently wrong health numbers. The counter-check is
// that clamping to max must survive that fix.

import {
  kcalPer100GMismatch,
  normalizeMealResult,
  optionalInt,
  optionalNumber,
  redactedContentMeta,
  unparseableShape,
} from "./normalize.ts";

function assert(condition: boolean, message: string): void {
  if (!condition) throw new Error(message);
}

function assertEquals(actual: unknown, expected: unknown, message: string): void {
  if (actual !== expected) {
    throw new Error(
      `${message}: erwartet ${JSON.stringify(expected)}, war ${JSON.stringify(actual)}`,
    );
  }
}

/** "Missing" = null OR key absent; identical to Dart, so neither is pinned. */
function assertMissing(result: object, key: string, message: string): void {
  const value = (result as Record<string, unknown>)[key];
  if (value === null || value === undefined) return;
  throw new Error(
    `${message}: "${key}" muesste fehlen, war aber ${JSON.stringify(value)}`,
  );
}

// Values a model returns that must never pass as a number; Number() turns
// most of them silently into 0.
const UNPARSEABLE: Array<[string, unknown]> = [
  ["Zahl im Fliesstext", "186 kcal/100g"],
  ["reiner Text", "unbekannt"],
  ["leerer String", ""],
  ["nur Leerzeichen", "   "],
  ["NaN", NaN],
  ["Infinity", Infinity],
  ["-Infinity", -Infinity],
  ["undefined", undefined],
  ["null", null],
  ["leeres Objekt", {}],
  ["Objekt mit Wert", { value: 186 }],
  ["leeres Array", []],
  ["Array mit einer Zahl", [186]],
  ["boolean true", true],
  ["boolean false", false],
];

Deno.test("REGRESSION B1: unparsebares kcalPer100G wird null, nicht 0", () => {
  // Model writes the reference size as text; that used to log 0 kcal.
  const result = normalizeMealResult({
    mealName: "Pasta mit Hackfleischsauce",
    caloriesKcal: 780,
    estimatedGrams: 420,
    kcalPer100G: "186 kcal/100g",
  });

  assertMissing(result, "kcalPer100G", "Textwert darf keine Zahl werden");
  assert(
    result.kcalPer100G !== 0,
    "kcalPer100G === 0 ist genau der B1-Bug: (0 * g / 100) = 0 kcal im Tagebuch",
  );
  // The authoritative fields stay untouched.
  assertEquals(result.caloriesKcal, 780, "caloriesKcal bleibt erhalten");
  assertEquals(result.estimatedGrams, 420, "estimatedGrams bleibt erhalten");
});

Deno.test("REGRESSION B1: unparsebares caloriesKcal/estimatedGrams wird null, nicht 0", () => {
  const result = normalizeMealResult({
    mealName: "Teller",
    caloriesKcal: "ca. 780 kcal",
    estimatedGrams: "etwa 420 g",
    kcalPer100G: 186,
  });

  assertMissing(result, "caloriesKcal", "Textwert darf keine 0 kcal werden");
  assertMissing(result, "estimatedGrams", "Textwert darf keine 0 g werden");
  assert(result.caloriesKcal !== 0, "0 kcal waere eine erfundene Gesundheitszahl");
  assert(result.estimatedGrams !== 0, "0 g waere eine erfundene Gesundheitszahl");
  assertEquals(result.kcalPer100G, 186, "der gueltige Wert bleibt");
});

Deno.test("alle unparsebaren Formen ergeben null, nicht min", () => {
  for (const [label, value] of UNPARSEABLE) {
    const result = normalizeMealResult({
      caloriesKcal: value,
      estimatedGrams: value,
      kcalPer100G: value,
      proteinG: value,
      carbsG: value,
      fatG: value,
    });
    for (const key of ["caloriesKcal", "estimatedGrams", "kcalPer100G", "proteinG", "carbsG", "fatG"]) {
      assertMissing(result, key, `${label} (${key})`);
    }
  }
});

Deno.test("fehlende Schluessel erfinden keine Nullwerte", () => {
  // {} used to yield a full result of zeros, making the Dart fallback chain
  // unreachable in production.
  const result = normalizeMealResult({});
  assertMissing(result, "caloriesKcal", "leeres Objekt");
  assertMissing(result, "estimatedGrams", "leeres Objekt");
  assertMissing(result, "kcalPer100G", "leeres Objekt");
  // Labels keep their fallback: generic text, never a wrong NUMBER.
  assertEquals(result.mealName, "Mahlzeit", "mealName behaelt seinen Fallback");
  // E7: confidence is the model's own certainty, not a label, so it must
  // stay missing rather than default to "medium".
  assertEquals(result.confidence, null, "fehlende confidence bleibt fehlend");
});

Deno.test("kaputte confidence wird nicht zu 'medium' aufgehuebscht", () => {
  const result = normalizeMealResult({ confidence: "sehr sicher!!" });
  assertEquals(result.confidence, null, "unlesbare confidence bleibt fehlend");
});

Deno.test("gueltige Werte werden weiterhin geklemmt (max darf nicht kaputtgehen)", () => {
  const result = normalizeMealResult({
    caloriesKcal: 99999,
    estimatedGrams: 55555,
    kcalPer100G: 4200,
    proteinG: 9000,
  });
  assertEquals(result.caloriesKcal, 10000, "caloriesKcal auf max geklemmt");
  assertEquals(result.estimatedGrams, 10000, "estimatedGrams auf max geklemmt");
  assertEquals(result.kcalPer100G, 1000, "kcalPer100G auf max geklemmt");
  assertEquals(result.proteinG, 1000, "proteinG auf max geklemmt");

  const low = normalizeMealResult({ caloriesKcal: -50, kcalPer100G: -3 });
  assertEquals(low.caloriesKcal, 0, "negative Werte weiterhin auf min geklemmt");
  assertEquals(low.kcalPer100G, 0, "negative Werte weiterhin auf min geklemmt");
});

Deno.test("numerische Strings und Kommazahlen bleiben gueltig", () => {
  const result = normalizeMealResult({
    caloriesKcal: "780",
    estimatedGrams: " 420 ",
    kcalPer100G: "185.7",
  });
  assertEquals(result.caloriesKcal, 780, "numerischer String wird uebernommen");
  assertEquals(result.estimatedGrams, 420, "umschliessende Leerzeichen stoeren nicht");
  assertEquals(result.kcalPer100G, 185.7, "Nachkommastellen bleiben erhalten");

  const rounded = normalizeMealResult({ caloriesKcal: 780.6, estimatedGrams: 419.4 });
  assertEquals(rounded.caloriesKcal, 781, "int-Felder werden gerundet");
  assertEquals(rounded.estimatedGrams, 419, "int-Felder werden gerundet");
});

Deno.test("items[]: unparsebare Werte werden null, nicht 0", () => {
  const result = normalizeMealResult({
    items: [
      { name: "Pasta", grams: 250, caloriesKcal: 390, kcalPer100G: "156 kcal/100g" },
      { name: "Sauce", grams: "reichlich", caloriesKcal: "?", kcalPer100G: 130 },
      { name: "Parmesan", grams: 20, caloriesKcal: 86, kcalPer100G: 431 },
    ],
  });
  const items = result.items as unknown as Array<Record<string, unknown>>;
  assertEquals(items.length, 3, "alle Items bleiben erhalten");

  assertMissing(items[0], "kcalPer100G", "Item 0");
  assertEquals(items[0].grams, 250, "Item 0 behaelt gueltige Gramm");
  assertEquals(items[0].caloriesKcal, 390, "Item 0 behaelt gueltige Kalorien");

  assertMissing(items[1], "grams", "Item 1");
  assertMissing(items[1], "caloriesKcal", "Item 1");
  assertEquals(items[1].kcalPer100G, 130, "Item 1 behaelt den gueltigen Wert");

  assertEquals(items[2].grams, 20, "Item 2 unveraendert");
  assertEquals(items[2].caloriesKcal, 86, "Item 2 unveraendert");
  assertEquals(items[2].kcalPer100G, 431, "Item 2 unveraendert");
  assertEquals(items[2].name, "Parmesan", "Namen bleiben Strings");
});

Deno.test("optionalInt/optionalNumber: Einzelverhalten", () => {
  assertEquals(optionalInt("keine Angabe", 0, 100), null, "Text -> null");
  assertEquals(optionalInt("", 0, 100), null, "leerer String -> null (Number('') === 0!)");
  assertEquals(optionalInt(null, 0, 100), null, "null -> null (Number(null) === 0!)");
  assertEquals(optionalInt(false, 0, 100), null, "boolean -> null (Number(false) === 0!)");
  assertEquals(optionalInt([], 0, 100), null, "Array -> null (Number([]) === 0!)");
  assertEquals(optionalInt(42.4, 0, 100), 42, "Zahl wird gerundet");
  assertEquals(optionalInt(420, 0, 100), 100, "Zahl wird auf max geklemmt");
  assertEquals(optionalNumber(-7, 0, 100), 0, "Zahl wird auf min geklemmt");
  assertEquals(optionalNumber(42.4, 0, 100), 42.4, "optionalNumber rundet nicht");
});

Deno.test("kcalPer100GMismatch meldet nur echte Widersprueche", () => {
  // 260 * 300 / 100 = 780, but the model claims 850.
  const mismatch = kcalPer100GMismatch(850, 300, 260);
  assert(mismatch !== null, "260 vs. implizite 283.3 ist ein Widerspruch");
  assertEquals(Math.round(mismatch!.implied), 283, "impliziter Wert wird berechnet");

  // Rounding to whole kcal/grams must not count as a contradiction.
  assertEquals(kcalPer100GMismatch(781, 300, 260.3), null, "Rundungsrauschen");
  assertEquals(kcalPer100GMismatch(780, 300, 260), null, "exakt konsistent");
  // Nothing to compare without complete values.
  assertEquals(kcalPer100GMismatch(null, 300, 260), null, "unvollstaendig");
  assertEquals(kcalPer100GMismatch(850, null, 260), null, "unvollstaendig");
  assertEquals(kcalPer100GMismatch(850, 300, null), null, "unvollstaendig");
  assertEquals(kcalPer100GMismatch(0, 300, 260), null, "0 ist kein Vergleichswert");
});

Deno.test("der Widerspruch aus B1 wird NICHT serverseitig ueberschrieben", () => {
  // index.ts logs the contradiction but cannot decide which of the three is
  // wrong, and dropping kcalPer100G only buys a name-based estimate.
  const result = normalizeMealResult({
    caloriesKcal: 850,
    estimatedGrams: 300,
    kcalPer100G: 260,
  });
  assertEquals(result.caloriesKcal, 850, "Modellwert bleibt unangetastet");
  assertEquals(result.estimatedGrams, 300, "Modellwert bleibt unangetastet");
  assertEquals(result.kcalPer100G, 260, "Modellwert bleibt unangetastet");
});

// --- Log redaction (security review 2026-08-11, finding 4, CWE-532) --------
//
// index.ts used to log `raw: rawContent.slice(0, 500)`, leaking photo- and
// hint-derived content. Log metadata now comes only from redactedContentMeta
// and unparseableShape, which these tests prove carry no content.

Deno.test("CWE-532: redactedContentMeta traegt keinen Inhalt, nur Laenge + Digest", async () => {
  // Worst case: the model quotes the user's free-text hint in broken JSON.
  const secret = 'Ich esse low-carb wegen Diabetes Typ 2 {"mealName": "Sala';
  const meta = await redactedContentMeta(secret);

  const logged = JSON.stringify(meta);
  assert(!logged.includes("Diabetes"), "Klartext darf nicht im Log-Objekt landen");
  assert(!logged.includes(secret.slice(0, 16)), "auch kein Praefix des Inhalts");

  assertEquals(meta.len, secret.length, "Laenge bleibt als Debug-Metadatum");
  assert(/^[0-9a-f]{12}$/.test(meta.sha256), "Digest ist ein 12-Zeichen-Hex-Praefix");
  assertEquals(Object.keys(meta).length, 2, "Allowlist: exakt len + sha256, sonst nichts");
});

Deno.test("CWE-532: Digest ist deterministisch und inhaltsabhaengig (Dedupe)", async () => {
  // Known vector, pinning the algorithm so a later rewrite cannot silently
  // invalidate log correlation.
  assertEquals((await redactedContentMeta("")).sha256, "e3b0c44298fc", "SHA-256-Leerstring-Vektor");

  const a1 = await redactedContentMeta("kein json A");
  const a2 = await redactedContentMeta("kein json A");
  const b = await redactedContentMeta("kein json B");
  assertEquals(a1.sha256, a2.sha256, "gleicher Inhalt -> gleicher Digest");
  assert(a1.sha256 !== b.sha256, "anderer Inhalt -> anderer Digest");
});

Deno.test("CWE-532: unparseableShape kategorisiert ohne Inhalt", () => {
  // 'empty': extractJson can turn "```json\n```" into an empty string even
  // though rawContent was not empty.
  assertEquals(unparseableShape("", new SyntaxError("x")), "empty", "leer nach extractJson");
  assertEquals(unparseableShape("   ", new SyntaxError("x")), "empty", "nur Whitespace");
  // JSON.parse throws SyntaxError -> not_json (truncated or no JSON).
  assertEquals(unparseableShape('{"a": 1', new SyntaxError("x")), "not_json", "abgeschnittenes JSON");
  // The isRecord guard in index.ts throws a plain Error -> not_object.
  assertEquals(unparseableShape("[1, 2]", new Error("not an object")), "not_object", "Array statt Objekt");
});
