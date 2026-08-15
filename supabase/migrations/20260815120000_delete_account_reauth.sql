-- Serverseitige Re-Auth-Pflicht fuer die Kontoloeschung (Nachpruefung
-- 2026-08-15, Befund 1). Bisher prueft delete_account() nur auth.uid();
-- die Mail-Code-Huerde lebte allein in der App (settings_screen.dart) —
-- ein erbeutetes Session-JWT loeschte das Konto per direktem RPC-Call.
--
-- Jetzt verlangt der RPC ein JWT, dessen `amr`-Claim (Authentication
-- Methods Reference; signierter Token-Bestandteil, in Postgres via
-- auth.jwt() lesbar) einen Eintrag mit method 'otp' oder 'recovery' und
-- einem Timestamp juenger als 5 Minuten traegt. Genau so ein JWT entsteht
-- ausschliesslich durch POST /auth/v1/verify mit einem gueltigen Mail-Code
-- (GoTrue legt dabei eine NEUE Session mit frischem amr-Eintrag an;
-- supabase/auth: internal/api/verify.go -> issueRefreshToken(models.OTP),
-- internal/models/sessions.go CalculateAALAndAMR). Der In-App-Flow erfuellt
-- das automatisch: verifyOTP ersetzt die Session, der unmittelbar folgende
-- RPC traegt das neue Token (kein Nutzer-Schritt dazwischen).
--
-- 'otp' ist der Wert des heutigen Implicit-Verify-Flows; 'recovery' deckt
-- den PKCE-/token_hash-Pfad ab. Ein Token-Refresh verlaengert die Frische
-- NICHT (amr-Timestamp bleibt der der Verifikation). 5 Minuten: der Client
-- ruft in < 2 s, die Uhr-Schraeglage GoTrue vs. Postgres liegt im
-- Sekundenbereich (beide Supabase-Infra); klein halten begrenzt das
-- Replay-Fenster eines unmittelbar nach legitimer Verifikation gestohlenen
-- JWTs. Fail-closed: fehlt amr, ist es kein Array oder ist kein Eintrag
-- frisch -> EX_REAUTH_REQUIRED (errcode 28000; PostgREST antwortet 403).
--
-- EX_USER_REQUIRED/'22023' bleibt unveraendert der uid-Guard
-- (20260603100000_security_hardening_followup.sql).

create or replace function public.delete_account()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  amr jsonb;
  frische_bestaetigung timestamptz;
begin
  if auth.uid() is null then
    raise exception 'EX_USER_REQUIRED' using errcode = '22023';
  end if;

  amr := auth.jwt() -> 'amr';

  if amr is null or jsonb_typeof(amr) is distinct from 'array' then
    raise exception 'EX_REAUTH_REQUIRED' using errcode = '28000';
  end if;

  -- Juengster mailbeweisender Eintrag. Defensive Filter: Nicht-Objekte und
  -- nicht-numerische Timestamps zaehlen nicht (fail-closed statt Cast-Fehler);
  -- 12 Ziffern decken Unix-Sekunden bis weit nach Jahr 30000 und halten
  -- to_timestamp im sicheren Bereich.
  select max(to_timestamp((eintrag ->> 'timestamp')::bigint))
    into frische_bestaetigung
    from jsonb_array_elements(amr) as eintrag
   where jsonb_typeof(eintrag) = 'object'
     and eintrag ->> 'method' in ('otp', 'recovery')
     and (eintrag ->> 'timestamp') ~ '^[0-9]{1,12}$';

  if frische_bestaetigung is null
     or frische_bestaetigung < now() - interval '5 minutes' then
    raise exception 'EX_REAUTH_REQUIRED' using errcode = '28000';
  end if;

  delete from auth.users where id = auth.uid();
end;
$$;

revoke execute on function public.delete_account() from public, anon;
grant execute on function public.delete_account() to authenticated;
