-- PostgreSQL's schema defaults are additive: a schema-local REVOKE does
-- not remove the built-in global PUBLIC EXECUTE default. Apply this to the
-- migration owner globally; existing functions and explicit grants are kept.
alter default privileges revoke execute on functions from public;

-- PostgreSQL 17 added MAINTAIN to GRANT ALL. Earlier hardening removed
-- TRUNCATE/REFERENCES/TRIGGER but left this maintenance privilege on older
-- tables. The client has no maintenance task; keep its existing CRUD grants.
-- Dynamic SQL preserves replay compatibility with PostgreSQL 16.
do $$
begin
  if current_setting('server_version_num')::integer >= 170000 then
    execute 'revoke maintain on all tables in schema public from public, anon, authenticated';
  end if;
end;
$$;
