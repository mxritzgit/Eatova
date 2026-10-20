-- AI consent log and answer reports (P1, review 2026-10-19).
--
--   ai_consents  append-only log of the in-app AI consent per account. One
--                row per decision: `granted = true` with the explicit health
--                data consent (GDPR art. 9(2)(a)) as `health_data`, or a
--                withdrawal (`granted = false`, `health_data = false`). The
--                latest row by created_at is the account's state; the app
--                caches it per account and asks again on the next AI use when
--                there is none, it is a withdrawal or its version is older
--                than the app's.
--   ai_reports   "Report answer" on Coach output: the message id, the closed
--                reason code and whether the answer text or a generated
--                recipe picture was reported. No message content is copied;
--                the operator finds the message through its id (and the
--                session for answers the client still holds under a local
--                id).
--
-- Both are written by the app directly through PostgREST: consent needs a
-- network round trip anyway, and the client must not proceed with an AI call
-- when this insert fails. Column grants cover only what the client chooses;
-- user_id (auth.uid()), id and created_at come from defaults, so a client
-- can neither backdate a consent nor file a row for another account (the
-- insert policies check the owner as well). No update, no delete: the logs
-- are evidence and stay until the account is deleted (`on delete cascade`).
--
-- Consent is NOT enforced by the Edge Functions in this round: builds
-- installed before this release send AI requests without it and would break.
-- Server-side enforcement is a follow-up once those builds are gone.
--
-- Row bound: a BEFORE INSERT trigger caps each table per user and UTC day
-- (consents 20, reports 30). Real use is a handful per year; the bound stops
-- a tampered client from growing the tables without end. The probe is the
-- bounded `offset <cap - 1> limit 1` of enforce_user_row_cap
-- (20260829120000) over the (user_id, created_at) index, so its cost follows
-- the caller's own rows of the day. Concurrent inserts can overshoot by the
-- number of writers, which is accepted for the same reasons as there. A
-- withdrawal the bound rejects stays effective on the device (the app keeps
-- it pending and retries); the server log records it on a later day.
-- Idempotent.

create table if not exists public.ai_consents (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid()
    references auth.users(id) on delete cascade,
  version integer not null,
  granted boolean not null,
  health_data boolean not null,
  created_at timestamptz not null default now(),
  constraint ai_consents_version_check check (version between 1 and 1000),
  constraint ai_consents_health_data_check check (granted or not health_data)
);

create index if not exists ai_consents_user_created_idx
  on public.ai_consents (user_id, created_at desc);

comment on table public.ai_consents is
  'Append-only in-app AI consent log; latest row per user is the state. '
  'Withdrawal = granted false. Kept until account deletion.';
comment on column public.ai_consents.version is
  'Consent text version the user saw (app constant kAiConsentVersion).';
comment on column public.ai_consents.health_data is
  'Explicit consent to processing health data (GDPR art. 9(2)(a)).';

alter table public.ai_consents enable row level security;

drop policy if exists ai_consents_select_own on public.ai_consents;
create policy ai_consents_select_own on public.ai_consents for select to authenticated
  using (user_id = (select auth.uid()));
drop policy if exists ai_consents_insert_own on public.ai_consents;
create policy ai_consents_insert_own on public.ai_consents for insert to authenticated
  with check (user_id = (select auth.uid()));

revoke all on public.ai_consents from public, anon, authenticated;
grant select on public.ai_consents to authenticated;
grant insert (version, granted, health_data) on public.ai_consents to authenticated;
grant all on public.ai_consents to service_role;

create table if not exists public.ai_reports (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid()
    references auth.users(id) on delete cascade,
  message_id text not null,
  session_id uuid,
  target text not null default 'answer',
  reason text not null,
  created_at timestamptz not null default now(),
  constraint ai_reports_message_id_check check (
    char_length(message_id) between 1 and 64
    and message_id ~ '^[A-Za-z0-9_-]+$'
  ),
  constraint ai_reports_target_check check (target in ('answer', 'recipe_image')),
  constraint ai_reports_reason_check check (
    reason in ('incorrect', 'harmful', 'inappropriate', 'other')
  )
);

create index if not exists ai_reports_user_created_idx
  on public.ai_reports (user_id, created_at desc);

comment on table public.ai_reports is
  'Reports of Coach output by its user: message id and closed reason code, '
  'no content. Kept until account deletion.';
comment on column public.ai_reports.message_id is
  'chat_messages.id, or the client-local id of an answer not yet reloaded '
  '(then session_id and created_at locate it).';

alter table public.ai_reports enable row level security;

drop policy if exists ai_reports_select_own on public.ai_reports;
create policy ai_reports_select_own on public.ai_reports for select to authenticated
  using (user_id = (select auth.uid()));
drop policy if exists ai_reports_insert_own on public.ai_reports;
create policy ai_reports_insert_own on public.ai_reports for insert to authenticated
  with check (user_id = (select auth.uid()));

revoke all on public.ai_reports from public, anon, authenticated;
grant select on public.ai_reports to authenticated;
grant insert (message_id, session_id, target, reason) on public.ai_reports
  to authenticated;
grant all on public.ai_reports to service_role;

-- Per user and UTC day. Generic over tables with user_id and created_at; the
-- cap is the trigger argument. Refuses an unattributable row like
-- enforce_user_row_cap instead of letting it through uncapped.
create or replace function public.enforce_user_daily_row_cap()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_grenze integer := tg_argv[0]::integer;
  v_tagesbeginn timestamptz :=
    pg_catalog.date_trunc('day', pg_catalog.now() at time zone 'utc')
      at time zone 'utc';
  v_voll boolean;
begin
  if new.user_id is null then
    raise exception
      'EX_ROW_CAP_NO_OWNER: public.%.user_id ist null, keine Begrenzung moeglich',
      tg_table_name
      using errcode = '22023';
  end if;

  execute pg_catalog.format(
    'select exists (select 1 from public.%I t where t.user_id = $1 '
    'and t.created_at >= $2 offset %s limit 1)',
    tg_table_name, v_grenze - 1
  ) into v_voll using new.user_id, v_tagesbeginn;

  if v_voll then
    raise exception
      'EX_DAILY_ROW_CAP_EXCEEDED: public.% haelt heute bereits % Zeilen fuer diesen Nutzer',
      tg_table_name, v_grenze
      using errcode = '22023';
  end if;

  return new;
end;
$$;

comment on function public.enforce_user_daily_row_cap() is
  'BEFORE INSERT row trigger: caps the rows one user may add to the table per '
  'UTC day. Argument: the cap. Needs user_id and created_at. A null owner '
  'raises EX_ROW_CAP_NO_OWNER. Review 2026-10-19 (AI consent and reports).';

-- EXECUTE is checked at CREATE TRIGGER time only, so the triggers fire
-- without a client grant (as for enforce_user_row_cap).
revoke execute on function public.enforce_user_daily_row_cap()
  from public, anon, authenticated;
grant execute on function public.enforce_user_daily_row_cap() to service_role;

drop trigger if exists ai_consents_daily_cap on public.ai_consents;
create trigger ai_consents_daily_cap
  before insert on public.ai_consents
  for each row
  execute function public.enforce_user_daily_row_cap('20');

drop trigger if exists ai_reports_daily_cap on public.ai_reports;
create trigger ai_reports_daily_cap
  before insert on public.ai_reports
  for each row
  execute function public.enforce_user_daily_row_cap('30');
