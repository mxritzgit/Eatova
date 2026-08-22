-- Coach chat: multi-session support, replacing the single running chat per
-- user. Adds chat_sessions (conversation threads), chat_messages.session_id
-- with a backfill into one default session per user, and the RPCs to list,
-- ensure, create, rename and delete sessions.

-- ---------------------------------------------------------------------------
-- chat_sessions
-- ---------------------------------------------------------------------------
create table if not exists public.chat_sessions (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null references auth.users(id) on delete cascade,
  title           text not null default 'Neue Unterhaltung',
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  last_message_at timestamptz not null default now()
);

create index if not exists chat_sessions_user_recent_idx
  on public.chat_sessions (user_id, last_message_at desc);

alter table public.chat_sessions enable row level security;

drop policy if exists "chat_sessions_select_own" on public.chat_sessions;
create policy "chat_sessions_select_own"
  on public.chat_sessions
  for select
  to authenticated
  using (auth.uid() = user_id);

drop policy if exists "chat_sessions_insert_own" on public.chat_sessions;
create policy "chat_sessions_insert_own"
  on public.chat_sessions
  for insert
  to authenticated
  with check (auth.uid() = user_id);

drop policy if exists "chat_sessions_update_own" on public.chat_sessions;
create policy "chat_sessions_update_own"
  on public.chat_sessions
  for update
  to authenticated
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

drop policy if exists "chat_sessions_delete_own" on public.chat_sessions;
create policy "chat_sessions_delete_own"
  on public.chat_sessions
  for delete
  to authenticated
  using (auth.uid() = user_id);

grant select, insert, update, delete on public.chat_sessions to authenticated;
grant all on public.chat_sessions to service_role;

-- ---------------------------------------------------------------------------
-- chat_messages.session_id (nullable, backfilled into a default session)
-- ---------------------------------------------------------------------------
alter table public.chat_messages
  add column if not exists session_id uuid references public.chat_sessions(id) on delete cascade;

create index if not exists chat_messages_session_created_idx
  on public.chat_messages (session_id, created_at);

-- Backfill: one "Allgemein" session per user with session_id-less messages,
-- and point all their old rows at it.
do $$
declare
  v_user record;
  v_session_id uuid;
begin
  for v_user in
    select distinct user_id
      from public.chat_messages
     where session_id is null
  loop
    insert into public.chat_sessions (user_id, title, last_message_at)
      values (v_user.user_id, 'Allgemein',
              coalesce((select max(created_at) from public.chat_messages
                         where user_id = v_user.user_id), now()))
      returning id into v_session_id;

    update public.chat_messages
       set session_id = v_session_id
     where user_id = v_user.user_id
       and session_id is null;
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- RPC: list_chat_sessions
-- ---------------------------------------------------------------------------
create or replace function public.list_chat_sessions()
returns table (
  id              uuid,
  title           text,
  created_at      timestamptz,
  last_message_at timestamptz,
  message_count   integer
)
language sql
security definer
set search_path = public
as $$
  select s.id, s.title, s.created_at, s.last_message_at,
         coalesce((select count(*)::integer from public.chat_messages m
                    where m.session_id = s.id and m.role in ('user','assistant')), 0)
    from public.chat_sessions s
   where s.user_id = auth.uid()
   order by s.last_message_at desc;
$$;

grant execute on function public.list_chat_sessions() to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- RPC: ensure_default_chat_session - always returns a session id, creating one
-- if needed. Called by the client on bootstrap and by the edge function as a
-- fallback.
-- ---------------------------------------------------------------------------
create or replace function public.ensure_default_chat_session(
  p_user_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := coalesce(p_user_id, auth.uid());
  v_id  uuid;
begin
  if v_uid is null then
    raise exception 'EX_USER_REQUIRED' using errcode = '22023';
  end if;

  select id into v_id
    from public.chat_sessions
   where user_id = v_uid
   order by last_message_at desc
   limit 1;

  if v_id is null then
    insert into public.chat_sessions (user_id, title)
      values (v_uid, 'Neue Unterhaltung')
      returning id into v_id;
  end if;

  return v_id;
end;
$$;

grant execute on function public.ensure_default_chat_session(uuid)
  to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- RPC: create_chat_session - always a fresh session.
-- ---------------------------------------------------------------------------
create or replace function public.create_chat_session(
  p_title text default 'Neue Unterhaltung'
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_id  uuid;
begin
  if v_uid is null then
    raise exception 'EX_USER_REQUIRED' using errcode = '22023';
  end if;

  insert into public.chat_sessions (user_id, title)
    values (v_uid, coalesce(nullif(trim(p_title), ''), 'Neue Unterhaltung'))
    returning id into v_id;

  return v_id;
end;
$$;

grant execute on function public.create_chat_session(text)
  to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- RPC: rename_chat_session
-- ---------------------------------------------------------------------------
create or replace function public.rename_chat_session(
  p_session_id uuid,
  p_title      text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'EX_USER_REQUIRED' using errcode = '22023';
  end if;

  update public.chat_sessions
     set title = coalesce(nullif(trim(p_title), ''), title),
         updated_at = now()
   where id = p_session_id
     and user_id = v_uid;
end;
$$;

grant execute on function public.rename_chat_session(uuid, text)
  to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- RPC: delete_chat_session (the FK cascades all messages away)
-- ---------------------------------------------------------------------------
create or replace function public.delete_chat_session(
  p_session_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'EX_USER_REQUIRED' using errcode = '22023';
  end if;

  delete from public.chat_sessions
   where id = p_session_id
     and user_id = v_uid;
end;
$$;

grant execute on function public.delete_chat_session(uuid)
  to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- RPC: touch_chat_session (the edge function resets last_message_at).
-- ---------------------------------------------------------------------------
create or replace function public.touch_chat_session(
  p_session_id uuid
)
returns void
language sql
security definer
set search_path = public
as $$
  update public.chat_sessions
     set last_message_at = now(),
         updated_at = now()
   where id = p_session_id;
$$;

grant execute on function public.touch_chat_session(uuid)
  to service_role;
