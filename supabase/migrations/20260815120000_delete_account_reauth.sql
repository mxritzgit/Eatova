-- Server-side re-auth for account deletion (review 2026-08-15, finding 1).
-- The mail-code hurdle lived in the app alone, so a stolen session JWT could
-- delete the account via a direct RPC call.
--
-- The RPC now needs a JWT whose `amr` claim carries a method 'otp' or
-- 'recovery' entry younger than 5 minutes. Only POST /auth/v1/verify with a
-- valid mail code produces one; the in-app flow satisfies it because the RPC
-- immediately follows verifyOTP. A token refresh does NOT extend freshness.
--
-- 5 minutes keeps the replay window small (the client calls within < 2 s).
-- Fail-closed: missing, non-array or stale amr -> EX_REAUTH_REQUIRED
-- (errcode 28000, PostgREST answers 403). '22023' remains the uid guard.

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

  -- Newest mail-proving entry. Non-objects and non-numeric timestamps do not
  -- count (fail-closed instead of a cast error); 12 digits keep to_timestamp
  -- in a safe range.
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
