-- Mass assignment on public.profiles (finding 2026-08-19): RLS is row-based,
-- but the grants were table-wide, so a client could set email, display_name,
-- avatar_url and created_at — columns the app never writes. Integrity only.
--
-- Fix: narrow the write grants to the ProfileSync.save payload. The remaining
-- columns are set by security-definer triggers or column defaults, and trigger
-- assignments are not subject to the statement column grants.
--
-- id must be in both lists: the PostgREST upsert puts every payload column into
-- the on-conflict SET list, including the PK. RLS and the FK still rule out an
-- id change.
--
-- New profiles columns the app writes must be granted here, or the upsert fails
-- loudly with 42501.

revoke insert, update on public.profiles from authenticated;

grant insert (
  id, weight_kg, height_cm, age_years, sex, activity_level,
  target_weight_kg, daily_steps_goal, daily_kcal_goal,
  daily_water_goal_ml, daily_sleep_goal_minutes,
  protein_goal_g, carbs_goal_g, fat_goal_g,
  weight_goal, diet_preference, onboarding_completed
) on public.profiles to authenticated;

grant update (
  id, weight_kg, height_cm, age_years, sex, activity_level,
  target_weight_kg, daily_steps_goal, daily_kcal_goal,
  daily_water_goal_ml, daily_sleep_goal_minutes,
  protein_goal_g, carbs_goal_g, fat_goal_g,
  weight_goal, diet_preference, onboarding_completed
) on public.profiles to authenticated;
