// Structured-output schema of the extraction. Array caps are enforced by the
// parser: structured outputs support no array or numeric constraints.
const text = { type: 'string' };
const number = { type: ['number', 'null'] };
const quotes = { type: 'array', items: text };
const properties = {
  title: text, description_quote: text, portion_quote: text,
  ingredient_quotes: quotes, ingredient_basis_quote: text, preparation_quotes: quotes, variant_label: text,
  servings: number, servings_quote: text,
  nutrition_basis: { type: 'string', enum: ['per_serving', 'per_recipe', 'per_100g', 'unspecified'] },
  nutrition_quote: text, calories_kcal: number, protein_g: number,
  carbs_g: number, fat_g: number, estimated_g: number,
};

export const extractionSchema = {
  type: 'object', additionalProperties: false,
  required: ['status', 'truncated', 'candidates'],
  properties: {
    status: { type: 'string', enum: ['ready', 'needs_text', 'no_recipe'] },
    truncated: { type: 'boolean' },
    candidates: {
      type: 'array',
      items: { type: 'object', additionalProperties: false, required: Object.keys(properties), properties },
    },
  },
};
