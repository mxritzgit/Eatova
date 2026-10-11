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

Deno.test('grouped kcal totals keep their thousands and are never read as decimals', () => {
  const total = (evidence: string, calories: number | null, v2 = true) => sourcedNutrition({ nutrition_basis: 'per_recipe',
    calories_kcal: calories, protein_g: 120, carbs_g: 200, fat_g: 80 }, evidence, 4, v2, 'Für 4 Portionen').calories_kcal;
  const dot = 'Nährwerte gesamt: 2.450 kcal, 120 g Protein, 200 g KH, 80 g Fett';
  check(total(dot, 2450) === 612.5, 'The model reading of 2.450 kcal is source-proven');
  check(total(dot, null) === 612.5, 'Recovery reads 2.450 kcal as 2450, never 0.6125 per serving');
  // The prompt asks for numbers exactly as written, so 2.450 can arrive as 2.45.
  check(total(dot, 2.45) === 612.5, 'A literal 2.45 model copy of 2.450 kcal is the grouped 2450');
  check(total(dot, 2.45, false) === 612.5, 'v1 reads the literal copy as 2450 as well');
  check(total(dot, 2.5) === null && total(dot, 245) === null, 'Other model values stay unproven');
  const english = (calories: number | null) => sourcedNutrition({ nutrition_basis: 'per_serving', calories_kcal: calories,
    protein_g: 60, carbs_g: 100, fat_g: 40 }, 'Per serving: 1,050 calories, 60g protein, 100g carbs, 40g fat', 2, true).calories_kcal;
  check(english(1050) === 1050 && english(null) === 1050, 'English thousands separator');
  check(english(1.05) === 1050, 'A literal 1.05 model copy of 1,050 calories is 1050');
  const totalEnglish = sourcedNutrition({ nutrition_basis: 'per_recipe', calories_kcal: 1.05 },
    'Total: 1,050 calories, 60g protein', 2, true, 'For 2 servings');
  check(totalEnglish.calories_kcal === 525, `1,050 calories copied as 1.05 are 525 per serving: ${JSON.stringify(totalEnglish)}`);
  const legacy = sourcedNutrition({ nutrition_basis: 'per_serving', calories_kcal: 2.45 }, 'Pro Portion: 2.450 kcal', null, false);
  check(legacy.calories_kcal === 2450, `v1 per serving reads a literal 2.45 as 2450: ${JSON.stringify(legacy)}`);
  const unknown = { nutrition_basis: 'unspecified', calories_kcal: null };
  const twice = sourcedNutrition(unknown, 'Nährwerte: 2.450 kcal (2450 kcal)', null, true);
  check(twice.calories_kcal === 2450 && !twice.nutrition_conflicts, 'One total in two spellings is no conflict');
  check(sourcedNutrition({ ...unknown, calories_kcal: 2.45 }, 'Nährwerte: 2.450 kcal (2450 kcal)', null, true)
    .calories_kcal === 2450, 'A literal copy agrees with the same total in another spelling');
  const conflict = sourcedNutrition(unknown, 'Nährwerte: 2.450 kcal, 2.540 kcal', null, true);
  check(conflict.calories_kcal === null && conflict.nutrition_conflicts?.includes('calories_kcal'), 'Distinct totals conflict');
  const copiedConflict = sourcedNutrition({ ...unknown, calories_kcal: 2.45 }, 'Nährwerte: 2.450 kcal, 2.540 kcal', null, true);
  check(copiedConflict.calories_kcal === null && copiedConflict.nutrition_conflicts?.includes('calories_kcal'),
    'A literal copy cannot settle distinct totals');
  // A space can group thousands or separate two numbers: the model decides.
  for (const space of [' ', '\u202f', '\u00a0']) {
    const grouped = `Nährwerte gesamt: 2${space}450 kcal, 120 g Protein, 200 g KH, 80 g Fett`;
    check(total(grouped, 2450) === 612.5, `2${space}450 kcal with the model's 2450`);
    check(total(grouped, null) === null, `2${space}450 kcal is not recovered as 450 kcal (112.5 per serving)`);
  }
  const labelFirst = (calories: number | null) => sourcedNutrition({ nutrition_basis: 'per_serving', calories_kcal: calories },
    'Pro Portion: Kalorien: 2 450, Protein: 30 g', null, true).calories_kcal;
  check(labelFirst(2450) === 2450 && labelFirst(null) === null, 'Kalorien: 2 450 is never 2 kcal');
  // Grams keep their decimals; a flattened caption keeps adjacent numbers apart.
  const grams = sourcedNutrition({ nutrition_basis: 'unspecified', fat_g: 1.125, carbs_g: 12.5 },
    'Nährwerte: 1,125 g Fett, 12,5 g KH', null, true);
  check(grams.fat_g === 1.125 && grams.carbs_g === 12.5, 'Decimal grams stay decimal');
  const flat = sourcedNutrition({ nutrition_basis: 'unspecified', calories_kcal: 520, carbs_g: 100 },
    'Kalorien 520 100g KH', null, true);
  check(flat.calories_kcal === 520 && flat.carbs_g === 100, 'Adjacent kcal and carbs stay separate');
});

Deno.test('a grouped reading no field can hold leaves adjacent numbers recoverable', () => {
  const missing = (evidence: string) => sourcedNutrition({ nutrition_basis: 'unspecified', calories_kcal: null,
    protein_g: null, carbs_g: null, fat_g: null }, evidence, null, true);
  const flat = missing('Kalorien 520 100g KH');
  check(flat.calories_kcal === 520 && flat.carbs_g === 100, `520 100 kcal is no reading: ${JSON.stringify(flat)}`);
  const proteinFirst = missing('Nährwerte: Protein 30 450 kcal');
  check(proteinFirst.protein_g === 30 && proteinFirst.calories_kcal === 450,
    `30 450 g protein is no reading: ${JSON.stringify(proteinFirst)}`);
  const grams = missing('Nährwerte: 1,125 g Fett');
  check(grams.fat_g === 1.125 && !grams.nutrition_conflicts, `1125 g fat is no reading: ${JSON.stringify(grams)}`);
  // Two readings within range stay the model's decision.
  check(missing('Nährwerte: 2 450 kcal').calories_kcal === null, '2 450 kcal stays ambiguous');
  check(missing('Nährwerte: 1.000 g Fett').fat_g === null, '1.000 g fat stays ambiguous');
});

Deno.test('a space-grouped fragment is never the only reading of a kcal value', () => {
  const perServing = (evidence: string, calories: number | null) =>
    sourcedNutrition({ nutrition_basis: 'per_serving', calories_kcal: calories }, evidence, null, true);
  // A range cuts off the leading group: neither 400 nor 1400 is the value.
  for (const dash of ['-', '–', ' - ']) {
    const evidence = `Pro Portion: 1 200${dash}1 400 kcal`;
    const recovered = perServing(evidence, null);
    check(recovered.calories_kcal === null, `${evidence} is not recovered as 400: ${JSON.stringify(recovered)}`);
    check(recovered.nutrition_conflicts?.includes('calories_kcal') === true, `${evidence} is flagged for review`);
    check(perServing(evidence, 400).calories_kcal === null && perServing(evidence, 1400).calories_kcal === null,
      `${evidence}: no model value settles a range`);
  }
  check(perServing('Pro Portion: 400-1 400 kcal', null).calories_kcal === null, '400-1 400 kcal is not 400');
  // A grouped tail the field cannot hold is shortened, not dropped.
  const flattened = 'Pro Portion: Kalorien 1 450 100g KH';
  const recovered = perServing(flattened, null);
  check(recovered.calories_kcal === null && recovered.carbs_g === 100,
    `Kalorien 1 450 is not recovered as 1 kcal: ${JSON.stringify(recovered)}`);
  check(perServing(flattened, 1450).calories_kcal === 1450, 'The model reading 1450 is source-proven');
  // Unchanged: one plain group still reads both ways, and an adjacent number stays apart.
  check(perServing('Pro Portion: 1 450 kcal', 1450).calories_kcal === 1450, '1 450 kcal with the model reading');
  check(perServing('Pro Portion: Kalorien 520 100g KH', null).calories_kcal === 520, '520 100 is no tail');
});

Deno.test('a space-grouped kcal row after a blank line stays in its nutrition section', async () => {
  // Plain, no-break, six-per-em, thin, figure and narrow no-break spaces.
  for (const space of [' ', ' ', ' ', ' ', ' ', ' ']) {
    const nutrition = `Nährwerte gesamt:\n120 g Protein, 200 g KH\n\n2${space}450 kcal\n80 g Fett`;
    const text = `Für 4 Portionen\n800 g Hackfleisch\nAlles anbraten.\n\n${nutrition}`;
    const result = await parseExtraction(JSON.stringify({ status: 'ready', candidates: [{
      title: 'Hack', ingredient_quotes: ['800 g Hackfleisch'], preparation_quotes: ['Alles anbraten.'],
      servings: 4, servings_quote: 'Für 4 Portionen', nutrition_quote: nutrition, nutrition_basis: 'per_recipe',
      calories_kcal: 2450, protein_g: 120, carbs_g: 200, fat_g: 80,
    }] }), { source: { url: null }, text, incomplete: false, truncated: false }, 2);
    const recipe = result?.candidates[0];
    check(recipe?.calories_kcal === 612.5 && recipe.protein_g === 30 && recipe.fat_g === 20,
      `Complete section per serving with U+${space.charCodeAt(0).toString(16)}: ${JSON.stringify(recipe)}`);
  }
});

Deno.test('fractional references cannot become a whole dish through typography normalization', () => {
  for (const fraction of ['½', '¼', '1/2', '1⁄2']) {
    const result = sourcedNutrition({ nutrition_basis: 'per_recipe', ...values },
      `Macros for ${fraction} pizza: ${figures}`, 1, true, 'Makes one pizza');
    sourceValues(result);
    check(result.nutrition_basis === 'unspecified', 'A fraction must stay unconfirmed');
  }
});
