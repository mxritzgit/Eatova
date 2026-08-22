-- profiles.weight_goal: the chosen lose/gain/maintain target, read and written
-- by ProfileSync. Without it every profile upsert throws and onboarding loops.
-- Idempotent, so an already out-of-band patched live DB still applies.

alter table public.profiles
  add column if not exists weight_goal text not null default 'maintain';

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'profiles_weight_goal_check'
  ) then
    alter table public.profiles add constraint profiles_weight_goal_check
      check (weight_goal in (
        'lose1kg', 'lose075kg', 'lose05kg', 'lose025kg',
        'maintain', 'gain025kg', 'gain05kg'
      ));
  end if;
end $$;
