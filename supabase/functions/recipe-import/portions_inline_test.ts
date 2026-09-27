import { parseExtraction } from './extraction.ts';
import { consistentYield, sourcedIngredientsBasis } from './portions.ts';

function check(value: unknown, message: string): asserts value {
  if (!value) throw new Error(message);
}

const items = ['160g Mehl', '6 Eier', '320g Skyr', '2 Scoops Süßungsmittel', '1 Pack Backpulver', '5g Puderzucker'];
const list = '-160g Mehl -6 Eier -320g Skyr -2 Scoops Süßungsmittel  -1 Pack Backpulver -5g Puderzucker';
const basis = `Zutaten für 2 Portionen: ${list}`;
const nutrients = 'Nährwerte: 650 kcal 47g Protein 68g Protein 20g Fett';
const source = `Kaiserschmarrn. ${basis} Zubereitung: Eier trennen. ${nutrients} #kaiserschmarrn`;

Deno.test('flattened TikTok ingredient header establishes two-portion batch quantities', async () => {
  for (const ingredientQuotes of [items, items.map((item) => `-${item}`), [list]]) {
    const result = await parseExtraction(JSON.stringify({ status: 'ready', candidates: [{
      title: 'Kaiserschmarrn', ingredient_quotes: ingredientQuotes,
      ingredient_basis_quote: basis, preparation_quotes: ['Eier trennen.'],
      servings: 2, servings_quote: 'für 2 Portionen', nutrition_quote: nutrients,
      nutrition_basis: 'unspecified', calories_kcal: 650, protein_g: null, carbs_g: null, fat_g: 20,
    }] }), { source: { url: null }, text: source, incomplete: false, truncated: false }, 2);
    const candidate = result?.candidates[0];
    check(candidate?.servings === 2 && candidate.ingredients_basis === 'per_recipe', 'Inline explicit ingredient yield proves batch quantities');
    check(candidate.ingredients === ingredientQuotes.join('\n'), 'Exact ingredient evidence stays unchanged');
    check(candidate.nutrition_basis === 'unspecified' && candidate.calories_kcal === 650,
      'Ingredient yield does not prove the nutrition basis');
  }
});

Deno.test('inline ingredient references preserve decimal yields and already per-serving quantities', () => {
  for (const [heading, count, expected] of [
    ['Ingredients for 2.5 servings:', 2.5, 'per_recipe'],
    ['Zutaten für 2,5 Portionen:', 2.5, 'per_recipe'],
    ['Zutaten pro Portion:', 2, 'per_serving'],
    ['Ingredients per serving:', 2, 'per_serving'],
  ] as const) {
    const evidence = `${heading} ${list}`;
    const yieldQuote = heading.includes('2') ? heading.replace(/^(?:Ingredients|Zutaten) /, '').slice(0, -1) : 'Für 2 Portionen';
    check(sourcedIngredientsBasis(evidence, items, count, yieldQuote, [], `Für 2 Portionen\n${evidence}`) === expected, heading);
  }
});

Deno.test('inline unsupported and competing ingredient references never authorize batch scaling', () => {
  for (const heading of ['Zutaten für 2–4 Portionen:', 'Ingredients for 1/2 servings:',
    'Zutaten pro 100 g:', 'Ingredients for half a serving:']) {
    const evidence = `${heading} ${list}`;
    check(sourcedIngredientsBasis(evidence, items, 2, '2 Portionen', [], evidence) === 'unspecified', heading);
  }
  for (const heading of ['Ingredients per 100 g:', 'Pro 100 g:', 'Zutaten pro Portion:', 'Zutaten für 4 Portionen:', 'Zutaten für 2 Portionen:']) {
    const evidence = `Zutaten für 2 Portionen: ${items[0]} ${heading} ${items[1]}`;
    check(sourcedIngredientsBasis(evidence, items.slice(0, 2), 2, 'für 2 Portionen', [], evidence) === 'unspecified', heading);
  }
  const competing = `Zutaten für 2 Portionen: ${items[0]} Zutaten für 4 Portionen: ${items[1]}`;
  check(consistentYield(2, competing) === null, 'Inline conflicting yields cannot be cropped away');
});

Deno.test('inline ingredient context stays candidate scoped and cannot come from nutrition or unbounded prose', () => {
  const second = 'Ingredients for 4 servings: 400g rice';
  check(sourcedIngredientsBasis(`${basis} ${second}`, items, 2, 'für 2 Portionen', ['400g rice'], `${basis} ${second}`) === 'unspecified',
    'A combined quote cannot borrow another candidate list');
  for (const evidence of [`Nutrition for 2 servings: ${list}`, `Nährwerte pro Portion: ${list}`, `Nutrition per serving: ${list}`,
    `Für 2 Portionen ${list}`, `Zutaten für 2 Portionen ${list}`]) {
    check(sourcedIngredientsBasis(evidence, items, 2, '2 Portionen', [], evidence) === 'unspecified',
      'New inline recognition requires explicit ingredient header and colon');
  }
});

Deno.test('cropped inline ingredient quotes retain immediately preceding conflicting references', () => {
  for (const heading of ['Ingredients per 100 g:', 'Pro 100 g:']) {
    const cropped = `${basis}`;
    check(sourcedIngredientsBasis(cropped, items, 2, 'für 2 Portionen', [], `A recipe. ${heading} ${cropped}`) === 'unspecified',
      'A cropped unsupported reference cannot establish a batch');
  }
  const cropped = `Für 2 Portionen\n${list}`;
  check(sourcedIngredientsBasis(cropped, items, 2, 'Für 2 Portionen', [], `A recipe. Zutaten pro Portion: ${cropped}`) === 'per_serving',
    'Explicit adjacent per-serving ingredient context remains authoritative');
});

Deno.test('earlier inline nutrition heading cannot hide a later ingredient reference conflict', () => {
  for (const heading of ['Pro 100 g:', 'Per serving:', 'Pro Portion:']) {
    const evidence = `Nutrition: 650 kcal Zutaten fuer 2 Portionen: 160g Mehl ${heading} 6 Eier`;
    check(sourcedIngredientsBasis(evidence, ['160g Mehl', '6 Eier'], 2, '2 Portionen', [], evidence) === 'unspecified',
      'The explicit ingredient header starts a new context: ' + heading);
  }
});
