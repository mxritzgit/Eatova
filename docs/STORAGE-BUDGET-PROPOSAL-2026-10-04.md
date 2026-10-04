# Proposal: per-account storage budget (D1), 2026-10-04

**Status: not applied.** This is a draft for the owner to decide on. It is
not a migration and does not live in `supabase/migrations/`. Applying it
means adding a migration, applying it live, and handling the client and test
follow-ups listed below.

## Finding

Row caps (`20260829120000_row_caps_and_hardening.sql`) limit how many rows
an account may write, but not how many bytes. A local probe as
`authenticated`, with 100 rows each through the normal direct inserts and
`save_planned_meal` and low-compressibility payloads, added:

| Table | Added |
|---|---|
| `logged_meals` | +20 MB |
| `favorite_meals` | +20 MB |
| `planned_meals` | +28 MB |

At the row caps, that is about 13 GB for one confirmed account. On the Free
plan, a project above 500 MB goes read-only for every user. That would
block writes, quota claims and rate gates, and it takes about 2,500
ordinary 200 kB requests from a single account. On a paid plan, disk grows
and is billed instead.

`apply_sync_operation` (250 kB payloads) behaves the same way.
`increment_lifetime_stats` adds a 131-byte `lifetime_stats_requests` row per
fresh request id and keeps it for 30 days, with no per-account cap.

## Draft

The draft below sets a 64 MiB default per account and fails with error
`PT507` (HTTP 507). The backend reviewer verified it against a local
PostgreSQL 17.6 replay of all migrations:
- junk inserts stopped after 337 rows at 64 MB;
- direct writes and RPC writes were both charged, and deletes credited;
- another account was unaffected;
- account erasure left no budget row;
- `rls_cross_user.sql` and `ai_provider_budget.sql` still passed.

```sql
create table if not exists public.account_storage_usage (
  user_id uuid primary key references auth.users(id) on delete cascade,
  used_bytes bigint not null default 0 check (used_bytes >= 0),
  budget_bytes bigint not null default 67108864 check (budget_bytes >= 67108864));
alter table public.account_storage_usage enable row level security;
revoke all on public.account_storage_usage from public, anon, authenticated;
grant all on public.account_storage_usage to service_role;
create or replace function public.charge_account_storage() returns trigger
language plpgsql security definer set search_path = pg_catalog as $$
declare
  old_size bigint := case when tg_op in ('UPDATE','DELETE') then octet_length(to_jsonb(old)::text) end;
  new_size bigint := case when tg_op in ('INSERT','UPDATE') then octet_length(to_jsonb(new)::text) end;
begin
  if old_size is not null and exists (select 1 from auth.users where id = old.user_id) then
    update public.account_storage_usage set used_bytes = greatest(used_bytes - old_size, 0)
     where user_id = old.user_id;
  end if;
  if new_size is not null then
    insert into public.account_storage_usage (user_id) values (new.user_id) on conflict (user_id) do nothing;
    update public.account_storage_usage set used_bytes = used_bytes + new_size
     where user_id = new.user_id and used_bytes + new_size <= budget_bytes;
    if not found then raise exception 'EX_ACCOUNT_STORAGE_CAPACITY' using errcode = 'PT507'; end if;
  end if;
  return null;
end; $$;
revoke all on function public.charge_account_storage() from public, anon, authenticated;
grant execute on function public.charge_account_storage() to service_role;
do $$ declare t text; begin
  foreach t in array array['logged_meals','favorite_meals','planned_meals','training_history',
    'training_plans','weight_log','chat_sessions','shopping_checks','lifetime_stats_requests'] loop
    execute format('drop trigger if exists %I on public.%I', t||'_storage_budget', t);
    execute format('create trigger %I after insert or update or delete on public.%I for each row execute function public.charge_account_storage()', t||'_storage_budget', t);
  end loop; end; $$;
insert into public.account_storage_usage (user_id, used_bytes, budget_bytes)
select user_id, sum(bytes), greatest(67108864, sum(bytes)) from (
  select user_id, octet_length(to_jsonb(t)::text)::bigint bytes from public.logged_meals t
  union all select user_id, octet_length(to_jsonb(t)::text) from public.favorite_meals t
  union all select user_id, octet_length(to_jsonb(t)::text) from public.planned_meals t
  union all select user_id, octet_length(to_jsonb(t)::text) from public.training_history t
  union all select user_id, octet_length(to_jsonb(t)::text) from public.training_plans t
  union all select user_id, octet_length(to_jsonb(t)::text) from public.weight_log t
  union all select user_id, octet_length(to_jsonb(t)::text) from public.chat_sessions t
  union all select user_id, octet_length(to_jsonb(t)::text) from public.shopping_checks t
  union all select user_id, octet_length(to_jsonb(t)::text) from public.lifetime_stats_requests t) u
group by user_id
on conflict (user_id) do update set used_bytes = excluded.used_bytes,
  budget_bytes = greatest(public.account_storage_usage.budget_bytes, excluded.budget_bytes);
```

## Follow-ups if applied

- **Invariant test:** add `charge_account_storage` to
  `test/migrations/rls_invariants_test.dart` as a server-only definer.
- **Schema docs:** regenerate `supabase/SCHEMA_STATE.md`.
- **SQL test:** add one under `test/migrations`.
- **Client:** add an `EX_ACCOUNT_STORAGE_CAPACITY` entry to
  `SyncCapacityKind`. Today it would fall into the `operationReceipts`
  default, which keeps the intent but shows the wrong text.
- **Ops:** choose the budget size and set a database-size alert.
