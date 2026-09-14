\set ON_ERROR_STOP on
begin;
set local role authenticated;
set local request.jwt.claims = '{"sub":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"}';
do $$
declare affected integer;
begin
  if current_user <> 'authenticated' then
    raise exception 'RESTORE_ROLE: restricted role required';
  end if;
  if (select count(*) from public.logged_meals) <> 1 then
    raise exception 'RESTORE_RLS: foreign rows visible';
  end if;
  if (select meal_name from public.logged_meals) <> 'Synthetic A' then
    raise exception 'RESTORE_DATA: own row missing';
  end if;
  update public.logged_meals set meal_name = 'Synthetic own edit'
    where user_id = auth.uid();
  get diagnostics affected = row_count;
  if affected <> 1 then
    raise exception 'RESTORE_GRANT: legitimate write rejected';
  end if;
  update public.logged_meals set meal_name = 'Forbidden'
    where user_id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
  get diagnostics affected = row_count;
  if affected <> 0 then
    raise exception 'RESTORE_RLS: foreign write succeeded';
  end if;
  begin
    insert into public.logged_meals
      (user_id, meal_name, calories_kcal, estimated_g, payload, local_day)
      values ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', 'Forbidden', 1, 1, '{}', '2026-01-01');
    raise exception 'RESTORE_RLS: foreign insert succeeded';
  exception when insufficient_privilege then null;
  end;
end $$;
set local role anon;
do $$
begin
  begin
    perform 1 from public.logged_meals;
    raise exception 'RESTORE_GRANT: anonymous read succeeded';
  exception when insufficient_privilege then null;
  end;
end $$;
rollback;
