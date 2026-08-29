-- Review 2026-08-29 — three findings on the DIRECT PostgREST path, which no
-- Edge Function and therefore no `consume_edge_rate_limit` ever sees:
--
--   P7-03 (medium)  per-user ROW CAPS on the client-writable tables.
--   P7-01 (low)     an index for prune_edge_rate_limits().
--   P7-05 (low)     the unused DELETE right on public.profiles goes away.
--
-- Purely additive apart from the profiles revoke; every step is idempotent, so
-- the file replays from an empty database and re-applies on the live one.

-- ---------------------------------------------------------------------------
-- 1) P7-03 — per-user row caps
--
-- 20260819140000 caps the SIZE of a user_recipes row and 20260517220000 the
-- size of a logged_meals/favorite_meals row, but nothing has ever capped the
-- NUMBER of rows. RLS answers "whose row is this", not "how many"; the three
-- Edge Function rate limits do not apply because the app writes these tables
-- through PostgREST directly. A tampered client can therefore insert without
-- end: storage, backup size and every full-table read grow with it.
--
-- The caps below are storage guards, not product rules. Each sits an order of
-- magnitude above the heaviest realistic use, so a real user cannot meet one:
--
--   logged_meals   50000  one row per logged item, never deduplicated. A heavy
--                         tracker logging 15 items every single day reaches
--                         5500/year — the cap is roughly nine such years.
--   weight_log     50000  same shape; five weigh-ins a day for 25 years.
--   favorite_meals  5000  the client keeps only 5 auto-recents
--                         (`_maxAutoRecents`) and deletes the ones that fall
--                         off; the open half is manual pinning, and the read
--                         path already stops at `favoritesLimit = 200`.
--   user_recipes    5000  read path stops at `userRecipesLimit = 200`; coach
--                         recipes additionally cost one of five daily chat
--                         quota slots.
--   chat_sessions   5000  one new conversation per day for over thirteen
--                         years.
--
-- MECHANISM. A `before insert` row trigger, but deliberately not the naive
-- `count(*)`:
--
--   * The probe is `… offset <cap - 1> limit 1`, so the index scan stops at
--     the cap instead of counting the whole set. Its cost is proportional to
--     the CALLER'S OWN rows and bounded by the cap — a user with 300 meals
--     pays 300 index tuples, and only someone actually attacking the cap pays
--     the full scan, which is the one case where slowing down is the point.
--   * Every capped table carries user_id as the LEADING index column
--     (logged_meals_user_logged_at_idx, the favorite_meals PK,
--     user_recipes_user_created_at_idx, weight_log_user_recorded_at_idx,
--     chat_sessions_user_recent_idx), so the probe is an index-only scan.
--   * The app writes through `upsert(… onConflict: …)`, i.e. `insert … on
--     conflict do update`, and a BEFORE INSERT trigger fires BEFORE the
--     conflict is resolved. An upsert onto an existing row replaces it and
--     grows nothing, so the trigger looks the identity up first and returns
--     early — otherwise a replayed outbox item would start failing at the cap.
--   * `errcode = '22023'`, the class this repo already uses for its guards
--     (EX_USER_REQUIRED). The client outbox treats class 22 as
--     payload-determined and drops the item at once; the default P0001 would
--     make it retry on the backoff ladder for 24 hours first.
--
-- KNOWN AND ACCEPTED: a single multi-row INSERT can overshoot, because a
-- BEFORE ROW trigger does not see the rows its own statement inserted. The app
-- writes one row per statement, and an overshoot of a batch length against a
-- five-figure cap changes nothing about the purpose of the guard.
-- ---------------------------------------------------------------------------

create or replace function public.enforce_user_row_cap()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_besitzer_spalte text    := tg_argv[0];
  v_grenze          integer := tg_argv[1]::integer;
  v_identitaet      text    := nullif(tg_argv[2], '');
  v_besitzer        uuid;
  v_ersetzt         boolean;
  v_voll            boolean;
begin
  execute format('select ($1).%I', v_besitzer_spalte)
    into v_besitzer using new;
  if v_besitzer is null then
    return new;
  end if;

  -- Upsert onto an existing row: replaces, does not grow.
  if v_identitaet is not null then
    execute format(
      'select exists (select 1 from public.%I t '
      'where t.%I = $1 and t.%I is not distinct from ($2).%I)',
      tg_table_name, v_besitzer_spalte, v_identitaet, v_identitaet
    ) into v_ersetzt using v_besitzer, new;
    if v_ersetzt then
      return new;
    end if;
  end if;

  -- Bounded probe: is there already a `v_grenze`-th row for this owner?
  execute format(
    'select exists (select 1 from public.%I t where t.%I = $1 offset %s limit 1)',
    tg_table_name, v_besitzer_spalte, v_grenze - 1
  ) into v_voll using v_besitzer;

  if v_voll then
    raise exception
      'EX_ROW_CAP_EXCEEDED: public.% haelt bereits % Zeilen fuer diesen Nutzer',
      tg_table_name, v_grenze
      using errcode = '22023';
  end if;

  return new;
end;
$$;

comment on function public.enforce_user_row_cap() is
  'BEFORE INSERT row trigger: caps the rows one user may hold in the table. '
  'Arguments: owner column, cap, identity column for the upsert check (empty '
  'string when the table has none). Review 2026-08-29, P7-03.';

-- EXECUTE is only checked at CREATE TRIGGER time, so the triggers below keep
-- firing without any client grant (same reasoning as 20260802120000).
revoke execute on function public.enforce_user_row_cap()
  from public, anon, authenticated;
grant execute on function public.enforce_user_row_cap() to service_role;

drop trigger if exists logged_meals_row_cap on public.logged_meals;
create trigger logged_meals_row_cap
  before insert on public.logged_meals
  for each row
  execute function public.enforce_user_row_cap('user_id', '50000', 'id');

drop trigger if exists weight_log_row_cap on public.weight_log;
create trigger weight_log_row_cap
  before insert on public.weight_log
  for each row
  execute function public.enforce_user_row_cap('user_id', '50000', 'id');

drop trigger if exists favorite_meals_row_cap on public.favorite_meals;
create trigger favorite_meals_row_cap
  before insert on public.favorite_meals
  for each row
  execute function public.enforce_user_row_cap(
    'user_id', '5000', 'favorite_key');

drop trigger if exists user_recipes_row_cap on public.user_recipes;
create trigger user_recipes_row_cap
  before insert on public.user_recipes
  for each row
  execute function public.enforce_user_row_cap('user_id', '5000', 'slug');

-- chat_sessions has no natural identity: every "new conversation" is a fresh
-- random id, through create_chat_session() as well as through the direct
-- PostgREST insert the policies still allow.
drop trigger if exists chat_sessions_row_cap on public.chat_sessions;
create trigger chat_sessions_row_cap
  before insert on public.chat_sessions
  for each row
  execute function public.enforce_user_row_cap('user_id', '5000', '');

-- ---------------------------------------------------------------------------
-- 2) P7-01 — an index prune_edge_rate_limits() can actually use
--
-- The only index on public.edge_rate_limits is the primary key
-- (scope, subject_hash, window_start, window_seconds). `window_start` sits in
-- third place, so it is no usable prefix for the retention delete
-- (`where window_start < now() - interval '2 days'`), which therefore reads
-- the whole table. All three Edge Functions call the prune unconditionally on
-- every request they let through.
--
-- Not acute — 2 days of retention keep the table at roughly 100-200 rows per
-- active user — but it grows with the user count, and the fix is one index.
-- ---------------------------------------------------------------------------

create index if not exists edge_rate_limits_window_start_idx
  on public.edge_rate_limits (window_start);

-- ---------------------------------------------------------------------------
-- 3) P7-05 — profiles: DELETE for `authenticated` goes away
--
-- The policy and the table grant are from 20260516160000 ("so users can reset
-- their own account"); that reset never shipped. Account deletion runs through
-- rpc('delete_account'), which removes the auth.users row and lets the
-- `on delete cascade` take the profile with it — the client never issues a
-- DELETE on public.profiles.
--
-- What the unused right could do: erase a profile row and with it
-- `daily_kcal_goal_before_live_reset`, the server-only snapshot from
-- 20260828100000 that exists precisely because it cannot be recomputed. The
-- bootstrap trigger only rebuilds the row on the NEXT auth event, and it
-- rebuilds it empty.
--
-- Not affected: `profiles.email` was refilled on the next address change even
-- before this (on_auth_user_email_updated, 20260818120000) — that was never
-- the argument for keeping DELETE.
-- ---------------------------------------------------------------------------

drop policy if exists "profiles_delete_own" on public.profiles;
revoke delete on public.profiles from authenticated;
