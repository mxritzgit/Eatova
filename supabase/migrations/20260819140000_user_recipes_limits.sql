-- Size and value limits for public.user_recipes and public.chat_sessions.title
-- (Komplettreview 2026-08-19, low finding).
--
-- 20260517220000_security_hardening.sql gave every then-existing
-- client-writable table a `<table>_safe_ranges_check`. `user_recipes` was
-- created later and never joined that block: it carries only five `>= 0`
-- column checks and no length or upper bound at all. `chat_sessions.title` was
-- missed in the same window.
--
-- No data leak — RLS holds. It is a cost and availability lever: a tampered
-- client can write arbitrarily large texts and absurd nutrition values, and
-- `UserRecipesSync.load` reads them all back at startup.
--
-- Limits are deliberately GENEROUS — a limit that rejects legitimate user data
-- would be worse than none. Every number sits far above what the two write
-- paths can produce (e.g. title 160 real vs 300 here, description 600 vs 4000,
-- ingredients/preparation 2000 vs 20000, chat title ~40 vs 500).
--
-- Numeric ranges match `logged_meals_safe_ranges_check`, since recipes are
-- converted to meals via `FitnessRecipe.toMealResult` anyway. Text limits are
-- wider than logged_meals: ingredients/preparation are multiline free text,
-- not labels.
--
-- `not valid`: ADD CONSTRAINT would otherwise validate the whole existing set
-- and fail if ONE legacy row breaks a limit, making the migration
-- non-redeployable in production. `not valid` guards future INSERT/UPDATE only,
-- which is the protection wanted here. To bring existing rows in line, run
-- separately and watch:
--   alter table public.user_recipes  validate constraint user_recipes_safe_ranges_check;
--   alter table public.chat_sessions validate constraint chat_sessions_safe_ranges_check;
--
-- Idempotent via the `pg_constraint` probe, as in
-- 20260517220000_security_hardening.sql section 3.

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'user_recipes_safe_ranges_check') then
    alter table public.user_recipes add constraint user_recipes_safe_ranges_check
      check (
        char_length(slug) between 1 and 200 and
        char_length(title) between 1 and 300 and
        char_length(description) <= 4000 and
        char_length(portion) <= 1000 and
        char_length(ingredients) <= 20000 and
        char_length(preparation) <= 20000 and
        char_length(image_asset) <= 2048 and
        calories_kcal between 0 and 10000 and
        protein_g between 0 and 1000 and
        carbs_g between 0 and 1000 and
        fat_g between 0 and 1000 and
        estimated_g between 0 and 10000 and
        -- cardinality alone would leave a SINGLE category unbounded, so the
        -- second line caps the total array length.
        cardinality(categories) <= 32 and
        char_length(array_to_string(categories, ',')) <= 2000
      ) not valid;
  end if;

  if not exists (select 1 from pg_constraint where conname = 'chat_sessions_safe_ranges_check') then
    alter table public.chat_sessions add constraint chat_sessions_safe_ranges_check
      check (char_length(title) between 1 and 500) not valid;
  end if;
end $$;
