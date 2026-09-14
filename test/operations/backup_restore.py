"""Rehearse a synthetic database restore in two disposable, networkless containers.

Run: python test/operations/backup_restore.py --prove-detection
Requires Docker and the CI-pinned PostgreSQL image already present locally.
No URL, credentials, existing container or dump input is accepted.
"""

import argparse
import hashlib
import json
import pathlib
import subprocess
import time
import uuid

ROOT = pathlib.Path(__file__).resolve().parents[2]
IMAGE = 'postgres@sha256:00bc86618629af00d2937fdc5a5d63db3ff8450acf52f0636ec813c7f4902929'
LABEL = 'eatova.synthetic-restore'


def command(args, *, data=None, expect_ok=True):
    result = subprocess.run(args, input=data, capture_output=True, timeout=180)
    if expect_ok and result.returncode:
        # Do not echo command output. This tool must remain safe if Docker fails.
        raise RuntimeError('Synthetic restore command failed: ' + args[0])
    return result


def docker(*args, **kwargs):
    return command(['docker', *args], **kwargs)


def sql(container, text, *, expect_ok=True):
    return docker('exec', '-i', container, 'psql', '-X', '-qAt', '-v',
                  'ON_ERROR_STOP=1', '-U', 'postgres', '-d', 'rehearsal',
                  data=text.encode(), expect_ok=expect_ok)


def fingerprints(container):
    tables = sql(container, "select schemaname || '.' || tablename from pg_tables "
                 "where schemaname in ('auth', 'public') order by 1").stdout.decode().splitlines()
    result = {}
    for table in tables:
        # Identifiers come exclusively from the reviewed local migrations.
        schema, name = table.split('.')
        quoted = '.'.join('"' + part.replace('"', '""') + '"' for part in (schema, name))
        rows = sql(container, 'select to_jsonb(t)::text from ' + quoted +
                   ' t order by to_jsonb(t)::text').stdout
        result[table] = hashlib.sha256(rows).hexdigest()
    return result


def schema_fingerprint(container):
    # Compare catalog definitions independently of dump ordering / object OIDs.
    queries = [
        "select n.nspname,c.relname,c.relkind,c.relrowsecurity,c.relforcerowsecurity,"
        "pg_get_userbyid(c.relowner),array(select x::text from unnest(c.relacl) x order by 1) "
        "from pg_class c join pg_namespace n on n.oid=c.relnamespace "
        "where n.nspname in ('public','auth')",
        "select n.nspname,c.relname,a.attname,format_type(a.atttypid,a.atttypmod),"
        "a.attnotnull,a.attidentity,a.attgenerated,pg_get_expr(d.adbin,d.adrelid),"
        "array(select x::text from unnest(a.attacl) x order by 1) "
        "from pg_attribute a join pg_class c on c.oid=a.attrelid "
        "join pg_namespace n on n.oid=c.relnamespace "
        "left join pg_attrdef d on d.adrelid=a.attrelid and d.adnum=a.attnum "
        "where n.nspname in ('public','auth') and a.attnum>0 and not a.attisdropped",
        "select schemaname,tablename,policyname,permissive,roles,cmd,qual,with_check "
        "from pg_policies where schemaname in ('public','auth')",
        "select n.nspname,c.relname,p.conname,pg_get_constraintdef(p.oid,true) "
        "from pg_constraint p join pg_class c on c.oid=p.conrelid "
        "join pg_namespace n on n.oid=c.relnamespace where n.nspname in ('public','auth')",
        "select schemaname,tablename,indexname,indexdef from pg_indexes "
        "where schemaname in ('public','auth')",
        "select n.nspname,pg_get_functiondef(p.oid),pg_get_userbyid(p.proowner),"
        "array(select x::text from unnest(p.proacl) x order by 1) "
        "from pg_proc p join pg_namespace n on n.oid=p.pronamespace "
        "where n.nspname in ('public','auth') and p.prokind='f'",
        "select n.nspname,c.relname,t.tgname,t.tgenabled,pg_get_triggerdef(t.oid) "
        "from pg_trigger t join pg_class c on c.oid=t.tgrelid "
        "join pg_namespace n on n.oid=c.relnamespace where n.nspname in ('public','auth') "
        "and not t.tgisinternal",
        "select pg_get_userbyid(d.defaclrole),n.nspname,d.defaclobjtype,"
        "array(select x::text from unnest(d.defaclacl) x order by 1) "
        "from pg_default_acl d left join pg_namespace n on n.oid=d.defaclnamespace",
    ]
    parts = [sql(container, 'select to_jsonb(t)::text from (' + query +
                 ') t order by to_jsonb(t)::text').stdout for query in queries]
    return hashlib.sha256(b'\n'.join(parts)).hexdigest()


def role_fingerprint(container):
    return sql(container, "select rolname, rolcanlogin, rolinherit, rolsuper, rolbypassrls "
               "from pg_roles where rolname in ('anon','authenticated','service_role') "
               "order by rolname").stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prove-detection', action='store_true')
    args = parser.parse_args()
    docker('image', 'inspect', IMAGE)
    revision = command(['git', '-C', str(ROOT), 'rev-parse', 'HEAD']).stdout.decode().strip()
    if len(revision) != 40 or any(character not in '0123456789abcdef' for character in revision):
        raise RuntimeError('Cannot identify the reviewed source revision')
    run_id = uuid.uuid4().hex
    containers = []
    started = time.monotonic()
    report = {'source_revision': revision, 'synthetic_only': True,
              'network': 'none', 'published_ports': 0,
              'image': IMAGE, 'migration_count': 0}
    try:
        for side in ('source', 'restored'):
            name = 'eatova-restore-' + side + '-' + run_id
            docker('run', '-d', '--rm', '--network', 'none', '--label', LABEL + '=' + run_id,
                   '--name', name, '-e', 'POSTGRES_PASSWORD=synthetic-only',
                   '-e', 'POSTGRES_DB=rehearsal', IMAGE)
            containers.append(name)
            for _ in range(60):
                if docker('exec', name, 'pg_isready', '-U', 'postgres',
                          expect_ok=False).returncode == 0:
                    break
                time.sleep(0.25)
            else:
                raise RuntimeError('Synthetic PostgreSQL did not become ready')
        source, restored = containers
        sql(source, (ROOT / 'test/migrations/pg_bootstrap.sql').read_text(encoding='utf-8'))
        migrations = sorted((ROOT / 'supabase/migrations').glob('*.sql'))
        for migration in migrations:
            sql(source, migration.read_text(encoding='utf-8'))
        report['migration_count'] = len(migrations)
        sql(source, (ROOT / 'test/operations/backup_seed.sql').read_text(encoding='utf-8'))
        verifier = (ROOT / 'test/operations/backup_verify.sql').read_text(encoding='utf-8')
        sql(source, verifier)

        # pg_dump omits global roles. Restore them explicitly into the second
        # cluster; all values below were generated inside this synthetic run.
        roles = sql(source, "select format('CREATE ROLE %I NOLOGIN NOINHERIT %s;', "
                    "rolname, case when rolbypassrls then 'BYPASSRLS' else 'NOBYPASSRLS' end) "
                    "from pg_roles where rolname in ('anon','authenticated','service_role') "
                    "order by rolname").stdout.decode()
        sql(restored, roles)
        dump = docker('exec', source, 'pg_dump', '-U', 'postgres', '-d',
                      'rehearsal', '--format=custom').stdout
        if not dump.startswith(b'PGDMP'):
            raise RuntimeError('Unexpected synthetic backup format')
        restore_started = time.monotonic()
        docker('exec', '-i', restored, 'pg_restore', '-U', 'postgres', '-d', 'rehearsal',
               '--exit-on-error', '--single-transaction', data=dump)
        report['restore_seconds'] = round(time.monotonic() - restore_started, 3)
        report['backup_bytes'] = len(dump)
        report['backup_sha256'] = hashlib.sha256(dump).hexdigest()
        expected = fingerprints(source)
        if fingerprints(restored) != expected:
            raise RuntimeError('Restored table data differs from synthetic source')
        source_schema = schema_fingerprint(source)
        restored_schema = schema_fingerprint(restored)
        if source_schema != restored_schema:
            raise RuntimeError('Restored schema, constraints, policies or grants differ')
        if role_fingerprint(source) != role_fingerprint(restored):
            raise RuntimeError('Restored restricted role attributes differ')
        sql(restored, verifier)
        report.update(data_fingerprints_match=True, verified_tables=len(expected),
                      schema_and_grants_match=True, role_attributes_match=True,
                      restricted_role_read_write=True, cross_user_and_anon_denied=True)

        if args.prove_detection:
            sql(restored, 'alter table public.logged_meals disable row level security;')
            if schema_fingerprint(restored) == source_schema:
                raise RuntimeError('Changed RLS catalog setting was not detected')
            negative = sql(restored, verifier, expect_ok=False)
            if negative.returncode == 0 or b'RESTORE_RLS: foreign rows visible' not in negative.stderr:
                raise RuntimeError('Broken RLS was not detected for the expected reason')
            sql(restored, 'alter table public.logged_meals enable row level security;')
            sql(restored, verifier)
            sql(restored, "delete from public.logged_meals where user_id = "
                "'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';")
            if fingerprints(restored) == expected:
                raise RuntimeError('Lost row was not detected')
            report.update(missing_rls_detected=True, missing_data_detected=True)
        report['elapsed_seconds'] = round(time.monotonic() - started, 3)
        report['result'] = 'passed'
    finally:
        for name in containers:
            label = docker('inspect', '--format', '{{index .Config.Labels "' + LABEL + '"}}',
                           name).stdout.decode().strip()
            if label != run_id or not name.startswith('eatova-restore-'):
                raise RuntimeError('Refusing cleanup of a container not created by this run')
            docker('rm', '-f', name)
    report['containers_removed'] = len(containers)
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
