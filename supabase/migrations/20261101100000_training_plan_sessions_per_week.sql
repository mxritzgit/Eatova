-- Optional weekly target on a training plan: `sessions_per_week`, an integer
-- 1..14. Additive: every v1 plan without the key stays valid, schema_version
-- stays 1, and the CHECKs on training_plans, chat_messages and the history
-- snapshot reuse this function unchanged. Apply before coach-chat sends the
-- key and before an app build writes it; builds before 2026-11 cannot read it.

create or replace function public.is_valid_training_plan(p_plan jsonb)
returns boolean
language plpgsql
immutable
set search_path = pg_catalog
as $$
declare
  workout jsonb;
  exercise jsonb;
  field text;
  number_value numeric;
  texts text[] := array[]::text[];
  limits integer[] := array[]::integer[];
  nonblank boolean[] := array[]::boolean[];
  i integer;
  total_characters integer := 0;
  -- Union of Unicode White_Space and the BOM, matching the app validators.
  whitespace constant text := U&'\0009\000A\000B\000C\000D\0020\0085\00A0\1680\2000\2001\2002\2003\2004\2005\2006\2007\2008\2009\200A\2028\2029\202F\205F\3000\FEFF';
begin
  -- Measure the uncompressed value. pg_column_size can conceal TOAST size.
  if jsonb_typeof(p_plan) is distinct from 'object'
     or octet_length(p_plan::text) > 131072 then
    return false;
  end if;
  if not (p_plan ?& array['schema_version', 'title', 'description', 'goal', 'workouts'])
     or p_plan - array['schema_version', 'title', 'description', 'goal', 'workouts', 'sessions_per_week'] <> '{}'::jsonb
     or p_plan -> 'schema_version' <> '1'::jsonb then
    return false;
  end if;
  -- Absent means no target; JSON null is not a second spelling of absent.
  if p_plan ? 'sessions_per_week' then
    if jsonb_typeof(p_plan -> 'sessions_per_week') is distinct from 'number' then
      return false;
    end if;
    number_value := (p_plan ->> 'sessions_per_week')::numeric;
    if number_value <> trunc(number_value) or number_value not between 1 and 14 then
      return false;
    end if;
  end if;
  foreach field in array array['title', 'description', 'goal'] loop
    if jsonb_typeof(p_plan -> field) is distinct from 'string' then
      return false;
    end if;
    texts := array_append(texts, p_plan ->> field);
  end loop;
  limits := array[120, 1000, 200];
  nonblank := array[true, false, false];
  if jsonb_typeof(p_plan -> 'workouts') is distinct from 'array' then
    return false;
  end if;
  if jsonb_array_length(p_plan -> 'workouts') not between 1 and 7 then
    return false;
  end if;

  for workout in select value from jsonb_array_elements(p_plan -> 'workouts') loop
    if jsonb_typeof(workout) is distinct from 'object' then
      return false;
    end if;
    if not (workout ?& array['title', 'description', 'exercises'])
       or workout - array['title', 'description', 'exercises'] <> '{}'::jsonb then
      return false;
    end if;
    foreach field in array array['title', 'description'] loop
      if jsonb_typeof(workout -> field) is distinct from 'string' then
        return false;
      end if;
      texts := array_append(texts, workout ->> field);
    end loop;
    limits := limits || array[120, 500];
    nonblank := nonblank || array[true, false];
    if jsonb_typeof(workout -> 'exercises') is distinct from 'array' then
      return false;
    end if;
    if jsonb_array_length(workout -> 'exercises') not between 1 and 20 then
      return false;
    end if;

    for exercise in select value from jsonb_array_elements(workout -> 'exercises') loop
      if jsonb_typeof(exercise) is distinct from 'object' then
        return false;
      end if;
      if not (exercise ?& array['name', 'sets', 'reps', 'duration_seconds', 'rest_seconds', 'notes'])
         or exercise - array['name', 'sets', 'reps', 'duration_seconds', 'rest_seconds', 'notes'] <> '{}'::jsonb then
        return false;
      end if;
      foreach field in array array['name', 'notes'] loop
        if jsonb_typeof(exercise -> field) is distinct from 'string' then
          return false;
        end if;
        texts := array_append(texts, exercise ->> field);
      end loop;
      limits := limits || array[120, 500];
      nonblank := nonblank || array[true, false];

      -- JSON null is explicit; absent keys were rejected above.
      if (exercise -> 'reps' = 'null'::jsonb) =
         (exercise -> 'duration_seconds' = 'null'::jsonb) then
        return false;
      end if;
      foreach field in array array['sets', 'reps', 'duration_seconds', 'rest_seconds'] loop
        if field in ('reps', 'duration_seconds') and exercise -> field = 'null'::jsonb then
          continue;
        end if;
        if jsonb_typeof(exercise -> field) is distinct from 'number' then
          return false;
        end if;
        number_value := (exercise ->> field)::numeric;
        if number_value <> trunc(number_value)
           or (field = 'sets' and number_value not between 1 and 10)
           or (field = 'reps' and number_value not between 1 and 100)
           or (field = 'duration_seconds' and number_value not between 5 and 3600)
           or (field = 'rest_seconds' and number_value not between 0 and 600) then
          return false;
        end if;
      end loop;
    end loop;
  end loop;

  for i in 1..cardinality(texts) loop
    if char_length(texts[i]) > limits[i]
       or (nonblank[i] and btrim(texts[i], whitespace) = '')
       or texts[i] ~ U&'[\0001-\0008\000B\000C\000E-\001F]' then
      return false;
    end if;
    total_characters := total_characters + char_length(texts[i]);
    if total_characters > 12000 then
      return false;
    end if;
  end loop;
  return true;
end;
$$;

-- `create or replace` keeps the ACL; restated so the grant is visible here.
revoke execute on function public.is_valid_training_plan(jsonb)
  from public, anon, authenticated;
grant execute on function public.is_valid_training_plan(jsonb)
  to authenticated, service_role;
