-- Befund-Verifikation 2026-08-19: Mass Assignment auf public.profiles.
--
-- Die RLS-Update-Policy (profiles_update_own) ist zeilenbasiert, die Grants
-- waren tabellenweit (20260517220000: grant insert/update on all tables to
-- authenticated). Ein manipulierter Client durfte damit per PostgREST auch
-- email, display_name, avatar_url und created_at direkt setzen — Spalten,
-- die die App nie schreibt. Ein verfaelschtes profiles.email wanderte in den
-- DSGVO-Export (data_export.dart holt profiles per select('*'), Art. 15).
-- Keine Vertraulichkeitsluecke, reine Integritaet.
--
-- Fix: Schreib-Grants exakt auf die App-Schreibmenge (ProfileSync.save-
-- Payload, lib/src/services/profile_sync.dart) einschraenken. Die uebrigen
-- Spalten pflegen ausschliesslich security-definer-Trigger bzw. die DB:
--   email/display_name  -> handle_new_user_profile (Signup + E-Mail-Wechsel)
--   avatar_url          -> derzeit niemand (bleibt zu, bis ein Feature kommt)
--   created_at          -> Spalten-Default
--   updated_at          -> profiles_set_updated_at (BEFORE-UPDATE-Trigger;
--                          Trigger-Zuweisungen unterliegen NICHT den
--                          Spalten-Grants des Statements)
--
-- id MUSS in beiden Listen stehen: der PostgREST-Upsert von ProfileSync.save
-- uebernimmt JEDE Payload-Spalte in die on-conflict-SET-Liste, auch den PK —
-- ohne UPDATE-Grant auf id scheitert der Upsert einer bestehenden Zeile.
-- Ein id-Wechsel bleibt trotzdem ausgeschlossen (RLS with check
-- auth.uid() = id + FK auf auth.users).
--
-- MERKE fuer kuenftige profiles-Spalten, die die App schreiben soll: der
-- Grant muss hier explizit nachgezogen werden. Fehlt er, wirft der Upsert
-- laut 42501 (ProfileSync.save rethrowt, Sentry sieht es) — kein stiller
-- Datenverlust.

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
