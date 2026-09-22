// Array caps are enforced by the parser. Nested maxItems made the live
// Gemini provider reject this schema with INVALID_ARGUMENT.
const text = { type: 'string' };
const number = { type: ['number', 'null'] };
const quotes = { type: 'array', items: text };
const properties = {
  title: text, description_quote: text, portion_quote: text,
  ingredient_quotes: quotes, preparation_quotes: quotes, variant_label: text,
  servings: number, servings_quote: text,
  nutrition_basis: { type: 'string', enum: ['per_serving', 'per_recipe', 'per_100g', 'unspecified'] },
  nutrition_quote: text, calories_kcal: number, protein_g: number,
  carbs_g: number, fat_g: number, estimated_g: number,
};

export const extractionResponseFormat = {
  type: 'json_schema',
  json_schema: {
    name: 'recipe_import', strict: true,
    schema: {
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
    },
  },
};
