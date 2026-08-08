// Tests fuer normalizeMealResult (normalize.ts).
//
// Der eigentliche Regressionstest steht unter "REGRESSION: unparsebare
// Zahlen werden null, nicht 0" (Review 2026-08-08, B1):
//
//   clampNumber/clampInt gaben bei einem nicht-parsebaren Wert `min` = 0
//   zurueck. Liefert das Modell "186 kcal/100g" als STRING statt als Zahl,
//   stand im Wire-Vertrag `kcalPer100G: 0` — die Karte zeigte 780 kcal, das
//   Tagebuch bekam nach "Portion anpassen" (kcalPer100G * g / 100) aber 0.
//   Still falsche Gesundheitszahlen, ohne Fehler, ohne Hinweis.
//
// Die Gegenprobe steht unter "gueltige Werte werden weiterhin geklemmt":
// das Klemmen auf max ist gewollt und darf beim Fix nicht mitsterben.
//
// Bewusst ohne externe Test-Dependencies (gleicher Stil wie prefilter_test.ts).

import {
  kcalPer100GMismatch,
  normalizeMealResult,
  optionalInt,
  optionalNumber,
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

/**
 * "Fehlt" = null ODER Schluessel gar nicht gesetzt. Beide Formen sind fuer die
 * Dart-Seite identisch (_readInt/_readDouble pruefen `value is int/double/String`
 * — ein JSON-null faellt genauso durch wie ein fehlender Schluessel), deshalb
 * pruefen die Tests bewusst nicht auf die exakte Form.
 */
function assertMissing(result: object, key: string, message: string): void {
  const value = (result as Record<string, unknown>)[key];
  if (value === null || value === undefined) return;
  throw new Error(
    `${message}: "${key}" muesste fehlen, war aber ${JSON.stringify(value)}`,
  );
}

// Werte, die ein Modell real liefert und die NIEMALS als Zahl durchgehen
// duerfen. Number() macht aus den meisten davon still eine 0 —
// Number("") === 0, Number(null) === 0, Number([]) === 0, Number(false) === 0.
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
  // Das Szenario aus dem Review: 780-kcal-Teller, das Modell schreibt die
  // Bezugsgroesse als Text. Vorher: kcalPer100G === 0 -> "Anpassen" ohne
  // Aenderung loggte 0 kcal.
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
  // Die authoritativen Felder bleiben unangetastet.
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
  // Vorher lieferte {} ein vollstaendiges Ergebnis mit lauter Nullen —
  // die Dart-Fallback-Kette (_extractFirstInt/_estimateGramsFromText/
  // _knownKcalPer100G) war dadurch in Produktion unerreichbar.
  const result = normalizeMealResult({});
  assertMissing(result, "caloriesKcal", "leeres Objekt");
  assertMissing(result, "estimatedGrams", "leeres Objekt");
  assertMissing(result, "kcalPer100G", "leeres Objekt");
  // Labels haben weiterhin ihren Fallback — ein fehlender Name erzeugt keine
  // falsche ZAHL, nur einen generischen Text.
  assertEquals(result.mealName, "Mahlzeit", "mealName behaelt seinen Fallback");
  // Sentinel-Rest E7: confidence ist KEIN Label, sondern die Aussage des
  // Modells ueber die eigene Sicherheit — der Nutzer bemisst daran, wie sehr
  // er der kcal-Zahl traut. Die erste Fassung dieses Tests pinnte "medium"
  // als Fallback und verstiess damit gegen den Leitsatz dieser Datei
  // (Zeile 8-18: Wert des Modells oder "fehlt").
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
  // Review-Beispiel: 260 * 300 / 100 = 780, das Modell behauptet 850.
  const mismatch = kcalPer100GMismatch(850, 300, 260);
  assert(mismatch !== null, "260 vs. implizite 283.3 ist ein Widerspruch");
  assertEquals(Math.round(mismatch!.implied), 283, "impliziter Wert wird berechnet");

  // Rundung auf ganze kcal/Gramm darf nicht als Widerspruch gelten.
  assertEquals(kcalPer100GMismatch(781, 300, 260.3), null, "Rundungsrauschen");
  assertEquals(kcalPer100GMismatch(780, 300, 260), null, "exakt konsistent");
  // Ohne vollstaendige Angaben gibt es nichts zu vergleichen.
  assertEquals(kcalPer100GMismatch(null, 300, 260), null, "unvollstaendig");
  assertEquals(kcalPer100GMismatch(850, null, 260), null, "unvollstaendig");
  assertEquals(kcalPer100GMismatch(850, 300, null), null, "unvollstaendig");
  assertEquals(kcalPer100GMismatch(0, 300, 260), null, "0 ist kein Vergleichswert");
});

Deno.test("der Widerspruch aus B1 wird NICHT serverseitig ueberschrieben", () => {
  // Bewusste Entscheidung: die Function meldet den Widerspruch (Logging in
  // index.ts), korrigiert ihn aber nicht. Wer von den dreien falsch liegt,
  // ist serverseitig nicht entscheidbar; ein Weglassen von kcalPer100G wuerde
  // die Dart-Seite zuerst in _knownKcalPer100G(mealName) schicken — eine
  // namensbasierte DB-Schaetzung, die zu caloriesKcal genauso wenig passt.
  const result = normalizeMealResult({
    caloriesKcal: 850,
    estimatedGrams: 300,
    kcalPer100G: 260,
  });
  assertEquals(result.caloriesKcal, 850, "Modellwert bleibt unangetastet");
  assertEquals(result.estimatedGrams, 300, "Modellwert bleibt unangetastet");
  assertEquals(result.kcalPer100G, 260, "Modellwert bleibt unangetastet");
});
