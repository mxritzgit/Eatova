// resolve_plan answers for the coach-chat stubs, in the shape of
// docs/PREMIUM.md 2.3. "legacy" is an account from before Premium (today's
// 5 questions with picture); suites that pin the mode fields use "premium"
// (20), so a constant 5 in the handler shows up as a failure.

export type PlanFixture = "free" | "premium" | "legacy";

const PREMIUM = { coach_daily: 20, meal_analysis_daily: 30, recipe_import_daily: 10, recipe_picture: true };

export const PLAN_FIXTURES: Record<PlanFixture, Record<string, unknown>> = {
  free: {
    tier: "free",
    legacy: false,
    coach_daily: 2,
    meal_analysis_daily: 3,
    recipe_import_daily: 1,
    provider_calls_daily: 11,
    recipe_picture: false,
    premium: PREMIUM,
  },
  premium: { tier: "premium", legacy: false, ...PREMIUM, provider_calls_daily: 150, premium: PREMIUM },
  // Free and legacy: the legacy row, and Premium as the higher value per feature.
  legacy: {
    tier: "free",
    legacy: true,
    coach_daily: 5,
    meal_analysis_daily: 100,
    recipe_import_daily: 20,
    provider_calls_daily: 150,
    recipe_picture: true,
    premium: { coach_daily: 20, meal_analysis_daily: 100, recipe_import_daily: 20, recipe_picture: true },
  },
};

export function isResolvePlanCall(url: string): boolean {
  return url.includes("/rest/v1/rpc/resolve_plan");
}

export function resolvePlanResponse(plan: PlanFixture): Response {
  return new Response(JSON.stringify(PLAN_FIXTURES[plan]), {
    status: 200,
    headers: { "content-type": "application/json" },
  });
}
