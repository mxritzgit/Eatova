import { parseExtraction } from './extraction.ts';
import type { SourceContent } from './source.ts';

function check(value: unknown, message: string): asserts value {
  if (!value) throw new Error(message);
}

const recipe = 'Pasta\n200 g Pasta\nPasta kochen.';
async function extract(nutrition: string, row: Record<string, unknown> = {}) {
  const source: SourceContent = {
    source: { url: null }, text: `${recipe}\n${nutrition}`,
    incomplete: false, truncated: false,
  };
  return await parseExtraction(JSON.stringify({
    status: 'ready', candidates: [{
      title: 'Pasta', ingredient_quotes: ['200 g Pasta'],
      preparation_quotes: ['Pasta kochen.'],
      nutrition_basis: 'per_serving', nutrition_quote: nutrition,
      calories_kcal: 450, protein_g: 30, carbs_g: 50, fat_g: 10,
      ...row,
    }],
  }), source);
}

Deno.test('caption nutrition supports a trailing basis, German abbreviations and decimal commas', async () => {
  for (const caption of [
    '450 kcal | 30 g Protein | 50 g KH | 10 g Fett (pro Portion)',
    'Nährwerte je Portion: kcal: 450, Eiweiß: 30 g, Kohlenhydrate: 50 g, Fett: 10 g',
    'Per serving: 450 calories, protein 30g, carbs 50g, fat 10g',
    '450 kcal 30g Protein 50g KH 10g Fett pro Portion',
  ]) {
    const result = await extract(caption);
    const value = result?.candidates[0];
    check(value?.calories_kcal === 450 && value.protein_g === 30 &&
      value.carbs_g === 50 && value.fat_g === 10, caption);
    check(!result?.warnings.includes('nutrition_missing'), 'Serving weight is optional');
  }
  const decimal = await extract('Pro Portion: 450 kcal, 30,5 g Eiweiß.', { protein_g: 30.5 });
  check(decimal?.candidates[0].protein_g === 30.5, 'Decimal grams survive source validation');
});

Deno.test('caption nutrition converts proven whole-recipe totals using explicit yield', async () => {
  const result = await extract('Für 2 Portionen. Gesamt: 900 kcal, 60 g Protein, 100 g KH, 20 g Fett.', {
    nutrition_basis: 'per_recipe', calories_kcal: 900, protein_g: 60, carbs_g: 100, fat_g: 20,
    servings: 2, servings_quote: 'Für 2 Portionen.',
  });
  const value = result?.candidates[0];
  check(value?.calories_kcal === 450 && value.protein_g === 30 &&
    value.carbs_g === 50 && value.fat_g === 10, 'Whole recipe divided by evidenced yield');
});

Deno.test('reported TikTok format: pro Stück and ca. preserve all four nutrients and piece yield', async () => {
  const result = await extract('Hot Pockets (8 Stück) Nährwerte pro Stück • Kalorien ca. 358 kcal • Eiweiß ca. 32 g • Kohlenhydrate ca. 31 g • Fett ca. 11 g', {
    calories_kcal: 358, protein_g: 32, carbs_g: 31, fat_g: 11,
    servings: 8, servings_quote: '8 Stück',
  });
  const row = result?.candidates[0];
  check(row?.calories_kcal === 358 && row.protein_g === 32 && row.carbs_g === 31 && row.fat_g === 11 && row.servings === 8, 'Caption values per piece');
});

Deno.test('caption nutrition does not confuse total, per-serving and per-100g values', async () => {
  const mixed = await extract('Pro 100 g: 150 kcal, 10 g Protein. Pro Portion: 450 kcal, 30 g Protein.');
  check(mixed?.candidates[0].calories_kcal === 450 && mixed.candidates[0].protein_g === 30, 'Only serving block');
  const swapped = await extract('Pro Portion: 450 kcal, 30 g Protein, 50 g KH.', { protein_g: 50, carbs_g: 30 });
  check(swapped?.candidates[0].protein_g === null && swapped.candidates[0].carbs_g === null, 'No swapped values');
});

Deno.test('recipe source quotes tolerate whitespace normalization and long captions without inventing content', async () => {
  const ingredients = Array.from({ length: 25 }, (_, i) => `${i + 1} g Zutat ${'lang '.repeat(20)}${i}`).join('\n');
  const source: SourceContent = { source: { url: null }, text: `${ingredients}\nAlles\u00a0 gut\nvermischen.`, incomplete: false, truncated: false };
  const result = await parseExtraction(JSON.stringify({ status: 'ready', candidates: [{
    title: 'Rezept', ingredient_quotes: [ingredients], preparation_quotes: ['Alles gut vermischen.'],
  }] }), source);
  check(result?.status === 'ready' && result.candidates[0].ingredients === ingredients, 'Long ingredient list retained');
  check(result.candidates[0].preparation === 'Alles\u00a0 gut\nvermischen.', 'Original source restored');
});

Deno.test('caption ingredients retain repeated quantities from different recipe parts', async () => {
  const source: SourceContent = { source: { url: null }, text: 'Teig: 100 g Mehl, 1 TL Salz. Füllung: 200 g Gemüse, 1 TL Salz. Alles backen.', incomplete: false, truncated: false };
  const row = { title: 'Taschen', ingredient_quotes: ['100 g Mehl', '1 TL Salz', '200 g Gemüse', '1 TL Salz'], preparation_quotes: ['Alles backen.'] };
  const result = await parseExtraction(JSON.stringify({ status: 'ready', candidates: [row] }), source);
  check(result?.candidates[0].ingredients.split('1 TL Salz').length === 3, 'Dough salt and filling salt both remain');
  const duplicate = await parseExtraction(JSON.stringify({ status: 'ready', candidates: [{ ...row, ingredient_quotes: ['100 g Mehl', '100 g Mehl'] }] }), source);
  check(duplicate?.candidates.length === 0, 'Invented duplicate quantities are rejected');
});
