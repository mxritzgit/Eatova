-- Sentinel-Rest, Migrations-Runde (2026-08-08). Zwei Punkte, die in PR #18
-- bewusst zurueckgestellt wurden, weil sie die Live-DB brauchen:
--
-- 1) get_chat_quota_today: der uid-null-Zweig antwortete mit VOLLEM
--    Kontingent ("kein Nutzerkontext" -> "used 0, remaining p_daily_limit").
--    Das ist exakt der Sentinel, den die Dart-Seite (W6-07,
--    ChatQuotaSnapshot.unknown) entfernt hat — er lebte im RPC weiter, und
--    der Client uebernimmt eine gelieferte Zeile ungeprueft als
--    Serveraussage. Kein Kontext ist keine Zahl: Exception. Praktisch
--    erreichbar war der Zweig nur fuer service_role-Aufrufe ohne User-JWT
--    (anon-EXECUTE ist seit 20260609120000 revoked); der normale Client
--    ruft mit User-JWT auf und ist unbetroffen.
--
-- 2) refund_chat_quota: claim_chat_quota reserviert den Tages-Slot VOR dem
--    teuren Antwort-Call. Scheitert die Edge Function danach
--    (Provider-Fehler, gescheiterter Message-Store), war der Slot bisher
--    ehrlich gemeldet, aber verloren — ein Abend mit Provider-Ausfall
--    konnte alle 5 Slots verbrennen, ohne eine einzige Antwort. Der Refund
--    gibt genau einen Slot zurueck und klemmt bei 0 (ein Refund ohne
--    vorherigen Claim darf keinen Gratis-Slot erzeugen).

create or replace function public.get_chat_quota_today(
  p_daily_limit integer default 5
) returns table (used integer, remaining integer, daily_limit integer)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_today date := (now() at time zone 'utc')::date;
  v_used  integer;
  v_uid   uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'EX_USER_REQUIRED' using errcode = '22023';
  end if;

  select used_count into v_used
    from public.chat_quota_usage
    where user_id = v_uid and day = v_today;

  v_used      := coalesce(v_used, 0);
  used        := v_used;
  remaining   := greatest(p_daily_limit - v_used, 0);
  daily_limit := p_daily_limit;
  return next;
end;
$$;

-- create or replace erhaelt die bestehenden Grants (authenticated +
-- service_role; anon seit 20260609120000 revoked) — hier nichts nachziehen.

create or replace function public.refund_chat_quota(
  p_user_id uuid
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_today date := (now() at time zone 'utc')::date;
begin
  if p_user_id is null then
    raise exception 'EX_USER_REQUIRED' using errcode = '22023';
  end if;

  update public.chat_quota_usage
     set used_count = greatest(used_count - 1, 0),
         updated_at = now()
   where user_id = p_user_id and day = v_today;
end;
$$;

-- Wie claim_chat_quota: nur die Edge Function (service_role) darf refunden —
-- ein Client, der seine eigene Quota zuruecksetzen kann, haette kein Limit.
revoke all on function public.refund_chat_quota(uuid) from public;
revoke all on function public.refund_chat_quota(uuid) from authenticated;
revoke all on function public.refund_chat_quota(uuid) from anon;
grant execute on function public.refund_chat_quota(uuid) to service_role;
