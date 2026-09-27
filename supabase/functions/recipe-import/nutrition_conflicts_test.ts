import { extractionPrompt, parseExtraction } from './extraction.ts';
import { sourcedNutrition } from './nutrition.ts';
import { completeNutritionEvidence } from './nutrition_source.ts';

function check(value: unknown, message: string): asserts value {
  if (!value) throw new Error(message);
}

// The reported nutrition caption repeats Protein; it contains no carbohydrate label.
const caption = 'Nährwerte:\n650 kcal\n47g Protein\n68g Protein\n20g Fett';
const model = { nutrition_basis: 'unspecified', calories_kcal: 650,
  protein_g: 47, carbs_g: 68, fat_g: 20 };

async function extract(nutrition = caption, changes: Record<string, unknown> = {}, version = 2) {
  return await parseExtraction(JSON.stringify({ status: 'ready', candidates: [{
    title: 'Kaiserschmarrn', ingredient_quotes: ['100 g Mehl', '2 Eier'],
    preparation_quotes: ['Alles vermischen und braten.'], nutrition_quote: nutrition,
    ...model, ...changes,
  }] }), { source: { url: null },
    text: `100 g Mehl\n2 Eier\nAlles vermischen und braten.\n${nutrition}`,
    incomplete: false, truncated: false }, version);
}

Deno.test('reported Kaiserschmarrn conflict explains unknown protein without inventing carbs', async () => {
  for (const text of [caption, caption.replaceAll('\n', ' ') + ' #frühstück #gesunderezepte #kaiserschmarrn']) {
    for (const protein of [null, 47, 68]) {
      const result = await extract(text, { protein_g: protein });
      const recipe = result?.candidates[0];
      check(recipe?.calories_kcal === 650 && recipe.fat_g === 20, 'Unambiguous source values survive');
      check(recipe.protein_g === null && recipe.carbs_g === null, 'Do not choose between protein labels or reinterpret one as carbs');
      check(JSON.stringify(recipe.nutrition_conflicts) === '["protein_g"]', 'Distinguish conflicting protein from absent carbohydrates');
      check(recipe.nutrition_basis === 'unspecified' && result?.warnings.includes('nutrition_missing'),
        'A serving confirmation cannot repair conflicting or missing nutrients');
    }
  }
});

Deno.test('correctly labelled caption needs no conflict correction', async () => {
  for (const label of ['Kohlenhydrate', 'KH', 'carbs']) {
    const result = await extract(caption.replace('68g Protein', `68g ${label}`));
    const recipe = result?.candidates[0];
    check(recipe?.protein_g === 47 && recipe.carbs_g === 68, 'Each number belongs to its explicit label');
    check(recipe.calories_kcal === 650 && recipe.fat_g === 20 && !('nutrition_conflicts' in recipe),
      'Clean candidates retain their existing response shape');
    check(!result?.warnings.includes('nutrition_missing') && recipe.nutrition_basis === 'unspecified',
      'Only the genuinely unconfirmed basis remains');
  }
});

Deno.test('repeated identical values aliases decimals and zero are not false conflicts', () => {
  const value = sourcedNutrition({ nutrition_basis: 'unspecified', protein_g: null, fat_g: null },
    'Nährwerte: 47,5g Protein, 47.5g Eiweiß, 0g Fett, F: 0g', null, true);
  check(value.protein_g === 47.5 && value.fat_g === 0 && value.carbs_g === null, 'Unique values recover; absent values stay unknown');
  check(!value.nutrition_conflicts, 'Repeated evidence of the same value is not conflicting');
});

Deno.test('conflict diagnostics contain only bounded canonical nutrient fields', () => {
  const value = sourcedNutrition({ nutrition_basis: 'unspecified', nutrition_conflicts: ['invented'] },
    'Nährwerte: 650 kcal, 700 calories, 0g Protein, 47g P, 68g carbs, C: 69g, 20g fat, F: 21g, weight: 100, weight: 200',
    null, true);
  check(JSON.stringify(value.nutrition_conflicts) === '["calories_kcal","protein_g","carbs_g","fat_g"]',
    'Every conflicting visible nutrient is identified once; weight and model metadata are excluded');
  check([value.calories_kcal, value.protein_g, value.carbs_g, value.fat_g].every((field) => field === null),
    'Diagnostics never make conflicting values usable');
});

Deno.test('conflicts belong to the selected nutrient block not adjacent references', () => {
  const distinct = 'Pro 100 g: 47g Protein, 68g Protein. Pro Portion: 650 kcal, 47g Protein, 68g KH, 20g Fett';
  const perServing = sourcedNutrition({ ...model, nutrition_basis: 'per_serving' }, distinct, 4, true);
  check(perServing.protein_g === 47 && perServing.carbs_g === 68 && !perServing.nutrition_conflicts,
    'A different block cannot contaminate the selected serving values');
  const mixed = sourcedNutrition(model,
    'Nährwerte Teig: 47g Protein. Nährwerte Belag: 68g Protein.', null, true);
  check(mixed.protein_g === null && !mixed.nutrition_conflicts,
    'Ambiguous separate dishes cannot be merged into a duplicate-label diagnosis');
});

Deno.test('explicit whole-recipe conversion retains conflicts without double scaling other values', () => {
  const value = sourcedNutrition({ ...model, nutrition_basis: 'per_recipe' },
    'Gesamt: 650 kcal, 47g Protein, 68g Protein, 20g Fett', 2, true, 'Für 2 Portionen');
  check(value.calories_kcal === 325 && value.fat_g === 10 && value.nutrition_basis === 'per_serving',
    'Only proven values are converted');
  check(value.protein_g === null && value.carbs_g === null && value.nutrition_conflicts?.[0] === 'protein_g',
    'Yield conversion cannot resolve contradictory numbers');
});

Deno.test('conflict diagnostics require source proof and do not trust model flags', async () => {
  const forged = await extract('Nährwerte: 650 kcal, 47g Protein, 20g Fett', {
    nutrition_conflicts: ['calories_kcal', 'carbs_g'],
  });
  check(!forged?.candidates[0].nutrition_conflicts, 'Only the server classifies conflicts');
  const invented = await extract('Keine Nährwertangaben.', { nutrition_quote: caption });
  check(invented?.candidates[0].protein_g === null && !invented.candidates[0].nutrition_conflicts,
    'A source quote that never occurred proves no conflict');
});

Deno.test('v1 keeps existing numeric safety and omits additive conflict diagnostics', async () => {
  const result = await extract(caption.replace('Nährwerte:', 'Pro Portion:'), { nutrition_basis: 'per_serving' }, 1);
  const recipe = result?.candidates[0];
  check(recipe?.calories_kcal === 650 && recipe.protein_g === null && recipe.carbs_g === null && recipe.fat_g === 20,
    'Legacy numeric behavior stays safe');
  check(!('nutrition_conflicts' in recipe), 'No v2-only metadata in legacy response');
});

Deno.test('prompt explicitly forbids correcting duplicate source labels by guessing', () => {
  const prompt = extractionPrompt('de');
  check(prompt.includes('conflicting labels') && prompt.includes('Never relabel'),
    'The extractor must retain contradictory evidence rather than repair the caption');
});

Deno.test('model cannot hide either conflicting protein amount by cropping the source block', async () => {
  for (const separator of ['\n', ' ']) {
    const source = caption.replaceAll('\n', separator);
    for (const crop of [`Nährwerte:${separator}650 kcal${separator}47g Protein`,
      `650 kcal${separator}47g Protein`, `68g Protein${separator}20g Fett`, '47g Protein']) {
      const result = await extract(source, { nutrition_quote: crop });
      const recipe = result?.candidates[0];
      check(recipe?.protein_g === null && recipe.carbs_g === null,
        'A cropped quote cannot select one of two contradictory labels');
      check(recipe.nutrition_conflicts?.[0] === 'protein_g' && recipe.calories_kcal === 650 && recipe.fat_g === 20,
        'The complete bounded section retains the diagnostic and uniquely evidenced values');
    }
  }
});

Deno.test('source block completion stops at nutrition recipe ingredient preparation and variant boundaries', () => {
  const first = 'Nährwerte: 650 kcal 47g Protein 68g KH 20g Fett';
  for (const boundary of ['\nNährwerte: ', ' Zutaten: ', '\nIngredients\n', ' Zubereitung: ',
    '\nPreparation\n', ' Rezept 2: ', ' Variante: ', '\n\nOther dish ', ' #recipe ']) {
    const complete = completeNutritionEvidence('47g Protein', first + boundary + '99g Protein');
    check(complete === first, 'Do not borrow an adjacent block: ' + boundary);
  }
  const source = `${first}\nNährwerte: 300 kcal 80g Protein 90g Protein`;
  check(completeNutritionEvidence('80g Protein', source) === 'Nährwerte: 300 kcal 80g Protein 90g Protein',
    'Select the containing section rather than the first nutrition heading');
});

Deno.test('trailing hashtags section crossings and blank nutrition lines cannot hide a source conflict', async () => {
  const flattened = caption.replaceAll('\n', ' ');
  const hashtags = ' #frühstück #gesunderezepte #kaiserschmarrn';
  const tagged = await extract(flattened + hashtags,
    { nutrition_quote: '68g Protein 20g Fett' + hashtags, protein_g: 68 });
  check(tagged?.candidates[0].protein_g === null && tagged.candidates[0].nutrition_conflicts?.[0] === 'protein_g',
    'Keeping trailing hashtags cannot hide the earlier contradictory value');
  const crossed = await extract(flattened + ' Zutaten: 10 g Zucker',
    { nutrition_quote: '68g Protein 20g Fett Zutaten: 10 g Zucker', protein_g: 68 });
  check(crossed?.candidates[0].protein_g === null, 'Crossing a different section cannot fall back to cropped values');
  const spaced = await extract(caption.replace('68g Protein', '\n68g Protein'),
    { nutrition_quote: '68g Protein\n20g Fett', protein_g: 68 });
  check(spaced?.candidates[0].protein_g === null && spaced.candidates[0].nutrition_conflicts?.[0] === 'protein_g',
    'Blank lines between nutrient rows do not split a source conflict');
});

Deno.test('source block completion is bounded source verified and conservative about association', () => {
  check(completeNutritionEvidence('invented quote', caption) === '', 'Unverified evidence cannot be completed');
  check(completeNutritionEvidence('47g Protein', `${caption}\n${caption}`) === '', 'Repeated quote occurrences have no unique source association');
  const headerless = '650 kcal 47g Protein 68g Protein 20g Fett';
  check(completeNutritionEvidence('47g Protein', headerless) === '47g Protein', 'No unproven block invented without a heading');
  const oversized = `Nährwerte: 47g Protein ${' '.repeat(2000)}68g Protein`;
  check(completeNutritionEvidence('47g Protein', oversized) === '', 'Oversized sections cannot authorize cropped values');
  const separated = 'Nährwerte: 47g Protein\nZutaten:\n100g Mehl\n68g Protein';
  check(completeNutritionEvidence('68g Protein', separated) === '68g Protein', 'An earlier section cannot claim later ingredient text');
  check(completeNutritionEvidence('47g Protein\nZutaten:\n100g Mehl', separated) === '',
    'A quote crossing into ingredients is not one complete nutrition section');
});

Deno.test('bulleted nutrient rows after blank lines cannot hide a source conflict', async () => {
  for (const bullet of ['-', '*', '•']) {
    for (const row of ['68g Protein', 'Protein: 68g']) {
      const source = `Nährwerte: 650 kcal 47g Protein\n\n${bullet} ${row}\n20g Fett`;
      const result = await extract(source, { nutrition_quote: `${row}\n20g Fett`, protein_g: 68 });
      const recipe = result?.candidates[0];
      check(recipe?.protein_g === null && recipe.nutrition_conflicts?.[0] === 'protein_g',
        'A list marker does not create a new nutrition section');
      check(recipe.calories_kcal === 650 && recipe.fat_g === 20, 'Retain both unambiguous values');
    }
    const first = 'Nährwerte: 650 kcal 47g Protein 68g KH 20g Fett';
    check(completeNutritionEvidence('47g Protein', `${first}\n\n${bullet} Other recipe: 99g Protein`) === first,
      'An unrelated bulleted paragraph still ends the nutrition section');
  }
});

Deno.test('completed source evidence retains separate serving basis selection and legacy shape', async () => {
  const source = 'Nährwerte pro 100 g: 47g Protein 68g Protein. Nährwerte pro Portion: 650 kcal 47g Protein 68g KH 20g Fett';
  const result = await extract(source, { nutrition_quote: '650 kcal 47g Protein 68g KH 20g Fett', nutrition_basis: 'per_serving' });
  check(result?.candidates[0].protein_g === 47 && !result.candidates[0].nutrition_conflicts,
    'Other basis blocks never supply conflicts');
  const legacy = await extract(caption.replace('Nährwerte:', 'Nährwerte pro Portion:'),
    { nutrition_basis: 'per_serving' }, 1);
  check(!legacy?.candidates[0].nutrition_conflicts, 'v1 diagnostics and evidence selection stay unchanged');
  const full = await extract(source, { nutrition_quote: source, nutrition_basis: 'per_serving' });
  check(full?.candidates[0].protein_g === 47 && !full.candidates[0].nutrition_conflicts,
    'Complete multi-basis quotes retain the existing basis selector');
  const cropped = 'Nährwerte pro 100 g: 10g Protein. Nährwerte pro Portion: 47g Protein';
  const concealed = await extract(cropped + ' 68g Protein',
    { nutrition_quote: cropped, nutrition_basis: 'per_serving' });
  check(concealed?.candidates[0].protein_g === null && concealed.candidates[0].nutrition_conflicts?.[0] === 'protein_g',
    'A complete earlier heading cannot hide a crop in the final selected nutrition block');
});
