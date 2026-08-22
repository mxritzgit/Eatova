-- profiles.diet_preference: none/vegetarian/vegan/pescetarian, read and written
-- by ProfileSync. Steers recommendations only, no allergy guarantee; default
-- 'none' leaves existing rows unchanged.
-- Idempotent; grants and RLS on public.profiles already cover the column.

alter table public.profiles
  add column if not exists diet_preference text not null default 'none';

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'profiles_diet_preference_check'
  ) then
    alter table public.profiles add constraint profiles_diet_preference_check
      check (diet_preference in ('none', 'vegetarian', 'vegan', 'pescetarian'));
  end if;
end $$;
