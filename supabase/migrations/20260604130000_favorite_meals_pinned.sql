-- ---------------------------------------------------------------------------
-- favorite_meals.pinned — curatable favorites (PROD-4).
-- true  = user-pinned, kept forever, never capped.
-- false = auto-recents, capped to the last N by the client.
-- Default false keeps existing rows as recents, so behaviour is unchanged.
-- ---------------------------------------------------------------------------
alter table public.favorite_meals
  add column if not exists pinned boolean not null default false;
