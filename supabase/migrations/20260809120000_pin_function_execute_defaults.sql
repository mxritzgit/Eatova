-- Sicherheits-Härtung (Audit 2026-08-09): die Ausführungsrechte neuer
-- Funktionen im Namensraum public explizit festnageln.
--
-- LIVE-BEFUND VOR DIESER MIGRATION (per Management-API verifiziert, deshalb
-- ist das hier eine ZUSICHERUNG, kein Reparatur-Fix):
--   * Alle 10 Nutzer-Tabellen haben RLS aktiv; ein Event-Trigger `ensure_rls`
--     (`rls_auto_enable()`) schaltet RLS auf JEDER neuen public-Tabelle
--     automatisch an — die „neue Tabelle ohne RLS"-Luecke ist bereits zu.
--   * KEINE public-Funktion traegt PUBLIC-EXECUTE; die Default-Privilegien
--     fuer Funktionen stehen bereits auf {postgres, service_role} OHNE PUBLIC.
--
-- Der Audit (datei-basiert) hatte einen residualen PUBLIC-Grant auf
-- `handle_new_user_profile` vermutet — live ist er nicht (mehr) da. Diese
-- Migration macht die korrekte Absicht dennoch VERSIONIERT und
-- re-assertierbar, statt sie allein der Supabase-Verwaltung zu ueberlassen:
-- ein spaeteres versehentliches `grant execute ... to public` faellt beim
-- naechsten Blick auf die Migrationshistorie auf.
--
-- BEWUSST NICHT `force row level security`: `postgres` und `service_role`
-- tragen beide `rolbypassrls` und ignorieren RLS ohnehin; `authenticated`/
-- `anon` unterliegen ihr bereits (sie sind nie Tabellen-Owner). FORCE waere
-- hier ein wirkungsloser No-Op — und wuerde kuenftige Leser glauben machen,
-- er tue etwas.

-- 1) Kuenftige Funktionen: kein automatischer PUBLIC-EXECUTE. Das ist der
--    strukturelle Schutz — die manuelle „an public revoken"-Disziplin
--    entfaellt. service_role bleibt (Edge Functions), PUBLIC faellt weg.
alter default privileges in schema public
  revoke execute on functions from public;

-- 2) Defensiver Strip auf dem BESTAND: falls je eine Funktion (Dashboard-SQL,
--    Alt-Migration) PUBLIC-EXECUTE traegt, hier entfernen. Aktuell ein
--    No-Op (keine traegt es). Explizite Grants an service_role/authenticated
--    bleiben unberuehrt — nur der implizite PUBLIC-Grant faellt.
revoke execute on all functions in schema public from public;
