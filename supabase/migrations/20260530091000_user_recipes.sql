-- FitPilot — user_recipes (user-created recipes), purely additive.
-- RLS is strictly user_id = auth.uid(); GRANTs are EXPLICIT because raw SQL
-- does not issue them. No Dart client wiring yet.

-- ---------------------------------------------------------------------------
-- 1) Table
-- ---------------------------------------------------------------------------
create table if not exists public.user_recipes (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references auth.users(id) on delete cascade,
  slug           text not null,
  title          text not null,
  description    text not null default '',
  portion        text not null default '',
  ingredients    text not null default '',
  preparation    text not null default '',
  image_asset    text not null default '',
  calories_kcal  integer not null default 0 check (calories_kcal >= 0),
  protein_g      integer not null default 0 check (protein_g >= 0),
  carbs_g        integer not null default 0 check (carbs_g >= 0),
  fat_g          integer not null default 0 check (fat_g >= 0),
  estimated_g    integer not null default 0 check (estimated_g >= 0),
  categories     text[] not null default '{}',
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  unique (user_id, slug)
);

create index if not exists user_recipes_user_created_at_idx
  on public.user_recipes (user_id, created_at desc);

-- updated_at trigger (function from 20260516150000_create_profiles.sql)
drop trigger if exists user_recipes_set_updated_at on public.user_recipes;
create trigger user_recipes_set_updated_at
  before update on public.user_recipes
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- 2) Row Level Security — a user only sees/changes their own rows
-- ---------------------------------------------------------------------------
alter table public.user_recipes enable row level security;

drop policy if exists "user_recipes_select_own"  on public.user_recipes;
drop policy if exists "user_recipes_insert_own"  on public.user_recipes;
drop policy if exists "user_recipes_update_own"  on public.user_recipes;
drop policy if exists "user_recipes_delete_own"  on public.user_recipes;

create policy "user_recipes_select_own"
  on public.user_recipes for select to authenticated
  using (user_id = auth.uid());
create policy "user_recipes_insert_own"
  on public.user_recipes for insert to authenticated
  with check (user_id = auth.uid());
create policy "user_recipes_update_own"
  on public.user_recipes for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "user_recipes_delete_own"
  on public.user_recipes for delete to authenticated
  using (user_id = auth.uid());

-- ---------------------------------------------------------------------------
-- 3) GRANTs — explicit; service_role gets full access.
-- ---------------------------------------------------------------------------
grant select, insert, update, delete on public.user_recipes to authenticated;
grant all on public.user_recipes to service_role;
