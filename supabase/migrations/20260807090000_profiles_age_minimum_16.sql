-- Raise the minimum age to 16, matching PRIVACY.md and the app UI.
--
-- Eatova processes health data (GDPR Art. 9); consent for information society
-- services requires 16 in Germany (Art. 8). The DB previously allowed 13+.
--
-- The constraint name stays identical so the old hardening migration's
-- if-not-exists guard still applies and no duplicate constraints appear.

do $$
begin
  if exists (
    select 1 from pg_constraint
    where conname = 'profiles_biometrics_range_check'
      and conrelid = 'public.profiles'::regclass
  ) then
    alter table public.profiles drop constraint profiles_biometrics_range_check;
  end if;
end $$;

-- Defensive: lift any legacy rows below 16 so the new constraint validates.
update public.profiles set age_years = 16 where age_years < 16;

alter table public.profiles add constraint profiles_biometrics_range_check
  check (
    weight_kg between 30 and 300 and
    height_cm between 100 and 250 and
    age_years between 16 and 100
  );
