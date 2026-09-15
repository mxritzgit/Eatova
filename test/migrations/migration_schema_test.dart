import 'package:flutter_test/flutter_test.dart';

import 'migration_schema.dart';

const _function = '''
create function public.probe() returns integer language sql
set search_path = '' as \$\$ select 7; \$\$;
''';

const _maintainRevoke = r'''
do $$
begin
  if current_setting('server_version_num')::integer >= 170000 then
    execute 'revoke maintain on all tables in schema public from public, anon, authenticated';
  end if;
end;
$$;
''';

SchemaState _replay(String sql) => schemaAusQuellen({'test.sql': sql});

void main() {
  group('PostgreSQL function defaults', () {
    test('a new function inherits built-in global PUBLIC EXECUTE', () {
      final schema = _replay(_function);
      expect(schema.unverstanden, isEmpty);
      expect(schema.funktionen['probe']!.executeRollen, {'public'});
    });

    test('a schema-local revoke cannot remove global PUBLIC EXECUTE', () {
      final schema = _replay('''
alter default privileges in schema public revoke execute on functions from public;
$_function
''');
      expect(schema.unverstanden, isEmpty);
      expect(schema.funktionen['probe']!.executeRollen, {'public'});
    });

    test('the global revoke removes implicit future EXECUTE', () {
      final schema = _replay('''
alter default privileges revoke execute on functions from public;
$_function
''');
      expect(schema.unverstanden, isEmpty);
      expect(schema.funktionen['probe']!.executeRollen, isEmpty);
    });

    test('schema grants remain additive after a global revoke', () {
      final schema = _replay('''
alter default privileges in schema public grant execute on functions to public, service_role;
alter default privileges revoke execute on functions from public;
$_function
''');
      expect(schema.unverstanden, isEmpty);
      expect(schema.funktionen['probe']!.executeRollen, {
        'public',
        'service_role',
      });
    });

    test('a schema revoke leaves an explicit global grant intact', () {
      final schema = _replay('''
alter default privileges revoke execute on functions from public;
alter default privileges grant execute on functions to service_role;
alter default privileges in schema public grant execute on functions to service_role;
alter default privileges in schema public revoke execute on functions from service_role;
$_function
''');
      expect(schema.unverstanden, isEmpty);
      expect(schema.funktionen['probe']!.executeRollen, {'service_role'});
    });

    test('default changes and replacement preserve an existing ACL', () {
      final schema = _replay('''
$_function
alter default privileges revoke execute on functions from public;
${_function.replaceFirst('create function', 'create or replace function')}
${_function.replaceFirst('probe()', 'later()')}
''');
      expect(schema.unverstanden, isEmpty);
      expect(schema.funktionen['probe']!.executeRollen, {'public'});
      expect(schema.funktionen['later']!.executeRollen, isEmpty);
    });

    test('unmodelled creator and global table defaults fail closed', () {
      for (final sql in [
        'alter default privileges for role other_owner '
            'revoke execute on functions from public;',
        'alter default privileges grant select on tables to anon;',
      ]) {
        expect(_replay(sql).unverstanden, isNotEmpty, reason: sql);
      }
    });
  });

  group('PostgreSQL 17 MAINTAIN', () {
    const seed = '''
create table public.notes(id integer);
grant all on public.notes to public, anon, authenticated, service_role;
''';

    test('GRANT ALL and an explicit grant include MAINTAIN', () {
      final all = _replay(seed);
      expect(
        all.tabellen['notes']!.alleRechte('authenticated'),
        contains('maintain'),
      );
      final explicit = _replay('''
create table public.notes(id integer);
grant maintain on public.notes to authenticated;
''');
      expect(explicit.tabellen['notes']!.alleRechte('authenticated'), {
        'maintain',
      });
    });

    test('the reviewed version guard revokes only client maintenance', () {
      final schema = _replay('$seed\n$_maintainRevoke');
      expect(schema.unverstanden, isEmpty);
      for (final role in ['public', 'anon', 'authenticated']) {
        expect(
          schema.tabellen['notes']!.alleRechte(role),
          kAlleTabellenrechte.difference({'maintain'}),
        );
      }
      expect(
        schema.tabellen['notes']!.alleRechte('service_role'),
        kAlleTabellenrechte,
      );
    });

    test(
      'a changed condition is not silently treated as the reviewed block',
      () {
        for (final condition in ['> 170000', '>= 180000', '< 170000']) {
          final schema = _replay(
            '$seed\n${_maintainRevoke.replaceFirst('>= 170000', condition)}',
          );
          expect(schema.unverstanden, isNotEmpty, reason: condition);
          expect(
            schema.tabellen['notes']!.alleRechte('authenticated'),
            contains('maintain'),
          );
        }
      },
    );

    test('changed SQL and extra statements in the same file fail closed', () {
      for (final body in [
        _maintainRevoke.replaceFirst(
          'from public, anon, authenticated',
          'from public, anon',
        ),
        _maintainRevoke.replaceFirst('revoke maintain', 'revoke select'),
        _maintainRevoke.replaceFirst(
          'end if;',
          "end if; execute 'grant select on public.notes to anon';",
        ),
      ]) {
        final schema = schemaAusQuellen({
          '00_seed.sql': seed,
          '20260915090000_database_privilege_boundaries.sql': body,
        });
        expect(schema.unverstanden, isNotEmpty);
      }
    });
  });
}
