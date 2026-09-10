-- Completed workouts are owned independently from their editable source plan.
-- Coach's v1 plan JSON stays unchanged; identity is adopted-plan metadata.
create or replace function public.is_valid_training_exercise_ids(plan jsonb, ids jsonb)
returns boolean language plpgsql immutable set search_path = pg_catalog as $$
declare w integer; e integer; identity text; seen text[] := '{}';
begin
  if ids is null then return true; end if;
  if jsonb_typeof(ids) is distinct from 'array'
     or jsonb_array_length(ids) <> jsonb_array_length(plan->'workouts') then return false; end if;
  for w in 0..jsonb_array_length(ids)-1 loop
    if jsonb_typeof(ids->w) is distinct from 'array'
       or jsonb_array_length(ids->w) <> jsonb_array_length(plan->'workouts'->w->'exercises') then return false; end if;
    for e in 0..jsonb_array_length(ids->w)-1 loop
      identity := ids->w->>e;
      if jsonb_typeof(ids->w->e) is distinct from 'string'
         or identity !~ '^[A-Za-z0-9_-]{1,100}$' or identity = any(seen) then return false; end if;
      seen := array_append(seen, identity);
    end loop;
  end loop;
  return true;
exception when others then return false;
end;
$$;

alter table public.training_plans add column if not exists exercise_ids jsonb;
alter table public.training_plans add constraint training_plans_exercise_ids_check
  check (public.is_valid_training_exercise_ids(plan, exercise_ids));

create or replace function public.is_valid_training_history(value jsonb, row_id uuid, ended timestamptz)
returns boolean language plpgsql immutable set search_path = pg_catalog set timezone = 'UTC' as $$
declare
  snap jsonb; source jsonb; workout jsonb; exercise jsonb; item jsonb; actual jsonb;
  w integer; e integer; s integer; total integer := 0; ref text;
  seen text[] := '{}'; completed text[] := '{}'; actual_seen text[] := '{}';
  started timestamptz; completed_at timestamptz; n numeric;
begin
  if jsonb_typeof(value) is distinct from 'object' or octet_length(value::text) > 196608
     or not (value ?& array['snapshot','note']) or value - array['snapshot','note'] <> '{}'
     or jsonb_typeof(value->'note') is distinct from 'string'
     or char_length(value->>'note') > 500
     or (value->>'note') ~ U&'[\0001-\0008\000B\000C\000E-\001F]' then return false; end if;
  snap := value->'snapshot'; source := snap->'plan';
  if jsonb_typeof(snap) is distinct from 'object'
     or not (snap ?& array['schema_version','status','session_id','started_at','plan','workout_index','exercise_index','set_index','phase','remaining_milliseconds','completed_sets','skipped_sets','actual_sets','draft_reps','draft_weight_kg'])
     or snap - array['schema_version','status','session_id','started_at','plan','workout_index','exercise_index','set_index','phase','remaining_milliseconds','completed_sets','skipped_sets','actual_sets','draft_reps','draft_weight_kg'] <> '{}'
     or snap->'schema_version' <> '2' or snap->>'status' is distinct from 'paused' or snap->>'phase' is distinct from 'review'
     or snap->>'session_id' is distinct from row_id::text or snap->'remaining_milliseconds' <> '0'
     or snap->'draft_reps' <> 'null' or snap->'draft_weight_kg' <> 'null'
     or jsonb_typeof(source) is distinct from 'object'
     or not (source ?& array['id','plan','exercise_ids']) or source - array['id','plan','exercise_ids'] <> '{}'
     or jsonb_typeof(source->'id') is distinct from 'string'
     or source->>'id' !~ '^[A-Za-z0-9_-]{1,100}$'
     or not public.is_valid_training_plan(source->'plan')
     or source->'exercise_ids' = 'null'
     or not public.is_valid_training_exercise_ids(source->'plan', source->'exercise_ids') then return false; end if;
  if jsonb_typeof(snap->'started_at') is distinct from 'string' or snap->>'started_at' !~ 'Z$'
     or not isfinite(ended) then return false; end if;
  started := (snap->>'started_at')::timestamptz;
  if not isfinite(started) or started < '2000-01-01Z'::timestamptz
     or ended >= '2201-01-01Z'::timestamptz or ended < started then return false; end if;
  foreach ref in array array['workout_index','exercise_index','set_index'] loop
    if jsonb_typeof(snap->ref) is distinct from 'number' then return false; end if;
    n := (snap->>ref)::numeric;
    if n < 0 or n > 200 or n <> trunc(n) then return false; end if;
  end loop;
  w := (snap->>'workout_index')::integer;
  if w >= jsonb_array_length(source->'plan'->'workouts') then return false; end if;
  workout := source->'plan'->'workouts'->w;
  e := jsonb_array_length(workout->'exercises') - 1;
  if (snap->>'exercise_index')::integer <> e
     or (snap->>'set_index')::integer <> (workout->'exercises'->e->>'sets')::integer - 1 then return false; end if;
  for exercise in select * from jsonb_array_elements(workout->'exercises') loop
    total := total + (exercise->>'sets')::integer;
  end loop;
  if jsonb_typeof(snap->'completed_sets') is distinct from 'array'
     or jsonb_typeof(snap->'skipped_sets') is distinct from 'array'
     or jsonb_typeof(snap->'actual_sets') is distinct from 'array'
     or jsonb_array_length(snap->'completed_sets') + jsonb_array_length(snap->'skipped_sets') <> total
     or jsonb_array_length(snap->'actual_sets') <> jsonb_array_length(snap->'completed_sets') then return false; end if;
  for item in select * from jsonb_array_elements((snap->'completed_sets') || (snap->'skipped_sets')) loop
    if jsonb_typeof(item) is distinct from 'object' or not (item ?& array['exercise_index','set_index'])
       or item - array['exercise_index','set_index'] <> '{}' then return false; end if;
    foreach ref in array array['exercise_index','set_index'] loop
      if jsonb_typeof(item->ref) is distinct from 'number' then return false; end if;
      n := (item->>ref)::numeric;
      if n < 0 or n > 200 or n <> trunc(n) then return false; end if;
    end loop;
    e := (item->>'exercise_index')::integer; s := (item->>'set_index')::integer;
    if e >= jsonb_array_length(workout->'exercises') or s >= (workout->'exercises'->e->>'sets')::integer then return false; end if;
    ref := e::text || ':' || s::text;
    if ref = any(seen) then return false; end if;
    seen := array_append(seen, ref);
    if cardinality(seen) <= jsonb_array_length(snap->'completed_sets') then completed := array_append(completed, ref); end if;
  end loop;
  for actual in select * from jsonb_array_elements(snap->'actual_sets') loop
    if jsonb_typeof(actual) is distinct from 'object'
       or not (actual ?& array['exercise_index','set_index','reps','weight_kg','completed_at'])
       or actual - array['exercise_index','set_index','reps','weight_kg','completed_at'] <> '{}' then return false; end if;
    foreach ref in array array['exercise_index','set_index'] loop
      if jsonb_typeof(actual->ref) is distinct from 'number' then return false; end if;
      n := (actual->>ref)::numeric;
      if n < 0 or n > 200 or n <> trunc(n) then return false; end if;
    end loop;
    e := (actual->>'exercise_index')::integer; s := (actual->>'set_index')::integer;
    ref := e::text || ':' || s::text;
    if not ref = any(completed) or ref = any(actual_seen) then return false; end if;
    actual_seen := array_append(actual_seen, ref);
    exercise := workout->'exercises'->e;
    if exercise->'reps' = 'null' then
      if actual->'reps' <> 'null' then return false; end if;
    else
      if jsonb_typeof(actual->'reps') is distinct from 'number' then return false; end if;
      n := (actual->>'reps')::numeric;
      if n not between 0 and 1000 or n <> trunc(n) then return false; end if;
    end if;
    if actual->'weight_kg' <> 'null' then
      if jsonb_typeof(actual->'weight_kg') is distinct from 'number' then return false; end if;
      n := (actual->>'weight_kg')::numeric;
      if n not between 0 and 2000 then return false; end if;
    end if;
    if jsonb_typeof(actual->'completed_at') is distinct from 'string' or actual->>'completed_at' !~ 'Z$' then return false; end if;
    completed_at := (actual->>'completed_at')::timestamptz;
    if not isfinite(completed_at) or completed_at < started or completed_at > ended then return false; end if;
  end loop;
  return true;
exception when others then return false;
end;
$$;

revoke execute on function public.is_valid_training_exercise_ids(jsonb,jsonb) from public, anon, authenticated;
revoke execute on function public.is_valid_training_history(jsonb,uuid,timestamptz) from public, anon, authenticated;
grant execute on function public.is_valid_training_exercise_ids(jsonb,jsonb) to authenticated, service_role;
grant execute on function public.is_valid_training_history(jsonb,uuid,timestamptz) to authenticated, service_role;

create table public.training_history (
  user_id uuid not null references auth.users(id) on delete cascade,
  id uuid not null,
  finished_at timestamptz not null,
  session jsonb not null,
  primary key (user_id, id),
  constraint training_history_session_check check (public.is_valid_training_history(session, id, finished_at))
);
create index training_history_user_finished_idx on public.training_history (user_id, finished_at desc, id);
create trigger training_history_row_cap before insert on public.training_history
  for each row execute function public.enforce_user_row_cap('user_id', '2000', 'id');
alter table public.training_history enable row level security;
create policy training_history_select_own on public.training_history for select to authenticated using (user_id = (select auth.uid()));
create policy training_history_insert_own on public.training_history for insert to authenticated with check (user_id = (select auth.uid()));
create policy training_history_delete_own on public.training_history for delete to authenticated using (user_id = (select auth.uid()));
-- No UPDATE grant: retries INSERT ... ON CONFLICT DO NOTHING preserve history.
revoke all on public.training_history from public, anon, authenticated;
grant select, insert, delete on public.training_history to authenticated;
grant all on public.training_history to service_role;
