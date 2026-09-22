type Basis = 'per_serving' | 'per_recipe' | 'per_100g' | 'unspecified';
const LABELS = {
  calories_kcal: '(?:kcal|calories|kalorien|kilokalorien)',
  protein_g: '(?:proteins?|proteine|eiweiß|eiweiss)',
  carbs_g: '(?:carbs?|carbohydrates?|kohlenhydrate[n]?|kh)',
  fat_g: '(?:fats?|fett[e]?)',
  estimated_g: '(?:weight|gewicht|portionsgewicht)',
};
type Field = keyof typeof LABELS;
export type Nutrition = Record<Field, number | null> & {
  nutrition_basis: 'per_serving' | 'unspecified' | null;
};

export function evidencedNumber(value: unknown, numbers: string[], min: number, max: number): number | null {
  if (typeof value !== 'number' || !Number.isFinite(value) || value < min || value > max) return null;
  const distinct = new Set(numbers.map((number) => Number(number.replace(',', '.'))));
  return distinct.size === 1 && distinct.has(value) ? value : null;
}

export function sourcedServings(value: unknown, evidence: string): number | null {
  const numbers = [...evidence.matchAll(/(\d+(?:[.,]\d+)?)\s*(?:portion(?:en|s)?|servings?|personen|people|stücke?|stuecke?|pieces?)\b/gi)].map((m) => m[1]);
  numbers.push(...[...evidence.matchAll(/\b(?:serves|servings|portionen)\s*[:=]?\s*(\d+(?:[.,]\d+)?)/gi)].map((m) => m[1]));
  return evidencedNumber(value, numbers, 0.1, 100);
}

// A single block can end with its basis. Mixed blocks must have clear headers.
function nutritionBlock(evidence: string, basis: Basis): string {
  const markers = [...evidence.matchAll(/\b(?:(?:pro|je|per)\s*(?:(?:1|eine[r]?|one)\s+)?(?:portion|serving|person|stück|stueck|piece)\b|(?:pro|je|per)\s*100\s*g\b|(?:insgesamt|gesamt(?:es\s+rezept)?|total|whole\s+recipe|entire\s+recipe|für\s+das\s+(?:ganze\s+)?rezept)\b)/gi)];
  const kind = (text: string): Basis => /100\s*g/i.test(text) ? 'per_100g'
    : /(?:pro|je|per)\s/i.test(text) ? 'per_serving' : 'per_recipe';
  if (!markers.length) return basis === 'unspecified' ? evidence : '';
  const selected = markers.filter((m) => kind(m[0]) === basis);
  if (selected.length !== 1) return '';
  if (markers.length === 1) return evidence;
  const index = markers.indexOf(selected[0]);
  return evidence.slice(selected[0].index! + selected[0][0].length, markers[index + 1]?.index ?? evidence.length);
}

function sourcedValue(value: unknown, evidence: string, field: Field): number | null {
  const name = LABELS[field];
  const before = new RegExp('(?:^|[^\\p{L}\\d.,\\-−])(\\d+(?:[.,]\\d+)?)\\s*(?:g\\s*)?(' + name + ')(?=$|[^\\p{L}])', 'giu');
  const after = new RegExp('(?:^|[^\\p{L}])(' + name + ')\\s*[:=]?\\s*(?:(?:ca\\.?|circa|about|approx\\.?)\\s*)?(\\d+(?:[.,]\\d+)?)', 'giu');
  const preceding = [...evidence.matchAll(before)];
  const usedLabels = new Set(preceding.map((m) => m.index! + m[0].length - m[2].length));
  const following = [...evidence.matchAll(after)].filter((m) =>
    !usedLabels.has(m.index! + m[0].indexOf(m[1])));
  const numbers = [...preceding.map((m) => m[1]), ...following.map((m) => m[2])];
  return evidencedNumber(value, numbers, field === 'estimated_g' ? 1 : 0,
    field === 'calories_kcal' || field === 'estimated_g' ? 10_000 : 1000);
}

export function sourcedNutrition(row: Record<string, unknown>, evidence: string, servings: number | null, allowUnspecified: boolean): Nutrition {
  const result: Nutrition = { calories_kcal: null, protein_g: null, carbs_g: null, fat_g: null, estimated_g: null, nutrition_basis: null };
  const basis = row.nutrition_basis;
  if (!['per_serving', 'per_recipe', 'per_100g', 'unspecified'].includes(String(basis))) return result;
  const block = nutritionBlock(evidence, basis as Basis);
  if (!block || basis === 'unspecified' && !allowUnspecified) return result;
  let divisor = 1;
  if (basis === 'per_recipe') {
    if (servings === null) {
      if (!allowUnspecified) return result;
    } else divisor = servings;
  }
  if (basis === 'per_100g') return result;
  for (const field of Object.keys(LABELS) as Field[]) {
    const value = sourcedValue(row[field], block, field);
    const converted = value === null ? null : value / divisor;
    const max = field === 'calories_kcal' || field === 'estimated_g' ? 10_000 : 1000;
    result[field] = converted !== null && converted <= max ? converted : null;
  }
  result.nutrition_basis = basis === 'unspecified' || basis === 'per_recipe' && servings === null
    ? 'unspecified' : 'per_serving';
  return result;
}
