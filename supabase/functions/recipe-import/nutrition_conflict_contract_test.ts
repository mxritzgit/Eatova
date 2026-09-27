import fixtures from '../../../test/fixtures/recipe_import/nutrition_conflict_contract.json' with { type: 'json' };
import { parseExtraction } from './extraction.ts';

function canonical(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(canonical);
  if (value && typeof value === 'object') {
    return Object.fromEntries(Object.entries(value).sort(([a], [b]) => a.localeCompare(b))
      .map(([key, item]) => [key, canonical(item)]));
  }
  return value;
}

for (const fixture of fixtures) {
  Deno.test(`server/client nutrition conflict contract: ${fixture.name}`, async () => {
    const actual = await parseExtraction(JSON.stringify(fixture.provider), fixture.source, 2);
    if (JSON.stringify(canonical(actual)) !== JSON.stringify(canonical(fixture.expected))) {
      throw new Error(`Source validation differs from the shared client fixture: ${fixture.name}`);
    }
  });
}
