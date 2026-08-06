-- Mindestalter konsistent auf 16 Jahre anheben (DSGVO).
--
-- Begruendung: Eatova verarbeitet Gesundheitsdaten (Art. 9 DSGVO). Fuer die
-- Einwilligung in Dienste der Informationsgesellschaft gilt in Deutschland
-- die Altersgrenze aus Art. 8 DSGVO: 16 Jahre. PRIVACY.md sagt bereits
-- "not directed at children under 16" — bisher erlaubte die DB aber 13+
-- (profiles_biometrics_range_check aus 20260517220000_security_hardening.sql)
-- und das Onboarding 14+. Diese Migration zieht die Datenbank auf denselben
-- Wert wie Datenschutzerklaerung und App-UI (Onboarding clampt jetzt 16–99).
--
-- Der Constraint-Name bleibt identisch, damit die if-not-exists-Guard der
-- alten Hardening-Migration bei frischen Setups weiterhin greift und keine
-- doppelten Constraints entstehen.

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

-- Defensiv: falls Altbestand mit age_years < 16 existiert, auf das neue
-- Minimum anheben, damit das neue Constraint validieren kann. (Aktuell sollte
-- es solche Zeilen nicht geben — Onboarding erlaubte nie unter 14.)
update public.profiles set age_years = 16 where age_years < 16;

alter table public.profiles add constraint profiles_biometrics_range_check
  check (
    weight_kg between 30 and 300 and
    height_cm between 100 and 250 and
    age_years between 16 and 100
  );
