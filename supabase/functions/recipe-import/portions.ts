import { sourcedServings } from './nutrition.ts';

export type IngredientsBasis = 'per_recipe' | 'per_serving' | 'unspecified';
const nutritionHeading = /\b(?:nährwerte|naehrwerte|nutrition|macros?)\b/i;
const perServingHeading = /^(?:zutaten|ingredients|mengen|amounts)?\s*(?:pro|je|per)\s+(?:(?:1|eine|one)\s+)?(?:portion|serving|person|stück|stueck|piece)\s*:?$/i;
const ingredientReference = /^(?:zutaten|ingredients|mengen|amounts)\s+(?:pro|je|per|für|fuer|for)\b/i;
const bareReference = /^(?:pro|je|per)\s+/i;

// Captions often flatten lists onto one line. Only explicit colon-delimited
// references gain boundaries; quantities and prose cannot become yield headings.
function referenceLines(evidence: string): string {
  let ingredientEnd = 0;
  return evidence.replace(/\b(?:(?:zutaten|ingredients|mengen|amounts)\s+(?:pro|je|per|für|fuer|for)|(?:pro|je|per))\s+[^:\r\n]{1,100}:/gi,
    (heading: string, offset: number) => {
      const prefix = evidence.slice(ingredientEnd, offset).split(/\r?\n/).at(-1) ?? '';
      if (bareReference.test(heading) && nutritionHeading.test(prefix)) return heading;
      if (!bareReference.test(heading)) ingredientEnd = offset + heading.length;
      return `\n${heading.trim()}\n`;
    });
}

/** A source substring must not crop a range, fraction or nutrition reference. */
export function sourceYield(value: unknown, evidence: string, source: string): number | null {
  const servings = sourcedServings(value, evidence);
  if (servings === null || !evidence) return null;
  let start = source.indexOf(evidence);
  while (start >= 0) {
    const before = source.slice(0, start);
    const after = source.slice(start + evidence.length);
    const prefix = before.split(/\r?\n|(?<=[.!])\s+/).at(-1) ?? '';
    if (!/[\d.,/⁄−–—-]\s*$/.test(prefix) &&
        !/(?:\b(?:to|bis|or|oder)|[½¼¾])\s*$/i.test(prefix) &&
        !/^\s*(?:[-−–—/⁄]|to\b|bis\b|or\b|oder\b)\s*\d/i.test(after) &&
        !nutritionHeading.test(prefix)) return servings;
    start = source.indexOf(evidence, start + evidence.length);
  }
  return null;
}

// Bounded standalone headings and parenthesized recipe yields. Ingredient or
// nutrition quantities cannot supply yields merely because they contain numbers.
function yieldHeadings(evidence: string): (number | null)[] {
  const result: (number | null)[] = [];
  for (const line of referenceLines(evidence).split(/\r?\n|(?<=[.!])\s+/)) {
    if (nutritionHeading.test(line)) continue;
    const text = line.trim().replace(/^(?:zutaten|ingredients)\s*:?\s*/i, '');
    const options = [text, ...[...text.matchAll(/\(([^()]*)\)/g)].map((match) => match[1])];
    for (const option of options) {
      const value = sourcedServings(null, option);
      if (value !== null) { result.push(value); break; }
      // Yield-looking but not exact (ranges, fractions, competing counts).
      if (/^(?:(?:für|fuer|for|ergibt|makes|yields|serves|servings|portionen)\b\s*[:=]?\s*)?[\d½¼¾]/i.test(option) &&
          /\b(?:portion(?:en|s)?|servings?|personen|people|stücke?|stuecke?|pieces?)\s*[.!:]?$/i.test(option)) {
        result.push(null); break;
      }
    }
  }
  return result;
}

export function consistentYield(servings: number | null, evidence: string): number | null {
  if (servings === null) return null;
  const yields = yieldHeadings(evidence);
  return yields.some((value) => value === null || value !== servings) ? null : servings;
}

/** Verify an ingredient-specific reference; a nutrient basis never supplies it. */
export function sourcedIngredientsBasis(
  evidence: string, ingredients: string[], servings: number | null,
  servingsEvidence: string, otherIngredients: string[], source: string,
): IngredientsBasis {
  if (!evidence || !ingredients.length || ingredients.some((item) => !evidence.includes(item))) return 'unspecified';
  // A quote spanning two distinct lists cannot borrow the other candidate's yield.
  if (otherIngredients.some((item) => !ingredients.includes(item) && evidence.includes(item))) return 'unspecified';
  // Include an immediately preceding ingredient reference even if the model
  // cropped it from the selected quote. Omitted per-serving wording is not proof
  // that these amounts apply to the batch.
  const start = source.indexOf(evidence);
  if (start < 0 || source.indexOf(evidence, start + evidence.length) >= 0) return 'unspecified';
  const previous = referenceLines(source.slice(0, start)).trimEnd().split(/\r?\n/).at(-1)?.trim() ?? '';
  if (perServingHeading.test(previous) || ingredientReference.test(previous) || bareReference.test(previous)) {
    evidence = `${previous}\n${evidence}`;
  }
  evidence = referenceLines(evidence);
  const headings = evidence.split(/\r?\n/);
  const firstIngredient = Math.min(...ingredients.map((item) => evidence.indexOf(item)));
  if (firstIngredient < 0) return 'unspecified';
  if (evidence.slice(firstIngredient).split(/\r?\n/).some((line) => ingredientReference.test(line.trim()) || bareReference.test(line.trim()))) return 'unspecified';
  const servingHeadings = headings.filter((line) => perServingHeading.test(line.trim()));
  if (servingHeadings.length) {
    if (headings.some((line) => (ingredientReference.test(line.trim()) || bareReference.test(line.trim())) && !perServingHeading.test(line.trim())) ||
        yieldHeadings(evidence.slice(firstIngredient)).length > 0) return 'unspecified';
    // Only one heading before the entire list establishes a uniform basis.
    if (servingHeadings.length !== 1 || ingredients.some((item) =>
      evidence.indexOf(item) < evidence.indexOf(servingHeadings[0]))) return 'unspecified';
    return 'per_serving';
  }
  // An explicit different reference must not be treated as the whole batch.
  if (headings.some((line) => bareReference.test(line.trim()) ||
    ingredientReference.test(line.trim()) && sourcedServings(null,
      line.trim().replace(/^(?:zutaten|ingredients|mengen|amounts)\s+/i, '')) !== servings)) return 'unspecified';
  if (servings === null || !servingsEvidence || !evidence.includes(servingsEvidence)) return 'unspecified';
  const yields = yieldHeadings(evidence);
  return yields.length > 0 && yields.every((value) => value === servings) ? 'per_recipe' : 'unspecified';
}
