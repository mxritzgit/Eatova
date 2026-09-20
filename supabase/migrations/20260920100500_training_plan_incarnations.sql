-- A coach proposal keeps its stable identity; explicit re-adoption creates a
-- new generation. Old operations can never address that new generation.
alter table public.training_plans add column source_id text;
alter table public.training_plans add column incarnation bigint not null default 0;
alter table public.training_plans add constraint training_plans_source_check check (
  incarnation between 0 and 2147483647 and
  ((source_id is null and incarnation=0) or
   (source_id is not null and source_id ~ '^[A-Za-z0-9_-]{1,94}$' and id='coach_'||source_id))
);

create table public.training_plan_heads (
  user_id uuid not null references auth.users(id) on delete cascade,
  source_id text not null check(source_id ~ '^[A-Za-z0-9_-]{1,94}$'),
  plan_id text not null check(plan_id='coach_'||source_id),
  incarnation bigint not null check(incarnation between 0 and 2147483647),
  deleted boolean not null,
  primary key(user_id,source_id),
  unique(user_id,plan_id)
);
alter table public.training_plan_heads enable row level security;
revoke all on public.training_plan_heads from public,anon,authenticated;
grant all on public.training_plan_heads to service_role;
alter table public.recipe_sync_heads add column training_head_count integer not null default 0
  check(training_head_count between 0 and 100000);

update public.training_plans set source_id=substring(id from 7)
where id ~ '^coach_[A-Za-z0-9_-]{1,94}$';
insert into public.training_plan_heads(user_id,source_id,plan_id,incarnation,deleted)
select user_id,source_id,id,0,false from public.training_plans where source_id is not null;
insert into public.training_plan_heads(user_id,source_id,plan_id,incarnation,deleted)
select user_id,substring(entity_id from 7),entity_id,0,true
from public.sync_entity_deletions where family='training_plan' and entity_id ~ '^coach_[A-Za-z0-9_-]{1,94}$'
on conflict(user_id,source_id) do nothing;
insert into public.recipe_sync_heads(user_id,training_head_count)
select user_id,count(*)::integer from public.training_plan_heads group by user_id
on conflict(user_id) do update set training_head_count=excluded.training_head_count;

create or replace function public.training_incarnation(p_value jsonb)
returns bigint language plpgsql immutable set search_path=pg_catalog as $$
begin
  if p_value is null then return 0; end if;
  if jsonb_typeof(p_value)<>'number' or p_value::text !~ '^[0-9]{1,10}$' or p_value::text::numeric>2147483647 then
    raise exception 'EX_INVALID_TRAINING_INCARNATION' using errcode='22023';
  end if;
  return p_value::text::bigint;
end;
$$;
revoke all on function public.training_incarnation(jsonb) from public,anon,authenticated;
grant execute on function public.training_incarnation(jsonb) to service_role;

create or replace function public.create_training_plan_head(p_user uuid,p_source text,p_id text,p_incarnation bigint,p_deleted boolean)
returns void language plpgsql security definer set search_path=pg_catalog as $$
begin
  perform pg_advisory_xact_lock(hashtextextended('sync:'||p_user::text,0));
  if exists(select 1 from public.training_plan_heads where user_id=p_user and source_id=p_source) then return; end if;
  insert into public.recipe_sync_heads(user_id) values(p_user) on conflict do nothing;
  update public.recipe_sync_heads set training_head_count=training_head_count+1
  where user_id=p_user and training_head_count<100000;
  if not found then raise exception 'EX_TRAINING_HEAD_CAPACITY' using errcode='PT507'; end if;
  insert into public.training_plan_heads(user_id,source_id,plan_id,incarnation,deleted)
  values(p_user,p_source,p_id,p_incarnation,p_deleted);
end;
$$;
revoke all on function public.create_training_plan_head(uuid,text,text,bigint,boolean) from public,anon,authenticated;
grant execute on function public.create_training_plan_head(uuid,text,text,bigint,boolean) to service_role;

-- Legacy writes are generation zero. An in-progress, privately stored receipt
-- proves a versioned RPC; a client-set GUC alone is never sufficient.
create or replace function public.guard_training_plan_incarnation()
returns trigger language plpgsql security definer set search_path=pg_catalog as $$
declare u uuid; src text; h public.training_plan_heads%rowtype; pending text; versioned boolean:=false;
begin
  u:=case when tg_op='DELETE' then old.user_id else new.user_id end;
  if tg_op='DELETE' and not exists(select 1 from auth.users where id=u) then return old; end if;
  if auth.uid() is not null and auth.uid()<>u then raise exception 'EX_OWNER_REQUIRED' using errcode='42501'; end if;
  perform pg_advisory_xact_lock(hashtextextended('sync:'||u::text,0));
  pending:=current_setting('eatova.sync_operation',true);
  if pending ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then
    versioned:=exists(select 1 from public.sync_operation_receipts
      where user_id=u and operation_id=pending::uuid and response is null);
  end if;
  if tg_op='DELETE' then
    if old.incarnation>0 and not versioned then
      raise exception 'EX_TRAINING_PROTOCOL_REQUIRED' using errcode='22023';
    end if;
    update public.training_plan_heads set deleted=true
      where user_id=u and plan_id=old.id and incarnation=old.incarnation;
    -- Coach heads and receipted effects bound retained identities. Legacy
    -- manual plans retain their previous direct-write policy without a journal.
    if versioned or old.source_id is not null then
      insert into public.sync_entity_deletions(user_id,family,entity_id)
        values(u,'training_plan',old.id) on conflict do nothing;
    end if;
    return old;
  end if;
  if tg_op='UPDATE' and (new.user_id<>old.user_id or new.id<>old.id or new.incarnation<>old.incarnation) then
    raise exception 'EX_TRAINING_IDENTITY_IMMUTABLE' using errcode='22023';
  end if;
  src:=coalesce(new.source_id,case when new.id ~ '^coach_[A-Za-z0-9_-]{1,94}$' then substring(new.id from 7) end);
  if tg_op='UPDATE' and src is distinct from old.source_id then
    raise exception 'EX_TRAINING_SOURCE_IMMUTABLE' using errcode='22023';
  end if;
  new.source_id:=src;
  if new.incarnation>0 and not versioned then
    raise exception 'EX_TRAINING_PROTOCOL_REQUIRED' using errcode='22023';
  end if;
  if src is null then
    if exists(select 1 from public.sync_entity_deletions where user_id=u and family='training_plan' and entity_id=new.id) then
      raise exception 'EX_TRAINING_SOURCE_CHANGED' using errcode='22023';
    end if;
    return new;
  end if;
  if src !~ '^[A-Za-z0-9_-]{1,94}$' or new.id<>'coach_'||src then
    raise exception 'EX_INVALID_TRAINING_SOURCE' using errcode='22023';
  end if;
  select * into h from public.training_plan_heads where user_id=u and source_id=src;
  if not found then
    if new.incarnation<>0 then raise exception 'EX_TRAINING_SOURCE_CHANGED' using errcode='22023'; end if;
    perform public.create_training_plan_head(u,src,new.id,0,false);
  elsif new.incarnation=h.incarnation and not h.deleted then
    null;
  elsif versioned and h.deleted and new.incarnation=h.incarnation+1 then
    update public.training_plan_heads set incarnation=new.incarnation,deleted=false where user_id=u and source_id=src;
  else
    raise exception 'EX_TRAINING_SOURCE_CHANGED' using errcode='22023';
  end if;
  return new;
end;
$$;
revoke all on function public.guard_training_plan_incarnation() from public,anon,authenticated;
grant execute on function public.guard_training_plan_incarnation() to service_role;
create trigger training_plans_incarnation_guard before insert or update or delete on public.training_plans
for each row execute function public.guard_training_plan_incarnation();

create or replace function public.training_plan_head_json(p_user uuid,p_id text)
returns jsonb language sql stable security definer set search_path=pg_catalog as $$
  select jsonb_build_object('source_id',h.source_id,'plan_id',h.plan_id,'incarnation',h.incarnation,'deleted',h.deleted,
    'plan',(select jsonb_build_object('id',p.id,'source_id',p.source_id,'incarnation',p.incarnation,
      'plan',p.plan,'exercise_ids',p.exercise_ids) from public.training_plans p
      where p.user_id=h.user_id and p.id=h.plan_id and p.incarnation=h.incarnation and not h.deleted))
  from public.training_plan_heads h where h.user_id=p_user and h.plan_id=p_id;
$$;
revoke all on function public.training_plan_head_json(uuid,text) from public,anon,authenticated;
grant execute on function public.training_plan_head_json(uuid,text) to service_role;

create or replace function public.load_training_plan_head(p_source_id text)
returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare u uuid:=auth.uid();
begin
  if u is null then raise exception 'EX_USER_REQUIRED' using errcode='42501'; end if;
  if p_source_id is null or p_source_id !~ '^[A-Za-z0-9_-]{1,94}$' then
    raise exception 'EX_INVALID_TRAINING_SOURCE' using errcode='22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('sync:'||u::text,0));
  return public.training_plan_head_json(u,'coach_'||p_source_id);
end;
$$;
revoke all on function public.load_training_plan_head(text) from public,anon,authenticated;
grant execute on function public.load_training_plan_head(text) to authenticated,service_role;

create or replace function public.apply_training_plan_mutation(p_kind text,p_id text,p_payload jsonb)
returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare u uuid:=auth.uid(); h public.training_plan_heads%rowtype; row_data jsonb; src text;
  generation bigint; adoption boolean:=false; outcome text:='applied';
begin
  if u is null then raise exception 'EX_USER_REQUIRED' using errcode='42501'; end if;
  if p_id !~ '^[A-Za-z0-9_-]{1,100}$' then raise exception 'EX_INVALID_TRAINING_ID' using errcode='22023'; end if;
  perform pg_advisory_xact_lock(hashtextextended('sync:'||u::text,0));
  if p_kind='trainingPlanUpsert' then
    row_data:=p_payload->'row';
    if jsonb_typeof(row_data) is distinct from 'object' or row_data->>'id' is distinct from p_id then
      raise exception 'EX_INVALID_TRAINING_ID' using errcode='22023';
    end if;
    generation:=public.training_incarnation(row_data->'incarnation');
    if p_payload ? 'adoption' and jsonb_typeof(p_payload->'adoption')<>'boolean' then
      raise exception 'EX_INVALID_TRAINING_ADOPTION' using errcode='22023';
    end if;
    adoption:=coalesce((p_payload->>'adoption')::boolean,false);
    src:=coalesce(row_data->>'source_id',case when p_id ~ '^coach_[A-Za-z0-9_-]{1,94}$' then substring(p_id from 7) end);
    if src is not null and (src !~ '^[A-Za-z0-9_-]{1,94}$' or p_id<>'coach_'||src) then
      raise exception 'EX_INVALID_TRAINING_SOURCE' using errcode='22023';
    end if;
    if src is null and (generation<>0 or adoption) then raise exception 'EX_INVALID_TRAINING_SOURCE' using errcode='22023'; end if;
    select * into h from public.training_plan_heads where user_id=u and plan_id=p_id;
    if (h.plan_id is not null and (generation<h.incarnation or (generation=h.incarnation and h.deleted)))
        or (h.plan_id is null and exists(select 1 from public.sync_entity_deletions where user_id=u and family='training_plan' and entity_id=p_id)) then
      outcome:=case when adoption then 'headConflict' else 'deleted' end;
    elsif (h.plan_id is null and generation<>0) or
        (h.plan_id is not null and generation>h.incarnation and
          (not adoption or not h.deleted or generation<>h.incarnation+1)) then
      outcome:='headConflict';
    else
      insert into public.training_plans(user_id,id,plan,exercise_ids,source_id,incarnation)
      values(u,p_id,row_data->'plan',row_data->'exercise_ids',src,generation)
      on conflict(user_id,id) do update set plan=excluded.plan,exercise_ids=excluded.exercise_ids,
        source_id=excluded.source_id,incarnation=excluded.incarnation;
    end if;
  elsif p_kind='trainingPlanDelete' then
    generation:=public.training_incarnation(p_payload->'incarnation');
    src:=case when p_id ~ '^coach_[A-Za-z0-9_-]{1,94}$' then substring(p_id from 7) end;
    select * into h from public.training_plan_heads where user_id=u and plan_id=p_id;
    if h.plan_id is null then
      if generation<>0 then raise exception 'EX_TRAINING_SOURCE_CHANGED' using errcode='22023'; end if;
      if src is not null then perform public.create_training_plan_head(u,src,p_id,0,true); end if;
    elsif generation>h.incarnation then
      if generation<>h.incarnation+1 or not h.deleted then raise exception 'EX_TRAINING_SOURCE_CHANGED' using errcode='22023'; end if;
      update public.training_plan_heads set incarnation=generation,deleted=true where user_id=u and plan_id=p_id;
    end if;
    delete from public.training_plans where user_id=u and id=p_id and incarnation=generation;
    insert into public.sync_entity_deletions(user_id,family,entity_id) values(u,'training_plan',p_id) on conflict do nothing;
    outcome:='deleted';
  else
    raise exception 'EX_INVALID_TRAINING_OPERATION' using errcode='22023';
  end if;
  return jsonb_build_object('training_mutation',jsonb_build_object('outcome',outcome,'incarnation',generation),
    'entity_deleted',not exists(select 1 from public.training_plans where user_id=u and id=p_id and incarnation=generation));
end;
$$;
revoke all on function public.apply_training_plan_mutation(text,text,jsonb) from public,anon,authenticated;
grant execute on function public.apply_training_plan_mutation(text,text,jsonb) to service_role;

-- Completed sessions retain the generation that was actually trained.
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
     or not (source ?& array['id','plan','exercise_ids']) or source - array['id','plan','exercise_ids','source_id','incarnation'] <> '{}'
     or jsonb_typeof(source->'id') is distinct from 'string'
     or source->>'id' !~ '^[A-Za-z0-9_-]{1,100}$'
     or not public.is_valid_training_plan(source->'plan')
     or source->'exercise_ids' = 'null'
     or not public.is_valid_training_exercise_ids(source->'plan', source->'exercise_ids') then return false; end if;
  if source ? 'source_id' and source->'source_id'<>'null' and
    (jsonb_typeof(source->'source_id') is distinct from 'string' or
     source->>'source_id' !~ '^[A-Za-z0-9_-]{1,94}$' or source->>'id'<>'coach_'||(source->>'source_id')) then return false; end if;
  if source ? 'incarnation' then
    if jsonb_typeof(source->'incarnation') is distinct from 'number' or
      (source->'incarnation')::text !~ '^[0-9]{1,10}$' or
      (source->>'incarnation')::numeric>2147483647 or
      ((source->>'incarnation')::numeric>0 and source->>'id' !~ '^coach_[A-Za-z0-9_-]{1,94}$') then return false; end if;
  end if;
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
