// resolve_plan answers (docs/PREMIUM.md 2.3) for the offline handler tests of
// analyze-meal and recipe-import. `legacy` is an account created before the
// Premium migration: it keeps the old limits, and its Premium is the higher
// value per feature, so Premium adds no analyses or imports for it.
export const RESOLVE_PLAN_RPC = '/rest/v1/rpc/resolve_plan';

const PREMIUM = { coach_daily: 20, meal_analysis_daily: 30, recipe_import_daily: 10, recipe_picture: true };

export const PLAN_ANSWERS = {
  free: {
    tier: 'free',
    legacy: false,
    coach_daily: 3,
    meal_analysis_daily: 4,
    recipe_import_daily: 2,
    provider_calls_daily: 30,
    recipe_picture: false,
    premium: PREMIUM,
  },
  premium: { tier: 'premium', legacy: false, ...PREMIUM, provider_calls_daily: 150, premium: PREMIUM },
  legacy: {
    tier: 'free',
    legacy: true,
    coach_daily: 5,
    meal_analysis_daily: 100,
    recipe_import_daily: 20,
    provider_calls_daily: 150,
    recipe_picture: true,
    premium: { coach_daily: 20, meal_analysis_daily: 100, recipe_import_daily: 20, recipe_picture: true },
  },
};
