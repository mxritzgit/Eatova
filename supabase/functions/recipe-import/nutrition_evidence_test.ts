import { parseExtraction } from './extraction.ts';
import { sourcedNutrition } from './nutrition.ts';

function check(value: unknown, message: string): asserts value {
  if (!value) throw new Error(message);
}

const values = { calories_kcal: 326, protein_g: 32, carbs_g: 31, fat_g: 7 };
const figures = '326 kcal\n31g carbs\n7g fat\n32g protein';

function raw(evidence: string, overrides: Record<string, unknown> = {}, servings: number | null = null) {
  return sourcedNutrition({ nutrition_basis: 'per_recipe', ...values, ...overrides },
    evidence, servings, true, servings === null ? '' : `For ${servings} servings`);
}

function sourceValues(result: ReturnType<typeof raw>, divisor = 1) {
  for (const [key, value] of Object.entries(values)) {
    check(result[key as keyof typeof values] === value / divisor, `${key} must come from the source`);
  }
}

Deno.test('reported Oreo whole-dessert nutrition survives without an invented serving yield', async () => {
  const nutrition = `Macros for whole desert: ${figures}`;
  const ingredients = ['180g 0% Greek yogurt', '15g vanilla protein powder', '3 oreo cookies'];
  const preparation = ['Mix the yogurt with the protein, add sweetener if desired',
    'Break up one Oreo into the mix and whisk around until it’s smooth',
    'Layer first the half yogurt mix, then Oreo and again yogurt mix',
    'Crumple up one Oreo on top and enjoy'];
  const result = await parseExtraction(JSON.stringify({ status: 'ready', candidates: [{
    title: 'High Protein Oreo Dessert', ingredient_quotes: ingredients,
    preparation_quotes: preparation, nutrition_quote: nutrition,
    nutrition_basis: 'per_recipe', servings: null, servings_quote: '', ...values,
  }] }), { source: { url: null }, text: [...ingredients, ...preparation, nutrition].join('\n'),
    incomplete: false, truncated: false }, 2);
  const recipe = result?.candidates[0];
  check(recipe, 'A recipe must be returned');
  sourceValues(recipe);
  check(recipe.nutrition_basis === 'unspecified' && recipe.servings === null,
    'Whole-dessert values stay visible while their serving count is unconfirmed');
  check(recipe.preparation.includes('enjoy'), 'Source preparation is retained');
  check(!result?.warnings.includes('nutrition_missing'), 'Known values are not labelled missing');
});

Deno.test('unfamiliar nutrition headings retain values independently of model basis labels', () => {
  for (const heading of [
    'Macros for whole desert', 'Nutritional values for this pudding',
    'Nährwerte für die komplette Auflaufform', 'Nutrition of my overnight oats',
    'Nährwerte (2 Gläser)', 'My macros', '',
  ]) {
    for (const basis of ['per_recipe', 'per_serving', 'unspecified', 'per_100g']) {
      const result = raw(`${heading}: ${figures}`, { nutrition_basis: basis });
      sourceValues(result);
      check(result.nutrition_basis === 'unspecified', 'Unproven serving basis must not be invented');
    }
  }
});

Deno.test('unfamiliar scope wording never authorizes conversion even with a recipe yield', () => {
  for (const heading of [
    'Macros for whole desert', 'Nutrition for the entire casserole',
    'Nutrition for the whole cake', 'Nutrition for whole grain bread',
    'Nährwerte für das gesamte Gericht', 'Nährwerte für die ganze Auflaufform',
  ]) {
    const result = raw(`${heading}: ${figures}`, {}, 2);
    sourceValues(result);
    check(result.nutrition_basis === 'unspecified', 'Recipe yield cannot prove the nutrition reference');
  }
  for (const heading of ['Entire recipe', 'Macros for the full batch', 'Total', 'Gesamt']) {
    const result = raw(`${heading}: ${figures}`, {}, 2);
    sourceValues(result, 2);
    check(result.nutrition_basis === 'per_serving', 'Explicit totals can use a proven yield');
  }
});

Deno.test('known numbers are preserved when their mass or fractional reference needs user review', () => {
  for (const heading of [
    'Per 100 g', 'Per 100 ml', 'For half the cake', 'Nährwerte für 1/2 Kuchen',
    'Nutrition for 2 slices',
  ]) {
    const result = raw(`${heading}: ${figures}`, {}, 4);
    sourceValues(result);
    check(result.nutrition_basis === 'unspecified', 'A recipe yield must not scale a different reference');
    const legacy = sourcedNutrition({ nutrition_basis: 'per_recipe', ...values },
      `${heading}: ${figures}`, 4, false, 'For 4 servings');
    check(legacy.calories_kcal === null, 'Legacy clients cannot display unresolved reference values safely');
  }
});

Deno.test('source-backed fields omitted by the model can be recovered without inventing missing values', () => {
  const result = raw(`Macros: ${figures}`, { calories_kcal: null, protein_g: null,
    carbs_g: null, fat_g: null, nutrition_basis: 'unspecified' });
  sourceValues(result);
  const partial = raw('Macros: 326 kcal, 32g protein, 0g fat', {
    calories_kcal: null, protein_g: null, carbs_g: null, fat_g: null,
  });
  check(partial.calories_kcal === 326 && partial.protein_g === 32 &&
    partial.fat_g === 0 && partial.carbs_g === null, 'Missing differs from an explicit zero');
});

Deno.test('raw fallback never combines distinct blocks or uses an unrelated model value', () => {
  for (const text of [
    `Macros for the cake: ${figures}\nMacros for the topping: 120 kcal, 5g protein`,
    'Macros for the cake: 326 kcal. Macros for the filling: 32g protein, 31g carbs, 7g fat.',
    `Per 100 g: ${figures}\nPer serving: ${figures}`,
  ]) {
    const result = raw(text);
    check(result.calories_kcal === null && result.protein_g === null,
      'Ambiguous quoted blocks need a narrower source quote');
  }
  const swapped = raw(`Macros for whole desert: ${figures}`, { protein_g: 31, carbs_g: 32 });
  check(swapped.calories_kcal === 326 && swapped.protein_g === null &&
    swapped.carbs_g === null, 'Numbers remain bound to their nutrient labels');
});

Deno.test('no caption proof still means unknown nutrition', async () => {
  const result = await parseExtraction(JSON.stringify({ status: 'ready', candidates: [{
    title: 'Dessert', ingredient_quotes: ['180g yogurt'], preparation_quotes: ['Mix.'],
    nutrition_basis: 'per_recipe', nutrition_quote: `Macros: ${figures}`, ...values,
  }] }), { source: { url: null }, text: '180g yogurt. Mix.', incomplete: false, truncated: false }, 2);
  check(result?.candidates[0].calories_kcal === null && result.candidates[0].protein_g === null,
    'Invented nutrition quotes cannot contribute values');
});

Deno.test('recovery respects numeric tokens, ingredient names and normalized typography', () => {
  const unknown = { nutrition_basis: 'unspecified', calories_kcal: null,
    protein_g: null, carbs_g: null, fat_g: null };
  for (const evidence of [
    'Macros: 15g protein powder, 7g fat free yogurt',
    'Macros: Protein: 32-34g, fat: 7 to 9g',
    'Macros: 32–34g protein, 1/2g fat',
    'Macros: Protein: 1e3 g, fat: 7.2.3 g',
  ]) {
    const result = raw(evidence, unknown);
    check(result.protein_g === null && result.fat_g === null,
      'Neither ingredient amounts nor fragments of ambiguous numbers are nutrition: ' + evidence);
  }
  const result = raw('Macros: ３２６ kcal, ３２ g protein, ３１ g carbs, ７ g fat', unknown);
  sourceValues(result);
  sourceValues(raw('Macros: 326 kcal protein: 32g carbs: 31g fat: 7g', unknown));
  sourceValues(raw('Macros: Protein32g Carbs31g Fat7g Calories326', unknown));
  sourceValues(raw('At 326 kcal with 32g protein and 31g carbs and 7g fat this is easy.', unknown));
});

Deno.test('a total-fat label does not turn an unqualified table into recipe totals', () => {
  const result = raw('Calories: 326, protein: 32g, carbs: 31g, total fat: 7g', {}, 2);
  sourceValues(result);
  check(result.nutrition_basis === 'unspecified', 'Nutrient names are not serving bases');
});

Deno.test('fractional references cannot become a whole dish through typography normalization', () => {
  for (const fraction of ['½', '¼', '1/2', '1⁄2']) {
    const result = sourcedNutrition({ nutrition_basis: 'per_recipe', ...values },
      `Macros for ${fraction} pizza: ${figures}`, 1, true, 'Makes one pizza');
    sourceValues(result);
    check(result.nutrition_basis === 'unspecified', 'A fraction must stay unconfirmed');
  }
});
