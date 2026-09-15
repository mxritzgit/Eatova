-- Run only against the disposable database, after all migrations.
begin;

-- A future owner-rights RPC must require an explicit grant even if its author
-- omits a REVOKE. This also exercises execution, not just ACL text parsing.
create function public.audit_default_execute_probe()
returns integer language sql security definer set search_path = pg_catalog
as $$ select 7 $$;

set local role anon;
do $$
begin
  begin
    perform public.audit_default_execute_probe();
    raise exception 'Anonymous caller executed an ungranted future RPC';
  exception when insufficient_privilege then null;
  end;
end;
$$;

reset role;
set local role authenticated;
do $$
begin
  begin
    perform public.audit_default_execute_probe();
    raise exception 'Authenticated caller executed an ungranted future RPC';
  exception when insufficient_privilege then null;
  end;
end;
$$;

reset role;
grant execute on function public.audit_default_execute_probe() to authenticated;
set local role authenticated;
do $$
begin
  if public.audit_default_execute_probe() <> 7 then
    raise exception 'Explicitly granted RPC stopped working';
  end if;
end;
$$;

reset role;
do $$
declare
  exposed boolean;
begin
  if current_setting('server_version_num')::integer >= 170000 then
    execute $query$
      select exists (
        select 1 from pg_class c
        join pg_namespace n on n.oid = c.relnamespace
        cross join (values ('anon'), ('authenticated')) r(name)
        where n.nspname = 'public' and c.relkind in ('r', 'p', 'm')
          and has_table_privilege(r.name, c.oid, 'MAINTAIN')
      )
    $query$ into exposed;
    if exposed then
      raise exception 'Client role retains table maintenance privileges';
    end if;
  end if;
  raise notice 'Database privilege boundaries: explicit RPC grants and no client MAINTAIN';
end;
$$;

rollback;
