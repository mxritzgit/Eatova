// WIRING GUARD for supabase/migrations/20260828100000_profiles_manual_energy.sql
// (F7-01). public.profiles carries COLUMN grants since 20260819100000, so a
// new column the app writes must be granted for insert and update — otherwise
// the upsert fails loudly with 42501 on the first save after the app update.
//
// Structural check of the SQL text (pattern of migration_*_test.dart): it
// cannot prove PostgreSQL accepts it, but it goes red if either side moves —
// the column, its grants, or the ProfileSync payload.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const String _migrationPfad =
    'supabase/migrations/20260828100000_profiles_manual_energy.sql';
const String _grantsPfad =
    'supabase/migrations/20260819100000_profiles_column_grants.sql';
const String _profileSyncPfad = 'lib/src/services/profile_sync.dart';

String _lies(String pfad) {
  final datei = File(pfad);
  expect(datei.existsSync(), isTrue, reason: '$pfad fehlt.');
  return datei.readAsStringSync();
}

/// Strips `--` comments so the header rationale cannot satisfy a check.
String _ohneKommentare(String sql) => sql
    .split('\n')
    .map((zeile) {
      final i = zeile.indexOf('--');
      return i < 0 ? zeile : zeile.substring(0, i);
    })
    .join('\n');

/// Columns named in every `grant VERB ( ... ) on public.profiles to
/// authenticated` of [sql], for the given [verb].
Set<String> _gewaehrt(String sql, String verb) {
  final treffer = RegExp(
    'grant\\s+$verb\\s*\\(([^)]*)\\)\\s*on\\s+public\\.profiles\\s+to\\s+authenticated',
    multiLine: true,
  ).allMatches(sql);
  return <String>{
    for (final m in treffer)
      for (final s in m.group(1)!.split(','))
        if (s.trim().isNotEmpty) s.trim(),
  };
}

void main() {
  test('Spalte ist idempotent, boolean, not null, default false', () {
    final sql = _ohneKommentare(_lies(_migrationPfad)).toLowerCase();
    expect(
      RegExp(r'alter\s+table\s+public\.profiles\s+add\s+column\s+if\s+not\s+exists\s+manual_energy\s+boolean\s+not\s+null\s+default\s+false')
          .hasMatch(sql),
      isTrue,
      reason: 'ohne `if not exists` bricht der zweite Lauf mit 42701; '
          'ohne default false bleiben Altzeilen ohne Wert (NOT NULL).',
    );
  });

  test('Spalte ist fuer authenticated auf insert UND update gewaehrt', () {
    final sql = _ohneKommentare(_lies(_migrationPfad)).toLowerCase();
    expect(_gewaehrt(sql, 'insert'), contains('manual_energy'));
    expect(_gewaehrt(sql, 'update'), contains('manual_energy'));
  });

  test('JEDE Spalte des ProfileSync-Payloads ist gewaehrt (insert + update)',
      () {
    final grants = _ohneKommentare(_lies(_grantsPfad)).toLowerCase() +
        _ohneKommentare(_lies(_migrationPfad)).toLowerCase();
    final insert = _gewaehrt(grants, 'insert');
    final update = _gewaehrt(grants, 'update');

    final dart = _lies(_profileSyncPfad);
    // Payload keys of ProfileSync.save: `'column': profile.xxx`.
    final payload = RegExp(r"'([a-z_]+)':\s*profile\.")
        .allMatches(dart)
        .map((m) => m.group(1)!)
        .toSet();
    expect(payload, contains('manual_energy'),
        reason: 'save() muss das Flag schreiben, sonst bleibt es unpersistiert');
    for (final spalte in payload) {
      expect(insert, contains(spalte), reason: '$spalte ohne insert-Grant');
      expect(update, contains(spalte), reason: '$spalte ohne update-Grant');
    }
  });

  test('load() liest die Spalte (Select-Liste)', () {
    final dart = _lies(_profileSyncPfad);
    final columns = RegExp(r'static const _columns\s*=\s*([\s\S]*?);')
        .firstMatch(dart)!
        .group(1)!;
    expect(columns, contains('manual_energy'));
  });

  // Review I-1: the pre-reset snapshot is a SERVER-ONLY column. It exists
  // idempotently, the backfill runs once (guarded by `is null`), and the
  // client neither writes nor selects it — a grant here would be a leak of
  // the intent, not a bug fix.
  group('Snapshot daily_kcal_goal_before_live_reset (I-1)', () {
    const spalte = 'daily_kcal_goal_before_live_reset';

    test('Spalte ist idempotent, integer, nullable', () {
      final sql = _ohneKommentare(_lies(_migrationPfad)).toLowerCase();
      expect(
        RegExp('alter\\s+table\\s+public\\.profiles\\s+add\\s+column\\s+if\\s+not\\s+exists\\s+$spalte\\s+integer\\s*;')
            .hasMatch(sql),
        isTrue,
        reason: 'ohne `if not exists` bricht der zweite Lauf; NOT NULL '
            'waere falsch, ein fehlender Snapshot ist ein legitimer Zustand',
      );
    });

    test('Backfill kopiert daily_kcal_goal nur in leere Snapshots', () {
      final sql = _ohneKommentare(_lies(_migrationPfad)).toLowerCase();
      expect(
        RegExp('update\\s+public\\.profiles\\s+set\\s+$spalte\\s*=\\s*daily_kcal_goal\\s+where\\s+$spalte\\s+is\\s+null')
            .hasMatch(sql),
        isTrue,
        reason: 'ohne `is null` ueberschriebe ein zweiter Lauf den Snapshot '
            'mit dem bereits geheilten Wert',
      );
    });

    test('Spalte ist NICHT gewaehrt und NICHT im Client-Wiring', () {
      final grants = _ohneKommentare(_lies(_grantsPfad)).toLowerCase() +
          _ohneKommentare(_lies(_migrationPfad)).toLowerCase();
      expect(_gewaehrt(grants, 'insert'), isNot(contains(spalte)));
      expect(_gewaehrt(grants, 'update'), isNot(contains(spalte)));

      final dart = _lies(_profileSyncPfad);
      expect(dart, isNot(contains(spalte)),
          reason: 'der Snapshot ist server-only; der Client schreibt und '
              'liest ihn nicht');
    });
  });
}
