-- GRANTs for the authenticated role. Without them even a logged-in user
-- cannot write to the public tables despite a matching RLS policy: Postgres
-- checks privileges BEFORE RLS. Symptom: 42501 "permission denied for table
-- X". The dashboard table editor does this automatically; raw SQL via the
-- Management API or psql does not.

-- Schema level (USAGE is required to query through the schema).
grant usage on schema public to anon, authenticated, service_role;

-- Full CRUD for logged-in users; RLS policies then decide which rows are
-- actually visible or changeable.
grant select, insert, update, delete on all tables in schema public
  to authenticated;

-- service_role gets everything anyway (edge functions, admin).
grant all on all tables in schema public to service_role;

-- Sequences (e.g. for serial PKs) need separate grants.
grant usage, select on all sequences in schema public to authenticated;
grant all on all sequences in schema public to service_role;

-- Functions: authenticated may call every function in public (custom RPC).
grant execute on all functions in schema public to authenticated, service_role;

-- Default privileges: every FUTURE table/sequence/function created in public
-- by the postgres owner gets these grants automatically, so this migration
-- does not have to be re-run for new tables.
alter default privileges in schema public
  grant select, insert, update, delete on tables to authenticated;
alter default privileges in schema public
  grant all on tables to service_role;
alter default privileges in schema public
  grant usage, select on sequences to authenticated;
alter default privileges in schema public
  grant all on sequences to service_role;
alter default privileges in schema public
  grant execute on functions to authenticated, service_role;
