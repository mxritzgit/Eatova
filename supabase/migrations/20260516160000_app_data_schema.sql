-- App data schema (multi-user with row level security).
--
-- Builds on 20260516150000_create_profiles.sql: extends profiles with
-- biometrics/daily goals and creates the app data tables (logs, meals, weight,
-- sleep, caffeine, stats). Every table carries user_id → auth.users(id) and an
-- RLS policy user_id = auth.uid(), so a user can structurally only see or
-- change their own rows.

-- ---------------------------------------------------------------------------
-- 1) Extend profiles with biometrics + daily goals (matches UserProfile)
-- ---------------------------------------------------------------------------
alter table public.profiles
  add column if not exists weight_kg                integer not null default 78,
  add column if not exists height_cm                integer not null default 178,
  add column if not exists age_years                integer not null default 30,
  add column if not exists sex                      text    not null default 'neutral',
  add column if not exists daily_steps_goal         integer not null default 8000,
  add column if not exists daily_kcal_goal          integer not null default 2200,
  add column if not exists daily_water_goal_ml      integer not null default 2500,
  add column if not exists daily_sleep_goal_minutes integer not null default 450,
  add column if not exists protein_goal_g           integer not null default 130,
  add column if not exists carbs_goal_g             integer not null default 240,
  add column if not exists fat_goal_g               integer not null default 70;

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'profiles_sex_check'
  ) then
    alter table public.profiles
      add constraint profiles_sex_check
      check (sex in ('male','female','neutral'));
  end if;
end $$;

-- The profiles DELETE policy was missing in the previous migration; needed so
-- users can reset their own account.
drop policy if exists "profiles_delete_own" on public.profiles;
create policy "profiles_delete_own"
  on public.profiles
  for delete
  to authenticated
  using (auth.uid() = id);

-- ---------------------------------------------------------------------------
-- 2) daily_logs — one entry per user per day
--    (water, steps, mood, completed plan blocks, habits)
-- ---------------------------------------------------------------------------
create table if not exists public.daily_logs (
  user_id              uuid not null references auth.users(id) on delete cascade,
  log_date             date not null,
  water_ml             integer not null default 0  check (water_ml >= 0),
  steps                integer not null default 0  check (steps >= 0),
  mood_score           smallint not null default 0 check (mood_score between 0 and 5),
  mood_note            text not null default '',
  completed_block_ids  text[] not null default '{}',
  completed_habit_ids  text[] not null default '{}',
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  primary key (user_id, log_date)
);

drop trigger if exists daily_logs_set_updated_at on public.daily_logs;
create trigger daily_logs_set_updated_at
  before update on public.daily_logs
  for each row execute function public.set_updated_at();

alter table public.daily_logs enable row level security;

drop policy if exists "daily_logs_select_own"  on public.daily_logs;
drop policy if exists "daily_logs_insert_own"  on public.daily_logs;
drop policy if exists "daily_logs_update_own"  on public.daily_logs;
drop policy if exists "daily_logs_delete_own"  on public.daily_logs;

create policy "daily_logs_select_own"
  on public.daily_logs for select to authenticated
  using (user_id = auth.uid());
create policy "daily_logs_insert_own"
  on public.daily_logs for insert to authenticated
  with check (user_id = auth.uid());
create policy "daily_logs_update_own"
  on public.daily_logs for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "daily_logs_delete_own"
  on public.daily_logs for delete to authenticated
  using (user_id = auth.uid());

-- ---------------------------------------------------------------------------
-- 3) logged_meals — logged meals (append-only log)
-- ---------------------------------------------------------------------------
create table if not exists public.logged_meals (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users(id) on delete cascade,
  logged_at     timestamptz not null default now(),
  forced_slot   text check (forced_slot in ('breakfast','lunch','dinner','snack')),
  meal_name     text not null,
  calories_kcal integer not null default 0,
  estimated_g   integer not null default 0,
  protein_g     numeric,
  carbs_g       numeric,
  fat_g         numeric,
  barcode       text,
  brand         text,
  source_label  text,
  payload       jsonb not null,
  created_at    timestamptz not null default now()
);

create index if not exists logged_meals_user_logged_at_idx
  on public.logged_meals (user_id, logged_at desc);

alter table public.logged_meals enable row level security;

drop policy if exists "logged_meals_select_own"  on public.logged_meals;
drop policy if exists "logged_meals_insert_own"  on public.logged_meals;
drop policy if exists "logged_meals_update_own"  on public.logged_meals;
drop policy if exists "logged_meals_delete_own"  on public.logged_meals;

create policy "logged_meals_select_own"
  on public.logged_meals for select to authenticated
  using (user_id = auth.uid());
create policy "logged_meals_insert_own"
  on public.logged_meals for insert to authenticated
  with check (user_id = auth.uid());
create policy "logged_meals_update_own"
  on public.logged_meals for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "logged_meals_delete_own"
  on public.logged_meals for delete to authenticated
  using (user_id = auth.uid());

-- ---------------------------------------------------------------------------
-- 4) favorite_meals — saved favorite meals
--    favorite_key matches FavoriteMeal.idFor (barcode:… or name:…)
-- ---------------------------------------------------------------------------
create table if not exists public.favorite_meals (
  user_id        uuid not null references auth.users(id) on delete cascade,
  favorite_key   text not null,
  meal_name      text not null,
  calories_kcal  integer not null default 0,
  estimated_g    integer not null default 0,
  barcode        text,
  brand          text,
  source_label   text,
  payload        jsonb not null,
  added_at       timestamptz not null default now(),
  primary key (user_id, favorite_key)
);

alter table public.favorite_meals enable row level security;

drop policy if exists "favorite_meals_select_own"  on public.favorite_meals;
drop policy if exists "favorite_meals_insert_own"  on public.favorite_meals;
drop policy if exists "favorite_meals_update_own"  on public.favorite_meals;
drop policy if exists "favorite_meals_delete_own"  on public.favorite_meals;

create policy "favorite_meals_select_own"
  on public.favorite_meals for select to authenticated
  using (user_id = auth.uid());
create policy "favorite_meals_insert_own"
  on public.favorite_meals for insert to authenticated
  with check (user_id = auth.uid());
create policy "favorite_meals_update_own"
  on public.favorite_meals for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "favorite_meals_delete_own"
  on public.favorite_meals for delete to authenticated
  using (user_id = auth.uid());

-- ---------------------------------------------------------------------------
-- 5) weight_log — weight measurements
-- ---------------------------------------------------------------------------
create table if not exists public.weight_log (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references auth.users(id) on delete cascade,
  recorded_at  timestamptz not null default now(),
  weight_kg    numeric(5,2) not null check (weight_kg > 0)
);

create index if not exists weight_log_user_recorded_at_idx
  on public.weight_log (user_id, recorded_at desc);

alter table public.weight_log enable row level security;

drop policy if exists "weight_log_select_own"  on public.weight_log;
drop policy if exists "weight_log_insert_own"  on public.weight_log;
drop policy if exists "weight_log_update_own"  on public.weight_log;
drop policy if exists "weight_log_delete_own"  on public.weight_log;

create policy "weight_log_select_own"
  on public.weight_log for select to authenticated
  using (user_id = auth.uid());
create policy "weight_log_insert_own"
  on public.weight_log for insert to authenticated
  with check (user_id = auth.uid());
create policy "weight_log_update_own"
  on public.weight_log for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "weight_log_delete_own"
  on public.weight_log for delete to authenticated
  using (user_id = auth.uid());

-- ---------------------------------------------------------------------------
-- 6) sleep_entries — one night per entry
-- ---------------------------------------------------------------------------
create table if not exists public.sleep_entries (
  user_id          uuid not null references auth.users(id) on delete cascade,
  sleep_date       date not null,
  bedtime_minutes  smallint not null check (bedtime_minutes between 0 and 1439),
  wake_minutes     smallint not null check (wake_minutes between 0 and 1439),
  quality          smallint not null check (quality between 1 and 5),
  created_at       timestamptz not null default now(),
  primary key (user_id, sleep_date)
);

alter table public.sleep_entries enable row level security;

drop policy if exists "sleep_entries_select_own"  on public.sleep_entries;
drop policy if exists "sleep_entries_insert_own"  on public.sleep_entries;
drop policy if exists "sleep_entries_update_own"  on public.sleep_entries;
drop policy if exists "sleep_entries_delete_own"  on public.sleep_entries;

create policy "sleep_entries_select_own"
  on public.sleep_entries for select to authenticated
  using (user_id = auth.uid());
create policy "sleep_entries_insert_own"
  on public.sleep_entries for insert to authenticated
  with check (user_id = auth.uid());
create policy "sleep_entries_update_own"
  on public.sleep_entries for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "sleep_entries_delete_own"
  on public.sleep_entries for delete to authenticated
  using (user_id = auth.uid());

-- ---------------------------------------------------------------------------
-- 7) caffeine_entries — one row per cup / intake
-- ---------------------------------------------------------------------------
create table if not exists public.caffeine_entries (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references auth.users(id) on delete cascade,
  consumed_at  timestamptz not null default now(),
  mg           integer not null check (mg > 0)
);

create index if not exists caffeine_entries_user_consumed_at_idx
  on public.caffeine_entries (user_id, consumed_at desc);

alter table public.caffeine_entries enable row level security;

drop policy if exists "caffeine_entries_select_own"  on public.caffeine_entries;
drop policy if exists "caffeine_entries_insert_own"  on public.caffeine_entries;
drop policy if exists "caffeine_entries_update_own"  on public.caffeine_entries;
drop policy if exists "caffeine_entries_delete_own"  on public.caffeine_entries;

create policy "caffeine_entries_select_own"
  on public.caffeine_entries for select to authenticated
  using (user_id = auth.uid());
create policy "caffeine_entries_insert_own"
  on public.caffeine_entries for insert to authenticated
  with check (user_id = auth.uid());
create policy "caffeine_entries_update_own"
  on public.caffeine_entries for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "caffeine_entries_delete_own"
  on public.caffeine_entries for delete to authenticated
  using (user_id = auth.uid());

-- ---------------------------------------------------------------------------
-- 8) lifetime_stats — cumulative counters per user (1:1 Dart LifetimeStats)
-- ---------------------------------------------------------------------------
create table if not exists public.lifetime_stats (
  user_id              uuid primary key references auth.users(id) on delete cascade,
  workouts_completed   integer not null default 0,
  meals_logged         integer not null default 0,
  water_total_ml       integer not null default 0,
  steps_recorded       integer not null default 0,
  weight_logs          integer not null default 0,
  session_start        timestamptz not null default now(),
  updated_at           timestamptz not null default now()
);

drop trigger if exists lifetime_stats_set_updated_at on public.lifetime_stats;
create trigger lifetime_stats_set_updated_at
  before update on public.lifetime_stats
  for each row execute function public.set_updated_at();

alter table public.lifetime_stats enable row level security;

drop policy if exists "lifetime_stats_select_own"  on public.lifetime_stats;
drop policy if exists "lifetime_stats_insert_own"  on public.lifetime_stats;
drop policy if exists "lifetime_stats_update_own"  on public.lifetime_stats;
drop policy if exists "lifetime_stats_delete_own"  on public.lifetime_stats;

create policy "lifetime_stats_select_own"
  on public.lifetime_stats for select to authenticated
  using (user_id = auth.uid());
create policy "lifetime_stats_insert_own"
  on public.lifetime_stats for insert to authenticated
  with check (user_id = auth.uid());
create policy "lifetime_stats_update_own"
  on public.lifetime_stats for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "lifetime_stats_delete_own"
  on public.lifetime_stats for delete to authenticated
  using (user_id = auth.uid());

-- ---------------------------------------------------------------------------
-- 9) Bootstrap trigger for lifetime_stats
--    handle_new_user_profile already bootstraps profiles; this second
--    auth.users trigger gives every new user a lifetime_stats row.
-- ---------------------------------------------------------------------------
create or replace function public.handle_new_user_stats()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.lifetime_stats (user_id)
  values (new.id)
  on conflict (user_id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created_stats on auth.users;
create trigger on_auth_user_created_stats
  after insert on auth.users
  for each row execute function public.handle_new_user_stats();

-- ---------------------------------------------------------------------------
-- 10) Backfill: existing auth.users rows created before the profiles migration
--     get their profiles and lifetime_stats rows. Idempotent.
-- ---------------------------------------------------------------------------
insert into public.profiles (id, email, display_name)
select
  u.id,
  u.email,
  coalesce(
    u.raw_user_meta_data->>'display_name',
    u.raw_user_meta_data->>'full_name',
    u.raw_user_meta_data->>'name',
    u.raw_user_meta_data->>'user_name',
    split_part(u.email, '@', 1),
    ''
  )
from auth.users u
left join public.profiles p on p.id = u.id
where p.id is null;

insert into public.lifetime_stats (user_id)
select id from auth.users
on conflict (user_id) do nothing;
