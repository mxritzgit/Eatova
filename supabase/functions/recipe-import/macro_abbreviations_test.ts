import { parseExtraction } from './extraction.ts';
import { sourcedNutrition } from './nutrition.ts';

function check(value: unknown, message: string): asserts value {
  if (!value) throw new Error(message);
}

const macros = { protein_g: 31, carbs_g: 13, fat_g: 9 };

function read(evidence: string, overrides: Record<string, unknown> = {}) {
  return sourcedNutrition({ nutrition_basis: 'unspecified', ...overrides }, evidence, null, true);
}

function checkMacros(value: ReturnType<typeof read>, expected = macros) {
  for (const field of ['protein_g', 'carbs_g', 'fat_g'] as const) {
    check(value[field] === expected[field], `${field}: expected ${expected[field]}, got ${value[field]}`);
  }
}

Deno.test('reported abbreviated caption keeps all macros through recipe extraction', async () => {
  const nutrition = '300 kcal 31g P   13g C  9g F';
  for (const values of [macros, { protein_g: null, carbs_g: null, fat_g: null }]) {
    const result = await parseExtraction(JSON.stringify({ status: 'ready', candidates: [{
      title: 'Bowl', ingredient_quotes: ['200 g yogurt'], preparation_quotes: ['Mix.'],
      nutrition_basis: 'unspecified', nutrition_quote: nutrition, calories_kcal: 300, ...values,
    }] }), { source: { url: null }, text: `200 g yogurt\nMix.\n${nutrition}`,
      incomplete: false, truncated: false }, 2);
    const candidate = result?.candidates[0];
    check(candidate, 'Recipe is retained');
    checkMacros(candidate);
    check(candidate.calories_kcal === 300 && candidate.nutrition_basis === 'unspecified',
      'Source values do not invent a serving basis');
    check(!result?.warnings.includes('nutrition_missing'), 'All four values are present');
  }
});

Deno.test('macro abbreviations accept compact, label-first and mixed captions', () => {
  for (const text of [
    '31g P   13g C  9g F',
    '31gP / 13gC / 9gF',
    '31 G p | 13 G c | 9 G f',
    'P: 31g C: 13g F: 9g',
    'P31g C13g F9g',
    'P = 31 g; C = 13 g; F = 9 g',
    '31g P\n13g C\n9g F',
    '31g P, carbs: 13g, 9g Fett',
    'Protein: 31g, 13g C, F: 9g',
    '31g P 13g KH 9g F',
    '３１ｇ Ｐ １３ｇ Ｃ ９ｇ Ｆ',
  ]) checkMacros(read(text));
});

Deno.test('abbreviated macros retain decimal grams, zero and genuinely missing values', () => {
  for (const text of ['31,5g P 13.25g C 0g F', 'P: 31.5g C: 13,25g F: 0g']) {
    checkMacros(read(text), { protein_g: 31.5, carbs_g: 13.25, fat_g: 0 });
  }
  const partial = read('31g P 0g F');
  check(partial.protein_g === 31 && partial.carbs_g === null && partial.fat_g === 0,
    'Missing carbs are distinct from zero fat');
});

Deno.test('abbreviated macros preserve source label ownership and reject conflicting values', () => {
  const swapped = read('31g P 13g C 9g F', { protein_g: 13, carbs_g: 31, fat_g: 9 });
  check(swapped.protein_g === null && swapped.carbs_g === null && swapped.fat_g === 9,
    'Model values cannot move between nutrient labels');
  for (const text of ['P: 31g P: 42g C: 13g F: 9g', 'P31g P42g C13g F9g']) {
    const conflict = read(text);
    check(conflict.protein_g === null && conflict.carbs_g === 13 && conflict.fat_g === 9,
      'Conflicting source protein is not guessed');
  }
  const partial = read('P: 31g C: F: 9g');
  check(partial.protein_g === 31 && partial.carbs_g === null && partial.fat_g === 9,
    'A label without a number cannot borrow another label\'s value');
});

Deno.test('single-letter macros require grams and never match ingredient names or temperatures', () => {
  for (const text of [
    '31g Parmesan, 13g Couscous, 9g Flour',
    '31g Pudding, 13g Chocolate, 9g Feta',
    'Bake at 180 C or 350 F',
    'Oven C: 180 F: 350',
    'Vitamin C: 13mg, Vitamin P: 31mg',
    'P: 31kg C: 13ml F: 9%',
    'P: 31garlic C: 13gramsauce F: 9ginger',
    '31 P 13 C 9 F',
    '31g Powder, 13g Caramel, 9g Fatfree yogurt',
  ]) {
    const value = read(text);
    check(value.protein_g === null && value.carbs_g === null && value.fat_g === null, text);
  }
});

Deno.test('macro abbreviations reject malformed quantities and ranges', () => {
  for (const text of [
    'P: 31-33g C: 13 to 15g F: 9/10g',
    '31–33g P 13/15g C 9.2.3g F',
    'P: 1e3g C: 13.2.3g F: -9g',
    '-31g P -13g C -9g F',
  ]) {
    const value = read(text);
    check(value.protein_g === null && value.carbs_g === null && value.fat_g === null, text);
  }
});

Deno.test('macro abbreviations respect serving conversion and legacy restrictions', () => {
  const row = { nutrition_basis: 'per_recipe', ...macros };
  const totals = sourcedNutrition(row, 'Total: 31g P 13g C 9g F', 2, true, 'For 2 servings');
  checkMacros(totals, { protein_g: 15.5, carbs_g: 6.5, fat_g: 4.5 });
  check(totals.nutrition_basis === 'per_serving', 'Only proven totals are scaled');
  const byWeight = sourcedNutrition({ ...row, nutrition_basis: 'per_100g' },
    'Per 100g: 31g P 13g C 9g F', 2, true, 'For 2 servings');
  checkMacros(byWeight);
  check(byWeight.nutrition_basis === 'unspecified', 'Per-100g values remain unconfirmed');
  const legacy = sourcedNutrition({ ...row, nutrition_basis: 'per_serving' },
    'Per serving: 31g P 13g C 9g F', null, false);
  checkMacros(legacy);
  const unqualified = sourcedNutrition({ ...row, nutrition_basis: 'unspecified' },
    '31g P 13g C 9g F', null, false);
  check(unqualified.protein_g === null, 'Legacy clients still require a proven basis');
});
