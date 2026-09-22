import { parseExtraction } from './extraction.ts';
import { sourcedNutrition } from './nutrition.ts';

function check(value: unknown, message: string): asserts value {
  if (!value) throw new Error(message);
}

const nutrition = '📊 Nährwerte (1 Bowl):\n425 kcal\n48 g Protein\n39 g Kohlenhydrate\n8 g Fett';
const ingredients = ['- 1 Ei', '- 50 g Skyr', '- 70 ml ungesüßte Mandelmilch',
  '- 35 g Mehl', '- 75 g TK-Beerenmix', '- 40 g Designer Whey'];

async function extract(basis: string, yieldText = '') {
  const content = {
    source: { url: null },
    text: `Gesunde High Protein Pancake Bowls\n${yieldText}\n${nutrition}\n🛒 Zutaten:\n${ingredients.join('\n')}`,
    incomplete: false,
    truncated: false,
  };
  return await parseExtraction(JSON.stringify({ status: 'ready', candidates: [{
    title: 'Healthy High Protein Pancake Bowl', ingredient_quotes: ingredients,
    preparation_quotes: [], portion_quote: '1 Bowl',
    servings: yieldText ? 2 : 1,
    servings_quote: yieldText || '1 Bowl',
    nutrition_basis: basis, nutrition_quote: nutrition,
    calories_kcal: 425, protein_g: 48, carbs_g: 39, fat_g: 8,
  }] }), content, 2);
}

Deno.test('reported Bowl caption retains all four source values', async () => {
  const result = await extract('per_serving');
  const bowl = result?.candidates[0];
  check(result?.status === 'ready' && bowl?.calories_kcal === 425 &&
    bowl.protein_g === 48 && bowl.carbs_g === 39 && bowl.fat_g === 8 &&
    bowl.nutrition_basis === 'per_serving', 'Caption values copied as one Bowl');
  check(bowl.servings === null && bowl.portion === '1 Bowl',
    'Nutrition for one Bowl is not proof of the whole recipe yield');
  check(!result.warnings.includes('nutrition_missing') &&
    result.warnings.includes('source_incomplete'), 'Only absent preparation is flagged');
});

Deno.test('an explicit Bowl basis wins over uncertain model labels or a larger yield', async () => {
  for (const basis of ['unspecified', 'per_recipe']) {
    const result = await extract(basis, 'Für 2 Portionen');
    const bowl = result?.candidates[0];
    check(bowl?.servings === 2 && bowl.nutrition_basis === 'per_serving' &&
      bowl.calories_kcal === 425 && bowl.protein_g === 48 &&
      bowl.carbs_g === 39 && bowl.fat_g === 8,
    'One-Bowl values must not be divided by the recipe yield');
  }
});

Deno.test('written one-unit nutrition headings work in German and English', () => {
  for (const heading of [
    'Nährwerte: (1 Bowl)', 'Nährwerte (eine Bowl)',
    'Nutrition (one pizza)', 'Macros (1 serving)',
  ]) {
    const value = sourcedNutrition({ nutrition_basis: 'per_serving',
      calories_kcal: 425, protein_g: 48, carbs_g: 39, fat_g: 8 },
      `${heading}: 425 kcal, 48 g Protein, 39 g Kohlenhydrate, 8 g Fett`,
      null, true);
    check(value.calories_kcal === 425 && value.protein_g === 48 &&
      value.carbs_g === 39 && value.fat_g === 8, 'One-unit basis: ' + heading);
  }
});

Deno.test('ambiguous and incompatible nutrition blocks remain untrusted', () => {
  const row = { nutrition_basis: 'per_serving', calories_kcal: 425,
    protein_g: 48, carbs_g: 39, fat_g: 8 };
  for (const evidence of [
    'Nährwerte (1/2 Bowl): 425 kcal, 48 g Protein, 39 g Kohlenhydrate, 8 g Fett',
    'Nährwerte (2 Bowls): 425 kcal, 48 g Protein, 39 g Kohlenhydrate, 8 g Fett',
    'Nährwerte pro 100 g: 425 kcal, 48 g Protein, 39 g Kohlenhydrate, 8 g Fett',
    `${nutrition}\nNährwerte (1 Pizza): 343 kcal, 24 g Protein`,
  ]) {
    const value = sourcedNutrition(row, evidence, null, true);
    check(value.calories_kcal === null && value.protein_g === null,
      'No unsupported per-Bowl attribution: ' + evidence);
  }
  const swapped = sourcedNutrition({ ...row, protein_g: 39, carbs_g: 48 }, nutrition, null, true);
  check(swapped.calories_kcal === 425 && swapped.protein_g === null &&
    swapped.carbs_g === null && swapped.fat_g === 8, 'Nutrient labels still bind each number');
});
