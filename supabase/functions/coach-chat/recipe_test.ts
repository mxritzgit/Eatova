// Tests fuer die pure Rezept-Logik (recipe.ts) — kein fetch, kein Deno.env.
// Bewusst ohne externe Test-Dependencies (gleicher Stil wie prefilter_test.ts).

import {
  parseRecipeDraft,
  parseRecipeRefusal,
  RECIPE_LIMITS,
  recipeImagePrompt,
  recipeSummary,
  recipeSystemPrompt,
} from "./recipe.ts";

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

const VALID = JSON.stringify({
  title: "Huehnchenauflauf",
  description: "Cremiger Auflauf mit viel Protein.",
  portion: "1 grosse Auflaufform-Portion",
  ingredients: "- 250 g Haehnchenbrust\n- 150 g Brokkoli",
  preparation: "1. Ofen vorheizen.\n2. Alles schichten und backen.",
  calories_kcal: 520,
  protein_g: 48,
  carbs_g: 32,
  fat_g: 18,
  estimated_g: 450,
});

Deno.test("gueltiges JSON roundtrippt mit allen Feldern", () => {
  const draft = parseRecipeDraft(VALID);
  assert(draft !== null, "Draft darf nicht null sein");
  assertEquals(draft!.title, "Huehnchenauflauf", "title");
  assertEquals(draft!.calories_kcal, 520, "kcal");
  assertEquals(draft!.protein_g, 48, "protein");
  assertEquals(draft!.estimated_g, 450, "gramm");
  assert(draft!.ingredients.includes("Haehnchenbrust"), "ingredients");
  assert(draft!.preparation.startsWith("1."), "preparation nummeriert");
});

Deno.test("Zahlen werden GEKLEMMT statt abgelehnt (KI-Werte)", () => {
  const draft = parseRecipeDraft(JSON.stringify({
    title: "Monsterportion",
    calories_kcal: 50000,
    protein_g: -5,
    carbs_g: 4000,
    fat_g: 12.7,
    estimated_g: 0,
  }));
  assert(draft !== null, "Draft darf nicht null sein");
  assertEquals(draft!.calories_kcal, RECIPE_LIMITS.kcalMax, "kcal auf Max geklemmt");
  assertEquals(draft!.protein_g, RECIPE_LIMITS.macroMin, "Protein auf Min geklemmt");
  assertEquals(draft!.carbs_g, RECIPE_LIMITS.macroMax, "KH auf Max geklemmt");
  assertEquals(draft!.fat_g, 13, "Kommazahl gerundet");
  assertEquals(draft!.estimated_g, RECIPE_LIMITS.gramsMin, "Gramm auf Min geklemmt");
});

Deno.test("Titel wird auf titleMaxChars gekappt", () => {
  const draft = parseRecipeDraft(JSON.stringify({
    title: "x".repeat(500),
    calories_kcal: 400,
  }));
  assert(draft !== null, "Draft darf nicht null sein");
  assertEquals(draft!.title.length, RECIPE_LIMITS.titleMaxChars, "Titel-Laenge");
});

Deno.test("JSON in Markdown-Fences wird extrahiert", () => {
  const draft = parseRecipeDraft("```json\n" + VALID + "\n```");
  assert(draft !== null, "Draft darf nicht null sein");
  assertEquals(draft!.title, "Huehnchenauflauf", "title aus Fence");
});

Deno.test("fehlender Titel oder fehlende kcal => null (unlesbar)", () => {
  assertEquals(
    parseRecipeDraft(JSON.stringify({ calories_kcal: 400 })),
    null,
    "ohne title",
  );
  assertEquals(
    parseRecipeDraft(JSON.stringify({ title: "Auflauf" })),
    null,
    "ohne kcal",
  );
  assertEquals(parseRecipeDraft("kein json"), null, "kein JSON");
  assertEquals(parseRecipeDraft(""), null, "leer");
});

Deno.test("recipeSummary nennt Titel + kcal in beiden Sprachen", () => {
  const draft = parseRecipeDraft(VALID)!;
  const de = recipeSummary(draft, "de");
  const en = recipeSummary(draft, "en");
  assert(de.includes("Huehnchenauflauf") && de.includes("520"), `de: ${de}`);
  assert(en.includes("Huehnchenauflauf") && en.includes("520"), `en: ${en}`);
  assert(de !== en, "Sprachen unterscheiden sich");
});

Deno.test("recipeSystemPrompt traegt Sprache + JSON-Refusal + JSON-Auftrag", () => {
  const de = recipeSystemPrompt("de");
  const en = recipeSystemPrompt("en");
  assert(de.includes("German"), "de-Prompt nennt German");
  assert(en.includes("English"), "en-Prompt nennt English");
  for (const p of [de, en]) {
    assert(p.includes('"refuse"'), "JSON-Refusal-Feld fehlt");
    assert(p.includes("calories_kcal"), "JSON-Schema fehlt");
    assert(p.includes("ONE"), "Genau-ein-Rezept-Auftrag fehlt");
  }
});

Deno.test("parseRecipeRefusal: refuse-Feld wird erkannt, sonst null", () => {
  assertEquals(
    parseRecipeRefusal('{"refuse": "Ich erstelle nur Essensrezepte."}'),
    "Ich erstelle nur Essensrezepte.",
    "Refusal-Satz",
  );
  assertEquals(parseRecipeRefusal(VALID), null, "normales Rezept ist keine Refusal");
  assertEquals(parseRecipeRefusal("kein json"), null, "kein JSON");
  assertEquals(parseRecipeRefusal('{"refuse": ""}'), null, "leere Refusal zaehlt nicht");
});

Deno.test("recipeImagePrompt nutzt den Titel und verbietet Text/Personen", () => {
  const draft = parseRecipeDraft(VALID)!;
  const prompt = recipeImagePrompt(draft);
  assert(prompt.includes("Huehnchenauflauf"), "Titel fehlt im Bild-Prompt");
  assert(/no text/i.test(prompt), "no-text-Regel fehlt");
  assert(/no people/i.test(prompt), "no-people-Regel fehlt");
});
