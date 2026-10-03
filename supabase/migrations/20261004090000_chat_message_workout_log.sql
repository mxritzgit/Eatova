-- Coach /log: a finished workout extracted from the user's words is stored on
-- the assistant message as a proposal (wire/stored schema v1, spec C3). Only
-- the client's explicit confirmation writes training_history. Apply BEFORE the
-- coach-chat deployment that writes this column.
--
-- Mirrors supabase/functions/coach-chat/workout_log.ts parseWorkoutLog. It
-- checks FORMAT only: no clock, so the performed_on window stays with the edge
-- function and the client. Shared cases:
-- supabase/functions/coach-chat/fixtures/workout_log_cases.json.

create or replace function public.is_valid_coach_workout_log(p_log jsonb)
returns boolean
language plpgsql
immutable
set search_path = pg_catalog
as $$
declare
  exercise jsonb;
  set_value jsonb;
  timed boolean;
  duration numeric;
  number_value numeric;
  date_text text;
  date_year integer;
  date_month integer;
  date_day integer;
  month_days integer;
  texts text[] := array[]::text[];
  limits integer[] := array[]::integer[];
  nonblank boolean[] := array[]::boolean[];
  i integer;
  total_characters integer := 0;
  -- Union of Unicode White_Space and the BOM, matching the app validators.
  whitespace constant text := U&'\0009\000A\000B\000C\000D\0020\0085\00A0\1680\2000\2001\2002\2003\2004\2005\2006\2007\2008\2009\200A\2028\2029\202F\205F\3000\FEFF';
begin
  -- Measure the uncompressed value. pg_column_size can conceal TOAST size.
  if jsonb_typeof(p_log) is distinct from 'object'
     or octet_length(p_log::text) > 32768 then
    return false;
  end if;
  if not (p_log ?& array['schema_version', 'title', 'performed_on', 'duration_minutes',
                         'other_days_omitted', 'note', 'exercises'])
     or p_log - array['schema_version', 'title', 'performed_on', 'duration_minutes',
                      'other_days_omitted', 'note', 'exercises'] <> '{}'::jsonb
     or p_log -> 'schema_version' <> '1'::jsonb then
    return false;
  end if;
  if jsonb_typeof(p_log -> 'title') is distinct from 'string'
     or jsonb_typeof(p_log -> 'note') is distinct from 'string' then
    return false;
  end if;
  texts := array[p_log ->> 'title', p_log ->> 'note'];
  limits := array[120, 500];
  nonblank := array[true, false];

  -- A real 'YYYY-MM-DD' calendar day, computed without date functions so a
  -- malformed day returns false instead of raising.
  if p_log -> 'performed_on' <> 'null'::jsonb then
    if jsonb_typeof(p_log -> 'performed_on') is distinct from 'string' then
      return false;
    end if;
    date_text := p_log ->> 'performed_on';
    if date_text !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
      return false;
    end if;
    date_year := substr(date_text, 1, 4)::integer;
    date_month := substr(date_text, 6, 2)::integer;
    date_day := substr(date_text, 9, 2)::integer;
    month_days := case
      when date_month = 2 then
        case when (date_year % 4 = 0 and date_year % 100 <> 0) or date_year % 400 = 0
          then 29 else 28 end
      when date_month in (4, 6, 9, 11) then 30
      else 31
    end;
    if date_month not between 1 and 12 or date_day not between 1 and month_days then
      return false;
    end if;
  end if;

  if p_log -> 'duration_minutes' <> 'null'::jsonb then
    if jsonb_typeof(p_log -> 'duration_minutes') is distinct from 'number' then
      return false;
    end if;
    number_value := (p_log ->> 'duration_minutes')::numeric;
    if number_value <> trunc(number_value) or number_value not between 1 and 600 then
      return false;
    end if;
  end if;
  if jsonb_typeof(p_log -> 'other_days_omitted') is distinct from 'boolean' then
    return false;
  end if;
  if jsonb_typeof(p_log -> 'exercises') is distinct from 'array' then
    return false;
  end if;
  if jsonb_array_length(p_log -> 'exercises') not between 1 and 20 then
    return false;
  end if;

  for exercise in select value from jsonb_array_elements(p_log -> 'exercises') loop
    if jsonb_typeof(exercise) is distinct from 'object' then
      return false;
    end if;
    if not (exercise ?& array['name', 'kind', 'duration_seconds', 'sets'])
       or exercise - array['name', 'kind', 'duration_seconds', 'sets'] <> '{}'::jsonb then
      return false;
    end if;
    if jsonb_typeof(exercise -> 'name') is distinct from 'string' then
      return false;
    end if;
    texts := array_append(texts, exercise ->> 'name');
    limits := array_append(limits, 120);
    nonblank := array_append(nonblank, true);
    if exercise -> 'kind' not in ('"reps"'::jsonb, '"timed"'::jsonb) then
      return false;
    end if;
    timed := exercise -> 'kind' = '"timed"'::jsonb;

    -- Reps exercises carry no duration; a timed one may leave it unsaid.
    duration := null;
    if exercise -> 'duration_seconds' <> 'null'::jsonb then
      if not timed or jsonb_typeof(exercise -> 'duration_seconds') is distinct from 'number' then
        return false;
      end if;
      duration := (exercise ->> 'duration_seconds')::numeric;
      if duration <> trunc(duration) or duration not between 5 and 36000 then
        return false;
      end if;
    end if;
    if jsonb_typeof(exercise -> 'sets') is distinct from 'array' then
      return false;
    end if;
    if jsonb_array_length(exercise -> 'sets') not between 1 and 10 then
      return false;
    end if;
    -- The client stores a timed set as ceil(d / 3600) history rows of at most
    -- one hour each; one exercise may produce at most ten.
    if duration is not null
       and jsonb_array_length(exercise -> 'sets') * ceil(duration / 3600) > 10 then
      return false;
    end if;

    for set_value in select value from jsonb_array_elements(exercise -> 'sets') loop
      if jsonb_typeof(set_value) is distinct from 'object' then
        return false;
      end if;
      if not (set_value ?& array['reps', 'weight_kg'])
         or set_value - array['reps', 'weight_kg'] <> '{}'::jsonb then
        return false;
      end if;
      if set_value -> 'reps' <> 'null'::jsonb then
        if timed or jsonb_typeof(set_value -> 'reps') is distinct from 'number' then
          return false;
        end if;
        number_value := (set_value ->> 'reps')::numeric;
        if number_value <> trunc(number_value) or number_value not between 0 and 1000 then
          return false;
        end if;
      end if;
      if set_value -> 'weight_kg' <> 'null'::jsonb then
        if jsonb_typeof(set_value -> 'weight_kg') is distinct from 'number' then
          return false;
        end if;
        number_value := (set_value ->> 'weight_kg')::numeric;
        if number_value <> round(number_value, 2) or number_value not between 0 and 2000 then
          return false;
        end if;
      end if;
    end loop;
  end loop;

  -- Code points, nonblank where required, no C0 except tab, LF and CR. JSONB
  -- cannot hold NUL or lone surrogates at all.
  for i in 1..cardinality(texts) loop
    if char_length(texts[i]) > limits[i]
       or (nonblank[i] and btrim(texts[i], whitespace) = '')
       or texts[i] ~ U&'[\0001-\0008\000B\000C\000E-\001F]' then
      return false;
    end if;
    total_characters := total_characters + char_length(texts[i]);
    if total_characters > 6000 then
      return false;
    end if;
  end loop;
  return true;
end;
$$;

-- Pure invoker validation reads no tables, granted like is_valid_training_plan.
revoke execute on function public.is_valid_coach_workout_log(jsonb)
  from public, anon, authenticated;
grant execute on function public.is_valid_coach_workout_log(jsonb)
  to authenticated, service_role;

-- No new chat grants or policies: only the edge function (service_role)
-- writes chat_messages. Old writers omit this nullable column and stay valid.
-- A row carries at most one proposal kind, never on a user row or a refusal.
alter table public.chat_messages add column if not exists workout_log jsonb;
alter table public.chat_messages drop constraint if exists chat_messages_workout_log_check;
alter table public.chat_messages add constraint chat_messages_workout_log_check
  check (workout_log is null or (
    role = 'assistant' and not refusal and recipe is null and training_plan is null
    and public.is_valid_coach_workout_log(workout_log)
  ));
