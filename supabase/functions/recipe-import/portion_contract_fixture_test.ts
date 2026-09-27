import fixtures from '../../../test/fixtures/recipe_import/portions_contract.json' with { type: 'json' };
import { parseExtraction } from './extraction.ts';

for (const fixture of fixtures) {
  Deno.test(`shared Flutter portion contract: ${fixture.name}`, async () => {
    const result = await parseExtraction(JSON.stringify(fixture.provider_response), fixture.source, 2);
    if (JSON.stringify(result) !== JSON.stringify(fixture.response)) {
      throw new Error('Shared response fixture differs from actual source validation');
    }
    const candidate = result?.candidates[0];
    const fields = candidate as unknown as Record<string, unknown>;
    if (fields.ingredients_basis !== fixture.expected_ingredients_basis ||
        candidate?.nutrition_basis !== fixture.expected_nutrition_basis ||
        candidate?.calories_kcal !== fixture.expected_kcal) {
      throw new Error(`Incorrect independent ingredient/nutrition basis: ${fixture.name}`);
    }
    if (candidate?.ingredients !== fixture.provider_response.candidates[0].ingredient_quotes.join('\n')) {
      throw new Error('Source ingredient evidence was rewritten');
    }
  });
}
