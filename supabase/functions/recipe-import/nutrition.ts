type Basis = 'per_serving' | 'per_recipe' | 'per_100g' | 'unspecified';
const LABELS = {
  calories_kcal: '(?:kcal|calories|kalorien|kilokalorien)',
  protein_g: '(?:proteins?|proteine|eiweiß|eiweiss|p)',
  carbs_g: '(?:carbs?|carbohydrates?|kohlenhydrate[n]?|kh|c)',
  fat_g: '(?:fats?|fett[e]?|f)',
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

function explicitDishYield(evidence: string): number | null {
  const match = /^(?:für|fuer|for|ergibt|makes|yields)\s+(ein(?:e[nr]?)?|one|\d+(?:[.,]\d+)?)\s+(?:pizza|pizzen|pizzas|bowls?|burgers?|pancakes?|pfannkuchen|waffeln?|waffles?|portion(?:en|s)?|servings?)\s*[.!:]?$/i.exec(evidence.trim());
  if (!match) return null;
  return /^(?:ein|one)/i.test(match[1]) ? 1 : Number(match[1].replace(',', '.'));
}

export function sourcedServings(value: unknown, evidence: string): number | null {
  const numbers = [...evidence.matchAll(/(\d+(?:[.,]\d+)?)\s*(?:portion(?:en|s)?|servings?|personen|people|stücke?|stuecke?|pieces?)\b/gi)].map((m) => m[1]);
  numbers.push(...[...evidence.matchAll(/\b(?:serves|servings|portionen)\s*[:=]?\s*(\d+(?:[.,]\d+)?)/gi)].map((m) => m[1]));
  const dishYield = explicitDishYield(evidence);
  if (dishYield !== null) numbers.push(String(dishYield));
  return evidencedNumber(value, numbers, 0.1, 100);
}

// A single block can end with its basis. Mixed blocks must have clear headers.
const singleUnitHeading = /\b(?:nährwerte|naehrwerte|nutrition|macros?)\s*:?\s*\(\s*(?:1|ein(?:e[nr]?)?|one)\s+(?:bowls?|pizzas?|burgers?|pancakes?|waffles?|waffeln?|pfannkuchen|portion(?:en|s)?|servings?|stücke?|stuecke?|pieces?)\s*\)/i;
const nutritionHeading = /\b(?:nährwerte|naehrwerte|nutrition(?:al)?(?:\s+(?:values|facts))?|macros?)\b/gi;

function basisMarkers(evidence: string): RegExpMatchArray[] {
  const found = [
    ...evidence.matchAll(/\b(?:(?:pro|je|per)\s*(?:(?:1|eine[r]?|one)\s+)?(?:portion|serving|person|stück|stueck|piece)\b|(?:pro|je|per)\s*100\s*(?:g|ml)\b|(?:insgesamt|gesamt(?:es\s+rezept)?|total(?!\s+(?:fat|carbs?|carbohydrates?|protein|sugars?|fibre|fiber)\b)|(?:whole|entire|full)\s+(?:recipe|batch)|für\s+das\s+(?:ganze\s+)?rezept)\b)/gi),
    ...evidence.matchAll(new RegExp(singleUnitHeading.source, 'gi')),
  ].sort((a, b) => a.index! - b.index!);
  return found;
}

function nutritionBlock(evidence: string, basis: Basis): string {
  const markers = basisMarkers(evidence);
  const headings = [...evidence.matchAll(nutritionHeading)];
  if (headings.length > 1 && headings.length > markers.length) return '';
  const kind = (text: string): Basis => /100\s*(?:g|ml)/i.test(text) ? 'per_100g'
    : /(?:pro|je|per)\s/i.test(text) || singleUnitHeading.test(text) ? 'per_serving' : 'per_recipe';
  if (!markers.length) return basis === 'unspecified' ? evidence : '';
  const selected = markers.filter((m) => kind(m[0]) === basis);
  if (selected.length !== 1) return '';
  if (markers.length === 1) return evidence;
  const index = markers.indexOf(selected[0]);
  return evidence.slice(selected[0].index! + selected[0][0].length, markers[index + 1]?.index ?? evidence.length);
}

function singleUnqualifiedBlock(evidence: string): string {
  // Unknown wording can still prove the numbers. Several references cannot be merged.
  return basisMarkers(evidence).length <= 1 &&
      [...evidence.matchAll(nutritionHeading)].length <= 1 ? evidence : '';
}

function nutritionNumbers(evidence: string): Record<Field, string[]> {
  evidence = evidence.normalize('NFKC');
  const result: Record<Field, string[]> = { calories_kcal: [], protein_g: [], carbs_g: [], fat_g: [], estimated_g: [] };
  const pairs: { field: Field; number: number; label: number; value: string }[] = [];
  for (const field of Object.keys(LABELS) as Field[]) {
    const name = LABELS[field];
    const before = new RegExp('(?:^|[^\\p{L}\\d.,\\-−–—/⁄])(\\d+(?:[.,]\\d+)?)\\s*(g\\s*)?(' + name + ')(?=$|[^\\p{L}])', 'giu');
    const after = new RegExp('(?:^|[^\\p{L}])(' + name + ')\\s*[:=]?\\s*(?:(?:ca\\.?|circa|about|approx\\.?)\\s*)?(\\d+(?:[.,]\\d+)?)', 'giu');
    for (const match of evidence.matchAll(before)) {
      // Single letters need grams: "180 C" and "350 F" can be oven temperatures.
      if (match[3].length === 1 && !match[2]) continue;
      const trailing = evidence.slice(match.index! + match[0].length);
      // A colon/equal sign binds this label to its own following value.
      if (/^\s*[:=]/.test(trailing)) continue;
      // "15 g protein powder" and "7 g fat free yogurt" are ingredients, not macros.
      if (/^\s*(?:powder|pulver|free|reduced)\b/i.test(trailing)) continue;
      pairs.push({ field, number: match.index! + match[0].indexOf(match[1]),
        label: match.index! + match[0].length - match[3].length, value: match[1] });
    }
    for (const match of evidence.matchAll(after)) {
      if (match[1].length === 1 && !/^\s*g(?!\p{L})/iu.test(evidence.slice(match.index! + match[0].length))) continue;
      if (/^(?:[eE][+-]?\d|[.,/⁄]\d|\s*(?:g\s*)?(?:[-−–—]|to\b|bis\b)\s*\d)/i.test(evidence.slice(match.index! + match[0].length))) continue;
      pairs.push({ field, number: match.index! + match[0].length - match[2].length,
        label: match.index! + match[0].indexOf(match[1]), value: match[2] });
    }
  }
  // Bind pairs in reading order. A number already labelled as protein cannot
  // become carbs just because "carbs: 31g" immediately follows "protein: 32g".
  pairs.sort((a, b) => Math.min(a.number, a.label) - Math.min(b.number, b.label));
  const usedLabels = new Set<number>();
  const usedNumbers = new Map<number, Field>();
  for (const pair of pairs) {
    if (usedLabels.has(pair.label)) continue;
    const owner = usedNumbers.get(pair.number);
    if (owner) continue;
    usedLabels.add(pair.label);
    usedNumbers.set(pair.number, pair.field);
    result[pair.field].push(pair.value);
  }
  return result;
}

function sourcedValue(value: unknown, numbers: string[], field: Field, recoverMissing: boolean): number | null {
  if (recoverMissing && (value === null || value === undefined)) {
    const distinct = new Set(numbers.map((number) => Number(number.replace(',', '.'))));
    if (distinct.size === 1) value = [...distinct][0];
  }
  return evidencedNumber(value, numbers, field === 'estimated_g' ? 1 : 0,
    field === 'calories_kcal' || field === 'estimated_g' ? 10_000 : 1000);
}

export function sourcedNutrition(row: Record<string, unknown>, evidence: string, servings: number | null, allowUnspecified: boolean, servingsEvidence = ''): Nutrition {
  const result: Nutrition = { calories_kcal: null, protein_g: null, carbs_g: null, fat_g: null, estimated_g: null, nutrition_basis: null };
  // An explicit one-dish nutrition heading is stronger than the model's basis label.
  let basis = singleUnitHeading.test(evidence) &&
      (row.nutrition_basis === 'unspecified' || row.nutrition_basis === 'per_recipe')
    ? 'per_serving' : row.nutrition_basis;
  if (!['per_serving', 'per_recipe', 'per_100g', 'unspecified'].includes(String(basis))) return result;
  let block = nutritionBlock(evidence, basis as Basis);
  // One explicitly yielded dish makes its complete recipe totals one serving.
  // A model label alone, a fraction or a conflicting per-unit basis is not proof.
  if (!block && basis === 'per_recipe' && servings === 1 &&
      explicitDishYield(servingsEvidence) === 1 &&
      !/\b(?:pro|je|per|für|fuer|for|half|halbe[nrs]?|viertel|quarter|slices?|stücke?|stuecke?|pieces?)\b|[½¼]|1\s*\/\s*[24]/i.test(evidence)) {
    block = nutritionBlock(evidence, 'unspecified');
  }
  // Keeping a proven number and authorizing a serving conversion are separate decisions.
  // v2 clients display these raw values as unconfirmed and require review before logging.
  if (allowUnspecified && (!block || basis === 'per_100g')) {
    block = singleUnqualifiedBlock(evidence);
    basis = 'unspecified';
  }
  if (!block || basis === 'unspecified' && !allowUnspecified) return result;
  let divisor = 1;
  if (basis === 'per_recipe') {
    if (servings === null) {
      if (!allowUnspecified) return result;
    } else divisor = servings;
  }
  if (basis === 'per_100g') return result;
  const numbers = nutritionNumbers(block);
  for (const field of Object.keys(LABELS) as Field[]) {
    const value = sourcedValue(row[field], numbers[field], field, allowUnspecified);
    const converted = value === null ? null : value / divisor;
    const max = field === 'calories_kcal' || field === 'estimated_g' ? 10_000 : 1000;
    result[field] = converted !== null && converted <= max ? converted : null;
  }
  result.nutrition_basis = basis === 'unspecified' || basis === 'per_recipe' && servings === null
    ? 'unspecified' : 'per_serving';
  return result;
}
