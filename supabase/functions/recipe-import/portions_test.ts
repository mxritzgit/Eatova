import { extractionPrompt, parseExtraction } from './extraction.ts';
import { sourcedServings } from './nutrition.ts';
import { extractionSchema } from './schema.ts';

function check(value: unknown, message: string): asserts value {
  if (!value) throw new Error(message);
}

const ingredients = ['800 g Hackfleisch', '400 g Tomaten'];
const nutrition = 'Pro Stück: 500 kcal, 40 g Protein, 0 g KH, 20 g Fett';
function candidate(overrides: Record<string, unknown> = {}) {
  return {
    title: 'Hackfleisch', ingredient_quotes: ingredients, preparation_quotes: ['Alles braten.'],
    ingredient_basis_quote: `Für 4 Portionen\n${ingredients.join('\n')}`,
    servings: 4, servings_quote: 'Für 4 Portionen',
    nutrition_basis: 'per_serving', nutrition_quote: nutrition,
    calories_kcal: 500, protein_g: 40, carbs_g: 0, fat_g: 20, ...overrides,
  };
}
async function extract(row = candidate(), source = `Für 4 Portionen\n${ingredients.join('\n')}\nAlles braten.\n${nutrition}`, version = 2) {
  const result = await parseExtraction(JSON.stringify({ status: 'ready', candidates: [row] }),
    { source: { url: null }, text: source, incomplete: false, truncated: false }, version);
  check(result?.candidates.length === 1, 'Usable source-backed draft survives');
  return result.candidates[0];
}

Deno.test('portion contract preserves 800g batch evidence and per-piece nutrition for four servings', async () => {
  const value = await extract();
  check(value.ingredients === ingredients.join('\n'), 'Source amounts stay verbatim for identity and review');
  check(value.ingredients_basis === 'per_recipe' && value.servings === 4, 'Client can derive 800 / 4 = 200 g');
  check(value.nutrition_basis === 'per_serving' && value.calories_kcal === 500 && value.carbs_g === 0,
    'Per-piece values are not divided again; known zero survives');
});

Deno.test('portion contract divides only whole-batch nutrients once', async () => {
  const totals = 'Gesamt: 2000 kcal, 160 g Protein, 0 g KH, 80 g Fett';
  const value = await extract(candidate({ nutrition_basis: 'per_recipe', nutrition_quote: totals,
    calories_kcal: 2000, protein_g: 160, fat_g: 80 }),
    `Für 4 Portionen\n${ingredients.join('\n')}\nAlles braten.\n${totals}`);
  check(value.ingredients_basis === 'per_recipe' && value.nutrition_basis === 'per_serving', 'Independent bases validated');
  check(value.calories_kcal === 500 && value.protein_g === 40 && value.fat_g === 20, 'Only nutrition normalized on server');
});

Deno.test('portion contract recognizes ingredient amounts already per serving independently of batch yield', async () => {
  const items = ['200 g Hackfleisch', '100 g Tomaten'];
  const basis = `Zutaten pro Portion:\n${items.join('\n')}`;
  const value = await extract(candidate({ ingredient_quotes: items, ingredient_basis_quote: basis }),
    `Für 4 Portionen\n${basis}\nAlles braten.\n${nutrition}`);
  check(value.ingredients_basis === 'per_serving' && value.servings === 4, '200 g stays 200 g per serving');
  check(value.calories_kcal === 500, 'Nutrients keep their own per-serving basis');
});

Deno.test('portion contract recovers an omitted exact decimal yield without rounding', async () => {
  for (const yieldText of ['Für 2,5 Portionen', 'Makes 2.5 servings']) {
    const basis = `${yieldText}\n${ingredients.join('\n')}`;
    const value = await extract(candidate({ ingredient_basis_quote: basis, servings: null, servings_quote: yieldText }),
      `${basis}\nAlles braten.\n${nutrition}`);
    check(value.servings === 2.5 && value.ingredients_basis === 'per_recipe', 'Exact decimal batch permits 320 g per serving');
  }
});

Deno.test('portion contract never infers batch ingredients from nutrient basis or yield alone', async () => {
  for (const ingredientBasis of ['', 'not in source', nutrition, 'Für 4 Portionen']) {
    const value = await extract(candidate({ ingredient_basis_quote: ingredientBasis }));
    check(value.ingredients_basis === 'unspecified', 'Missing complete ingredient context stays unknown');
    check(value.calories_kcal === 500, 'Ingredient ambiguity does not erase valid nutrition');
  }
  const value = await extract(candidate({ servings: null, servings_quote: '', ingredient_basis_quote: ingredients.join('\n') }),
    `${ingredients.join('\n')}\nAlles braten.\n${nutrition}`);
  check(value.servings === null && value.ingredients_basis === 'unspecified', 'No yield is invented');
});

Deno.test('portion contract does not turn uncertain yield into batch nutrition division', async () => {
  for (const yieldText of ['2–4 Portionen', '1/4 Portionen', 'Für 4 Portionen\nFür 6 Portionen']) {
    const basis = `${yieldText}\n${ingredients.join('\n')}`;
    const totals = 'Gesamt: 2000 kcal, 160 g Protein';
    const value = await extract(candidate({ ingredient_basis_quote: basis,
      servings_quote: yieldText.includes('6') ? 'Für 4 Portionen' : '4 Portionen',
      nutrition_basis: 'per_recipe', nutrition_quote: totals, calories_kcal: 2000, protein_g: 160,
      carbs_g: null, fat_g: null }), `${basis}\nAlles braten.\n${totals}`);
    check(value.servings === null && value.ingredients_basis === 'unspecified', 'Range, fraction or conflict is not an exact yield');
    check(value.calories_kcal === 2000 && value.nutrition_basis === 'unspecified', 'Raw totals preserved pending confirmation');
    check(value.carbs_g === null, 'Missing is not zero');
  }
});

Deno.test('portion contract rejects nutrition references cropped into a recipe yield', async () => {
  const basis = `Nutrition for 4 servings:\n${nutrition}`;
  const value = await extract(candidate({ servings_quote: '4 servings', ingredient_basis_quote: '' }),
    `${ingredients.join('\n')}\nAlles braten.\n${basis}`);
  check(value.servings === null && value.ingredients_basis === 'unspecified', 'Nutrient reference does not establish batch yield');
});

Deno.test('portion yield accepts a recipe or ingredient subject before the exact yield', async () => {
  for (const evidence of ['Zutaten für 4 Portionen', 'Zutaten für 4 Portionen:', 'Rezept für 4 Personen',
    'Ingredients for 4 servings:', 'Recipe for 4 people', 'Serves 4 people', 'Portionen: 4 Personen']) {
    check(sourcedServings(4, evidence) === 4, 'Exact yield with subject: ' + evidence);
    check(sourcedServings(null, evidence) === 4, 'Omitted model yield recovered: ' + evidence);
  }
  check(sourcedServings(1, 'Rezept für eine Pizza') === 1, 'Written single-dish yield with subject');
  for (const evidence of ['Zutaten für 2-4 Portionen', 'Zutaten 4 Portionen', 'Nährwerte für 4 Portionen',
    'Nutrition for 4 servings', 'Serves 4 or 6 people', 'Zutaten für 4 Portionen Teig und 2 Portionen Soße']) {
    check(sourcedServings(4, evidence) === null, 'Still not an exact recipe yield: ' + evidence);
  }
  const heading = 'Zutaten für 4 Portionen:';
  const totals = 'Gesamt: 2000 kcal, 160 g Protein, 0 g KH, 80 g Fett';
  const value = await extract(candidate({ servings_quote: heading, ingredient_basis_quote: `${heading}\n${ingredients.join('\n')}`,
    nutrition_basis: 'per_recipe', nutrition_quote: totals, calories_kcal: 2000, protein_g: 160, fat_g: 80 }),
    `${heading}\n${ingredients.join('\n')}\nAlles braten.\n${totals}`);
  check(value.servings === 4 && value.ingredients_basis === 'per_recipe', 'Quoted ingredient heading proves the batch');
  check(value.nutrition_basis === 'per_serving' && value.calories_kcal === 500 && value.fat_g === 20,
    'Whole-recipe totals are divided by the proven yield');
});

Deno.test('portion yield rejects ranges fractions signs conflicting and model-invented numbers', () => {
  for (const evidence of ['2-4 servings', '1/4 servings', '-4 servings', '4 or 6 servings', '4 servings / 6 pieces',
    'Nutrition for 4 servings', '4.5.4 servings', '400 servings']) {
    check(sourcedServings(4, evidence) === null, 'Invalid exact yield: ' + evidence);
  }
  check(sourcedServings(2, '4 servings') === null, 'A differing model value is not repaired silently');
});

Deno.test('portion contract rejects mixed ingredient references and per-100g quantities', async () => {
  for (const heading of ['Zutaten pro 100 g:', 'Ingredients for half a serving:']) {
    const basis = `Für 4 Portionen\n${heading}\n${ingredients.join('\n')}`;
    const value = await extract(candidate({ ingredient_basis_quote: basis }), `${basis}\nAlles braten.\n${nutrition}`);
    check(value.ingredients_basis === 'unspecified', 'Unsupported reference cannot become batch quantities');
  }
  const basis = `Für 4 Portionen\n800 g Hackfleisch\nZutaten pro Portion:\n400 g Tomaten`;
  const value = await extract(candidate({ ingredient_basis_quote: basis }), `${basis}\nAlles braten.\n${nutrition}`);
  check(value.ingredients_basis === 'unspecified', 'A heading halfway through the list cannot apply to all ingredients');
});

Deno.test('portion contract checks source context omitted from the model evidence quote', async () => {
  const basis = `Für 4 Portionen\n${ingredients.join('\n')}`;
  const conflict = await extract(candidate(), `${basis}\nFür 6 Portionen\nAlles braten.\n${nutrition}`);
  check(conflict.servings === null && conflict.ingredients_basis === 'unspecified', 'Cropping another source yield cannot authorize scaling');
  const perServing = await extract(candidate(), `Zutaten pro Portion:\n${basis}\nAlles braten.\n${nutrition}`);
  check(perServing.ingredients_basis === 'per_serving', 'Adjacent per-serving heading cannot be cropped into batch quantities');
  const perMass = await extract(candidate(), `Ingredients per 100 g:\n${basis}\nAlles braten.\n${nutrition}`);
  check(perMass.ingredients_basis === 'unspecified', 'Unsupported adjacent reference is not a batch');
});

Deno.test('portion contract never applies a per-serving heading across competing ingredient bases', async () => {
  for (const other of ['Zutaten für 4 Portionen:', 'Für 4 Portionen', 'Ingredients per 100 g:']) {
    const items = ['200 g Hackfleisch', '400 g Tomaten'];
    const basis = `Zutaten pro Portion:\n${items[0]}\n${other}\n${items[1]}`;
    const value = await extract(candidate({ ingredient_quotes: items, ingredient_basis_quote: basis }),
      `Für 4 Portionen\n${basis}\nAlles braten.\n${nutrition}`);
    check(value.ingredients_basis === 'unspecified', 'Mixed references stay unscaled: ' + other);
  }
});

Deno.test('portion contract never applies a batch heading across an unsupported ingredient reference', async () => {
  for (const other of ['Ingredients per 100 g:', 'Pro 100 g:', 'Zutaten für eine halbe Portion:']) {
    const basis = `Zutaten für 4 Portionen:\n${ingredients[0]}\n${other}\n${ingredients[1]}`;
    const value = await extract(candidate({ ingredient_basis_quote: basis, servings_quote: 'für 4 Portionen' }),
      `${basis}\nAlles braten.\n${nutrition}`);
    check(value.ingredients_basis === 'unspecified', 'An ordinary batch heading cannot hide another basis');
  }
});

Deno.test('portion contract does not choose the first occurrence of repeated ingredient evidence', async () => {
  const basis = `Für 4 Portionen\n${ingredients.join('\n')}`;
  const source = `Zutaten pro Portion:\n${basis}\nIngredients per 100 g:\n${basis}\nAlles braten.\n${nutrition}`;
  const value = await extract(candidate(), source);
  check(value.ingredients_basis === 'unspecified', 'Identical selected text with different surrounding bases cannot be assigned');
});

Deno.test('portion contract keeps multiple candidates and their individual yield evidence separate', async () => {
  const first = candidate();
  const secondBasis = 'Für 2 Portionen\n300 g Nudeln';
  const second = candidate({ title: 'Pasta', ingredient_quotes: ['300 g Nudeln'],
    ingredient_basis_quote: secondBasis, servings: 2, servings_quote: 'Für 2 Portionen' });
  const source = `${first.ingredient_basis_quote}\nAlles braten.\n${secondBasis}\n${nutrition}`;
  const content = { source: { url: null }, text: source, incomplete: false, truncated: false };
  const result = await parseExtraction(JSON.stringify({ status: 'ready', candidates: [first, second] }), content, 2);
  check(result?.candidates.length === 2 && result.candidates[0].servings === 4 && result.candidates[1].servings === 2,
    'Independent yields remain associated with independent recipes');
  check(result.candidates.every((value) => value.ingredients_basis === 'per_recipe'), 'Each list has its own proof');
  const borrowed = await parseExtraction(JSON.stringify({ status: 'ready', candidates: [first,
    { ...second, servings: 4, servings_quote: 'Für 4 Portionen', ingredient_basis_quote: source }] }), content, 2);
  check(borrowed?.candidates[1].ingredients_basis === 'unspecified' && borrowed.candidates[1].servings === null,
    'A quote spanning another dish cannot borrow its yield');
  const outside = await parseExtraction(JSON.stringify({ status: 'ready', candidates: [first,
    { ...second, servings: 4, servings_quote: 'Für 4 Portionen' }] }), content, 2);
  check(outside?.candidates[1].servings === null, 'A candidate cannot borrow yield evidence outside its own list context');
});

Deno.test('portion contract keeps unsupported nutrition basis pending despite proven batch ingredients', async () => {
  const unknown = 'Macros for whole desert: 500 kcal, 40 g protein';
  const value = await extract(candidate({ nutrition_basis: 'per_recipe', nutrition_quote: unknown,
    carbs_g: null, fat_g: null }), `Für 4 Portionen\n${ingredients.join('\n')}\nAlles braten.\n${unknown}`);
  check(value.ingredients_basis === 'per_recipe' && value.calories_kcal === 500 && value.nutrition_basis === 'unspecified',
    'Ingredient batch proof cannot normalize unproven nutrition');
});

Deno.test('portion contract retains legacy response shape and stable source identity', async () => {
  const current = await extract();
  const legacy = await extract(candidate(), undefined, 1);
  check(!('ingredients_basis' in legacy) && legacy.calories_kcal === 500, 'Legacy shape and safe nutrients retained');
  check(legacy.id === current.id && legacy.ingredients === current.ingredients, 'Evidence metadata does not alter identity');
  const oldProvider = await extract(candidate({ ingredient_basis_quote: undefined }));
  check(oldProvider.ingredients_basis === 'unspecified', 'Older provider-shaped rows remain reviewable');
});

Deno.test('portion prompt and provider schema request exact independent ingredient basis evidence', () => {
  check(extractionPrompt('en').includes('ingredient_basis_quote') && extractionPrompt('de').includes('800 g'), 'Prompt explains source and derived quantity');
  const properties = extractionSchema.properties.candidates.items.properties;
  check(properties.ingredient_basis_quote.type === 'string', 'Provider strict schema contains quote field');
});
