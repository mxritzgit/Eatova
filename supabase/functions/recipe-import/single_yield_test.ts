import { parseExtraction } from './extraction.ts';
import { sourcedNutrition, sourcedServings } from './nutrition.ts';

function check(value: unknown, message: string): asserts value {
  if (!value) throw new Error(message);
}

Deno.test('explicit single pizza yield supports the corresponding whole-recipe nutrition', async () => {
  const caption = 'Für eine Pizza\n125 g Quark\n75 g Mehl\nAlles backen.\nNährwerte mit Belag: ~ 507 kcal | 50 g Eiweiß | 6 g Fett | 61 g Kohlenhydrate';
  const result = await parseExtraction(JSON.stringify({
    status: 'ready', candidates: [{
      title: 'Pizza', ingredient_quotes: ['125 g Quark', '75 g Mehl'],
      preparation_quotes: ['Alles backen.'],
      servings: 1, servings_quote: 'Für eine Pizza',
      nutrition_basis: 'per_recipe',
      nutrition_quote: 'Nährwerte mit Belag: ~ 507 kcal | 50 g Eiweiß | 6 g Fett | 61 g Kohlenhydrate',
      calories_kcal: 507, protein_g: 50, carbs_g: 61, fat_g: 6,
    }],
  }), { source: { url: null }, text: caption, incomplete: false, truncated: false }, 2);
  const candidate = result?.candidates[0];
  check(candidate?.servings === 1 && candidate.nutrition_basis === 'per_serving', 'One pizza is the evidenced recipe yield');
  check(candidate.calories_kcal === 507 && candidate.protein_g === 50 &&
    candidate.carbs_g === 61 && candidate.fat_g === 6, 'Complete recipe values retained');
});

Deno.test('written single yields do not turn time, ingredients or another quantity into servings', () => {
  check(sourcedServings(1, 'Für eine Pizza') === 1, 'Written German yield');
  check(sourcedServings(1, 'Makes one pizza') === 1, 'Written English yield');
  for (const text of ['Für eine Minute', '1 Ei', 'Für zwei Pizzen', 'one pizza sauce jar']) {
    check(sourcedServings(1, text) === null, 'Not proof of one serving: ' + text);
  }
});

Deno.test('a proven single-dish yield also retains nutrition without a heading', () => {
  const value = sourcedNutrition({ nutrition_basis: 'per_recipe', calories_kcal: 507,
    protein_g: 50, carbs_g: 61, fat_g: 6 },
    '507 kcal, 50 g Protein, 61 g Kohlenhydrate, 6 g Fett.', 1, true, 'Fuer eine Pizza');
  check(value.nutrition_basis === 'per_serving' && value.calories_kcal === 507 &&
    value.protein_g === 50 && value.carbs_g === 61 && value.fat_g === 6,
    'The optional nutrition heading must not erase source-backed values');
});

Deno.test('a single yielded dish never overrides another nutrition basis or conflicting blocks', () => {
  const row = { nutrition_basis: 'per_recipe', calories_kcal: 507, protein_g: 50, carbs_g: 61, fat_g: 6 };
  for (const evidence of [
    'Nährwerte pro 100 g: 507 kcal, 50 g Protein',
    'Nutrition per 100 ml: 507 kcal, 50 g protein',
    'Nährwerte für eine halbe Pizza: 507 kcal, 50 g Protein',
    'Nutrition for 2 slices: 507 kcal, 50 g protein',
    'Nährwerte mit Belag: 507 kcal, 50 g Protein. Nährwerte ohne Belag: 343 kcal, 24 g Protein.',
  ]) {
    const value = sourcedNutrition(row, evidence, 1, true, 'Für eine Pizza');
    check(value.calories_kcal === null && value.protein_g === null, 'No unsupported whole-recipe attribution: ' + evidence);
  }
  const guessed = sourcedNutrition(row, 'Nährwerte: 507 kcal, 50 g Protein', 1, true);
  check(guessed.calories_kcal === null, 'A numeric yield without source evidence is insufficient');
  const ordinary = sourcedNutrition({ ...row, nutrition_basis: 'unspecified' },
    'Nährwerte: 507 kcal, 50 g Protein', null, true);
  check(ordinary.nutrition_basis === 'unspecified' && ordinary.calories_kcal === 507, 'Unstated recipe yield stays unconfirmed');
});
