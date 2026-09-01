-- Performance audit 2026-09-01, finding A7 — public.chat_quota_usage is the
-- one table in this schema that nothing ever deletes from.
--
-- WHAT GROWS. claim_chat_quota() writes one row per user per UTC day (primary
-- key (user_id, day)), and neither it nor refund_chat_quota() nor
-- get_chat_quota_today() has ever removed one: an account that talks to the
-- coach every day leaves 365 rows a year behind, permanently, so the table
-- grows with TIME as well as with the user count. Every neighbouring table
-- already carries its guard — edge_rate_limits is pruned after two days
-- (20260517220000), lifetime_stats_requests after thirty (20260814120000), and
-- 20260829120000 caps how many rows a CLIENT may write. chat_quota_usage
-- slipped through all three precisely because the client cannot write it: it
-- is filled by a security-definer RPC, so no row-cap trigger and no rate limit
-- ever sees it.
--
-- WHO READS AN OLD ROW. Nothing operational. claim_chat_quota(),
-- refund_chat_quota() and get_chat_quota_today() all pin
-- `day = (now() at time zone 'utc')::date` and touch the current day only;
-- there is no streak, no statistic and no audit over the history, and the
-- client holds no write grant to build one. The single reader of anything
-- older is the GDPR export (DataExportService,
-- lib/src/services/data_export.dart), which selects the table whole so the
-- user gets what we hold. That is what fixes the window below: these rows are
-- worth keeping exactly as long as they are worth exporting.
--
-- THE WINDOW: 90 DAYS. A quarter of usage history answers the one question a
-- past row can answer at all ("when did I run into the limit?"), keeps the
-- export non-trivial, and bounds the table by the number of ACTIVE users
-- instead of by time — at most 91 rows per user rather than 365 a year. It
-- sits deliberately between the two windows the schema already has: far longer
-- than the two days of edge_rate_limits, which hold a hashed IP and are pure
-- infrastructure, and longer than the 30-day deduplication markers, because
-- unlike either of those a quota row is data the user may ask us for.
--
-- TODAY IS UNTOUCHABLE, and not merely because 90 is a large number.
-- claim_chat_quota() reserves a slot by inserting and then locking exactly the
-- row for the current UTC day; deleting that row mid-day would hand the user a
-- fresh set of five slots — a free reset of the daily limit, the very thing
-- 20260814120000 revoked every client write to prevent. The delete is
-- therefore guarded twice: p_keep_days must be >= 1, so no argument can walk
-- the cutoff up to today, and the DELETE itself carries a redundant
-- `day < v_today` that no argument, and no later edit of the cutoff
-- arithmetic, can reach past. The second guard has an operational side too: it
-- keeps the prune off the `for update` row a concurrent claim is holding, so
-- this housekeeping neither waits on nor blocks a live coach request.
--
-- HOW IT RUNS: from prune_edge_rate_limits(), the maintenance RPC all three
-- Edge Functions already call fire-and-forget on every request they let
-- through. Not pg_cron: the extension is enabled nowhere in this repo, and the
-- CI job `rls-postgres` applies every migration to a bare postgres:16 with
-- ON_ERROR_STOP=1, where `create extension pg_cron` does not exist — a
-- scheduler dependency would fail the from-scratch replay this whole directory
-- is verified on. prune_chat_quota_usage() is nevertheless standalone and
-- independently callable with its own grant, so attaching a scheduler later,
-- or clearing the first backlog by hand, changes the caller and nothing else.
--
-- FREQUENCY. A separate finding of the same audit turns that opportunistic
-- call from per-request into sampled, so the prune fires less often; for
-- retention that is irrelevant. In steady state exactly one row per active
-- user falls out of the window per day, which a handful of calls a day covers
-- at p_max_rows = 1000 per call, and a row that outlives its window by a quiet
-- period costs storage and nothing else — the same honesty the privacy policy
-- already states for the two-day rate-limit records.
--
-- WHAT THIS OWES THE PRIVACY POLICY. PRIVACY.md closes its Retention section
-- with "No other data has an automatic expiry" and lists three exceptions.
-- This migration adds a fourth, and that sentence stops being true until the
-- section — and the same text on eatova.de — names the coach-quota counters.
--
-- Idempotent throughout (`create index if not exists`, `create or replace`,
-- plain grants), so the file replays from an empty database and re-applies on
-- the live one.

-- ---------------------------------------------------------------------------
-- 1) An index the retention delete can actually use
--
-- The only index on the table is the primary key (user_id, day). `day` sits in
-- second place, so it is no usable prefix for `where day < …`, and every prune
-- call would read the whole table — including the overwhelming majority of
-- calls that find nothing at all because the backlog was cleared minutes
-- earlier. With this index the common case is one index probe that stops at
-- the first row on or after the cutoff, instead of a sequential scan whose
-- cost grows with exactly the table this migration exists to bound. Same
-- reasoning as edge_rate_limits_window_start_idx in 20260829120000.
-- ---------------------------------------------------------------------------
create index if not exists chat_quota_usage_day_idx
  on public.chat_quota_usage (day);

-- ---------------------------------------------------------------------------
-- 2) The retention itself
-- ---------------------------------------------------------------------------
create or replace function public.prune_chat_quota_usage(
  p_keep_days integer default 90,
  p_max_rows  integer default 1000
) returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_today   date := (now() at time zone 'utc')::date;
  v_cutoff  date;
  v_deleted integer;
begin
  -- The window may never reach today (see header). At the tightest argument
  -- this rule allows, the newest deletable row is still the day before
  -- yesterday. A null or a 0 is a misconfiguration, and it says so rather than
  -- quietly handing every user a fresh set of daily slots.
  if p_keep_days is null or p_keep_days < 1 then
    raise exception 'EX_RETENTION_WINDOW: p_keep_days must be >= 1, got %',
      coalesce(p_keep_days::text, 'null')
      using errcode = '22023';
  end if;
  -- The batch bound is the whole point of the second parameter: without one
  -- this is an unbounded DELETE taking a row lock per row on a table that,
  -- before the first prune, may hold every row ever written.
  if p_max_rows is null or p_max_rows < 1 or p_max_rows > 100000 then
    raise exception 'EX_RETENTION_BATCH: p_max_rows must be 1..100000, got %',
      coalesce(p_max_rows::text, 'null')
      using errcode = '22023';
  end if;

  v_cutoff := v_today - p_keep_days;

  -- Bounded delete: the p_max_rows OLDEST expired rows, picked through
  -- chat_quota_usage_day_idx in day order — so repeated calls make monotonic
  -- progress instead of re-reading the same head of the table — and joined
  -- back on the primary key. A ctid join would do the same work, but the key
  -- says which row it means and survives a concurrent update of that row.
  --
  -- `z.day < v_today` is redundant against v_cutoff and stays anyway: it is
  -- the statement-level guarantee that this delete can never take the row a
  -- live claim_chat_quota() is holding, whatever arguments it is called with.
  delete from public.chat_quota_usage z
   using (
     select t.user_id, t.day
       from public.chat_quota_usage t
      where t.day < v_cutoff
      order by t.day
      limit p_max_rows
   ) expired
   where z.user_id = expired.user_id
     and z.day     = expired.day
     and z.day     < v_today;

  get diagnostics v_deleted = row_count;
  return v_deleted;
end;
$$;

comment on function public.prune_chat_quota_usage(integer, integer) is
  'Retention for public.chat_quota_usage: deletes at most p_max_rows rows '
  'older than p_keep_days (default 90) and NEVER the current UTC day — '
  'claim_chat_quota() reserves the daily slot in that row, so removing it '
  'would be a free reset of the five-per-day limit. Returns the number of rows '
  'deleted. Called in passing by prune_edge_rate_limits(); safe to call '
  'directly to work off a backlog. Performance audit 2026-09-01, A7.';

revoke all on function public.prune_chat_quota_usage(integer, integer)
  from public, anon, authenticated;
grant execute on function public.prune_chat_quota_usage(integer, integer)
  to service_role;

-- ---------------------------------------------------------------------------
-- 3) Wiring: the maintenance call that already exists carries it
--
-- The two-day edge_rate_limits delete is unchanged from 20260517220000; new
-- are the second job and the block around it. Order and return value stay as
-- they were: the rate-limit prune runs first and its row count is what the
-- function returns, because that is what the name promises and what
-- supabase/functions/_shared/rate_limit_prune.ts logs against.
--
-- The exception block is not decoration. Without it a failing quota prune
-- would roll the whole function back, the already successful rate-limit delete
-- included — a housekeeping job added later must not be able to take the older
-- one down with it. `raise warning` keeps a permanently failing prune visible
-- in the Postgres log instead of swallowing it; the Edge Functions never read
-- this result, so nothing else would ever notice.
-- ---------------------------------------------------------------------------
create or replace function public.prune_edge_rate_limits()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_deleted integer;
begin
  delete from public.edge_rate_limits
  where window_start < now() - interval '2 days';
  get diagnostics v_deleted = row_count;

  begin
    perform public.prune_chat_quota_usage();
  exception
    when others then
      raise warning 'prune_chat_quota_usage failed: % (%)', sqlerrm, sqlstate;
  end;

  return v_deleted;
end;
$$;

comment on function public.prune_edge_rate_limits() is
  'Opportunistic housekeeping, called fire-and-forget by all three Edge '
  'Functions: deletes edge_rate_limits rows older than two days and, in '
  'passing, expired chat_quota_usage rows via prune_chat_quota_usage() — '
  'guarded, so a failure there cannot roll back the rate-limit delete. The '
  'return value counts edge_rate_limits rows only, as the name says. '
  'Performance audit 2026-09-01, A7.';

-- `create or replace` keeps the existing ACL (service_role only, since
-- 20260517220000) — nothing to re-grant here.
