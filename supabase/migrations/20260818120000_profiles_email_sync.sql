-- Eatova — profiles.email nach E-Mail-Wechsel nachziehen (Befund-Verifikation
-- 2026-08-18, externes Review-INFO "profiles.email driftet").
--
-- BEFUND: handle_new_user_profile() feuert nur AFTER INSERT auf auth.users
-- (20260516150000_create_profiles.sql). Aendert ein Nutzer seine Adresse
-- (verifyOTP emailChange), behaelt public.profiles die alte. Kein Leser im
-- Backend (Edge Functions greppen profiles nicht, ProfileSync selektiert
-- email nicht) — ABER der DSGVO-Datenexport (lib/src/services/
-- data_export.dart, select('*') auf profiles) liefert die veraltete Adresse
-- in der Selbstauskunft aus (Art.-15-Export mit unrichtigem Datum). Kein
-- Sicherheitsproblem, aber mehr als Kosmetik.
--
-- FIX: derselbe Trigger-Rumpf zusaetzlich AFTER UPDATE OF email. Die
-- Funktion ist dafuer bereits geeignet: on conflict (id) do update set
-- email = excluded.email; display_name wird aus den beim Adresswechsel
-- unveraenderten Auth-Metadaten identisch neu berechnet — die App schreibt
-- profiles.email/display_name nie direkt (ProfileSync fasst nur Zahlen- und
-- Enum-Spalten an), es gibt also nichts, was der Upsert ueberschreiben
-- koennte. Die WHEN-Klausel haelt den Trigger von UPDATEs fern, die die
-- Spalte email zwar im SET fuehren, den Wert aber nicht aendern.

drop trigger if exists on_auth_user_email_updated on auth.users;
create trigger on_auth_user_email_updated
  after update of email on auth.users
  for each row
  when (new.email is distinct from old.email)
  execute function public.handle_new_user_profile();
