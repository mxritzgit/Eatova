-- Eatova — keep profiles.email in sync after an email change (2026-08-18).
--
-- handle_new_user_profile() only fired AFTER INSERT, so an email change left
-- public.profiles stale and the GDPR export shipped the old address.
--
-- FIX: run the same trigger body AFTER UPDATE OF email. The function already
-- upserts email, and the app never writes profiles.email directly, so nothing
-- is clobbered. The WHEN clause skips UPDATEs that do not change the value.

drop trigger if exists on_auth_user_email_updated on auth.users;
create trigger on_auth_user_email_updated
  after update of email on auth.users
  for each row
  when (new.email is distinct from old.email)
  execute function public.handle_new_user_profile();
