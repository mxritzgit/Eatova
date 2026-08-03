-- FitPilot — Drop der Tabellen der entfernten Tabs (Heute / Training / Trends)
--
-- Kontext: Am 2026-08-03 wurden die Tabs Heute, Training und Trends samt
-- ihrer gesamten Client-Logik entfernt (Rework spaeter, siehe App-Commit
-- "refactor(app)!: Heute-, Training- und Trends-Tab vollstaendig entfernt").
-- Kein Code spricht diese Tabellen mehr an — sie fliegen inklusive Daten.
--
-- ACHTUNG: destruktiv und NICHT umkehrbar. Alle User-Daten in diesen fuenf
-- Tabellen gehen verloren. Die Tabellen-DEFINITIONEN bleiben in den alten
-- Migrationen (20260516160000_app_data_schema.sql, 20260530090000_streak_
-- and_weekly_plan.sql, 20260604160000_workout_logging.sql) nachlesbar und
-- koennen beim Rework als Vorlage dienen.
--
-- Bewusst NICHT geloescht:
--   * weight_log        — Gewichts-Log lebt weiter im Profil
--   * lifetime_stats    — Zaehler/Streak-Aggregat, weiter im Profil sichtbar
--   * profiles, logged_meals, favorite_meals, user_recipes, Chat-Tabellen
--   * RPCs increment_lifetime_stats / record_workout_day — arbeiten nur auf
--     lifetime_stats, bleiben als Andockpunkt fuers Rework
--
-- CASCADE raeumt die tabellengebundenen Objekte mit ab (RLS-Policies,
-- Indexe, Trigger, Check-Constraints aus dem Security-Hardening).
-- IF EXISTS macht das Skript idempotent — ein zweiter Lauf ist ein No-Op.

begin;

drop table if exists public.daily_logs       cascade; -- Wasser/Schritte/Mood/Habits/Bloecke (Heute)
drop table if exists public.caffeine_entries cascade; -- Koffein-Tracking (Heute)
drop table if exists public.sleep_entries    cascade; -- Schlaf-Log (Heute)
drop table if exists public.weekly_plans     cascade; -- 7-Tage-Trainingsplan (Training)
drop table if exists public.workout_sets     cascade; -- Satz-Logging PROD-5 (Training)

commit;
