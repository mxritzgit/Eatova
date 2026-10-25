// The account's plan for one AI request: public.resolve_plan
// (20261025100000) through PostgREST with the service key.
//
// Fail-safe to Free: a lookup that fails, hangs, answers non-2xx or in any
// shape other than the contract yields FREE_FALLBACK, never more. The
// request keeps working with the Free limits; one log line names the outage,
// never a body or a user id. A day limit hit under the fallback is no
// verdict on the account (it may be Premium), so the AI functions answer it
// with 503 `plan_unavailable`: no planLimit, no upgrade offer, retryable.

import { readProviderBody } from './provider_body.ts';

export type PlanTier = 'free' | 'premium';
export type PlanFeature = 'coach' | 'meal_analysis' | 'recipe_import';

export interface TierLimits {
  coachDaily: number;
  mealAnalysisDaily: number;
  recipeImportDaily: number;
  recipePicture: boolean;
}

export interface ResolvedPlan extends TierLimits {
  tier: PlanTier;
  legacy: boolean;
  providerCallsDaily: number;
  /** What Premium gives this account (for a legacy account the higher value per feature). */
  premium: TierLimits;
  /** True when the lookup failed and the Free defaults apply. */
  fallback: boolean;
}

/** The `planLimit` object of a tier-quota denial (docs/PREMIUM.md 3.1). */
export interface PlanLimitWire {
  feature: PlanFeature;
  tier: PlanTier;
  limit: number;
  resetAt: string;
  premiumLimit?: number;
}

export const FREE_FALLBACK: ResolvedPlan = Object.freeze({
  tier: 'free',
  legacy: false,
  coachDaily: 3,
  mealAnalysisDaily: 4,
  recipeImportDaily: 2,
  providerCallsDaily: 30,
  recipePicture: false,
  premium: Object.freeze({ coachDaily: 20, mealAnalysisDaily: 30, recipeImportDaily: 10, recipePicture: true }),
  fallback: true,
});

/** A few hundred bytes by contract; anything far larger is not resolve_plan. */
const MAX_PLAN_BYTES = 4096;
/** Upper bound of the lookup even when the caller's signal allows more. */
const PLAN_TIMEOUT_MS = 5000;
/** The bounds of the plan_tiers CHECK constraints. */
const MAX_LIMIT = 10_000;

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function isLimit(value: unknown, min: number): value is number {
  return typeof value === 'number' && Number.isInteger(value) && value >= min && value <= MAX_LIMIT;
}

function tierLimits(value: unknown): TierLimits | null {
  if (!isRecord(value)) return null;
  const { coach_daily, meal_analysis_daily, recipe_import_daily, recipe_picture } = value;
  if (!isLimit(coach_daily, 1) || !isLimit(meal_analysis_daily, 1) || !isLimit(recipe_import_daily, 1)) return null;
  if (typeof recipe_picture !== 'boolean') return null;
  return {
    coachDaily: coach_daily,
    mealAnalysisDaily: meal_analysis_daily,
    recipeImportDaily: recipe_import_daily,
    recipePicture: recipe_picture,
  };
}

/** The strict reading of the resolve_plan answer; null for anything else. */
function parsePlan(value: unknown): ResolvedPlan | null {
  if (!isRecord(value)) return null;
  const { tier, legacy, provider_calls_daily } = value;
  if (tier !== 'free' && tier !== 'premium') return null;
  if (typeof legacy !== 'boolean' || !isLimit(provider_calls_daily, 0)) return null;
  const current = tierLimits(value);
  const premium = tierLimits(value.premium);
  if (!current || !premium) return null;
  return { ...current, tier, legacy, providerCallsDaily: provider_calls_daily, premium, fallback: false };
}

/** Resolves the plan of `userId`. Never throws; any failure gives FREE_FALLBACK. */
export async function resolvePlan(o: {
  supabaseUrl: string;
  serviceKey: string;
  userId: string;
  signal: AbortSignal;
}): Promise<ResolvedPlan> {
  const signal = AbortSignal.any([o.signal, AbortSignal.timeout(PLAN_TIMEOUT_MS)]);
  try {
    const response = await fetch(`${o.supabaseUrl}/rest/v1/rpc/resolve_plan`, {
      method: 'POST',
      headers: {
        apikey: o.serviceKey,
        authorization: `Bearer ${o.serviceKey}`,
        'content-type': 'application/json',
      },
      body: JSON.stringify({ p_user_id: o.userId }),
      // The service key must never follow a redirect.
      redirect: 'error',
      signal,
    });
    if (!response.ok) {
      // Not awaited: a stalled cancel must not hold the fallback.
      void response.body?.cancel().catch(() => {});
    } else {
      const raw = await readProviderBody(response, MAX_PLAN_BYTES, signal);
      const plan = raw === null ? null : parsePlan(JSON.parse(raw));
      if (plan) return plan;
    }
  } catch {
    // Transport, timeout, abort or unreadable body: the fallback below.
  }
  console.error('resolve_plan unavailable');
  return FREE_FALLBACK;
}

export function limitFor(plan: ResolvedPlan, feature: PlanFeature): number {
  return pick(plan, feature);
}

export function premiumLimitFor(plan: ResolvedPlan, feature: PlanFeature): number {
  return pick(plan.premium, feature);
}

function pick(limits: TierLimits, feature: PlanFeature): number {
  switch (feature) {
    case 'coach':
      return limits.coachDaily;
    case 'meal_analysis':
      return limits.mealAnalysisDaily;
    case 'recipe_import':
      return limits.recipeImportDaily;
  }
}

/** The next 00:00 UTC after `nowMs`: every daily limit resets then. */
export function nextUtcMidnightIso(nowMs: number = Date.now()): string {
  const now = new Date(nowMs);
  return new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate() + 1)).toISOString();
}

/**
 * The `planLimit` object. `premiumLimit` only for a Free account whose
 * Premium allowance is higher, so the client offers an upgrade only then;
 * never for the fallback, whose tier is not the account's. The AI functions
 * answer a denial under the fallback with 503 `plan_unavailable` instead.
 */
export function planLimitWire(plan: ResolvedPlan, feature: PlanFeature, resetAt: string): PlanLimitWire {
  const limit = limitFor(plan, feature);
  const premiumLimit = premiumLimitFor(plan, feature);
  return {
    feature,
    tier: plan.tier,
    limit,
    resetAt,
    ...(!plan.fallback && plan.tier === 'free' && premiumLimit > limit ? { premiumLimit } : {}),
  };
}
