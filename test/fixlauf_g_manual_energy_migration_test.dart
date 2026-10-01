// WIRING GUARD for supabase/migrations/20260828100000_profiles_manual_energy.sql
// (F7-01). public.profiles carries COLUMN grants since 20260819100000, so a
// new column the app writes must be granted for insert and update — otherwise
// the upsert fails loudly with 42501 on the first save after the app update.
//
// Structural check of the SQL text (pattern of migration_*_test.dart): it
// cannot prove PostgreSQL accepts it, but it goes red if either side moves —
// the column, its grants, the server insert, or the client wire payload.
//
// The current client writes profiles only through apply_sync_operation
// (SECURITY DEFINER). The column grants remain for older builds that still
// upsert directly; their payload is pinned in [_legacyDirectWriteColumns].

import 'dart:io';

import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/services/sync_operation_payload.dart';
import 'package:eatova/src/services/sync_outbox.dart';
import 'package:flutter_test/flutter_test.dart';

const String _migrationPfad =
    'supabase/migrations/20260828100000_profiles_manual_energy.sql';
const String _grantsPfad =
    'supabase/migrations/20260819100000_profiles_column_grants.sql';
const String _profileSyncPfad = 'lib/src/services/profile_sync.dart';
const String _syncReceiptsPfad =
    'supabase/migrations/20260920101000_sync_operation_receipts.sql';

/// Profile columns of the removed direct `ProfileSync.save` upsert (besides
/// `id`), as builds before 2026-10-01 still send them.
const Set<String> _legacyDirectWriteColumns = {
  'weight_kg', 'height_cm', 'age_years', 'sex', 'activity_level',
  'target_weight_kg', 'daily_steps_goal', 'daily_kcal_goal',
  'daily_water_goal_ml', 'daily_sleep_goal_minutes', 'protein_goal_g',
  'carbs_goal_g', 'fat_goal_g', 'weight_goal', 'diet_preference',
  'onboarding_completed', 'manual_energy',
};

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

  test('Live-Profil-Operation transportiert und schreibt manual_energy', () {
    for (final manual in [false, true]) {
      final payload = encodeSyncOperationPayload(
        SyncOp.profileUpsert(
          UserProfile(onboardingCompleted: true, manualEnergy: manual),
        ),
      );
      expect((payload['row'] as Map)['manual_energy'], manual,
          reason: 'das Flag muss im Wire-Payload stehen');
    }
    final sql = _ohneKommentare(_lies(_syncReceiptsPfad)).toLowerCase();
    final insert = RegExp(
      r"elsif\s+p_kind\s*=\s*'profileupsert'.*?insert\s+into\s+public\.profiles\s*\(([^)]*)\)",
      dotAll: true,
    ).firstMatch(sql);
    expect(insert, isNotNull);
    expect(insert!.group(1)!.split(',').map((c) => c.trim()),
        contains('manual_energy'),
        reason: 'apply_sync_operation muss die Spalte schreiben');
  });

  test('Direkt-Upsert älterer Builds bleibt gewährt (insert + update)', () {
    final grants = _ohneKommentare(_lies(_grantsPfad)).toLowerCase() +
        _ohneKommentare(_lies(_migrationPfad)).toLowerCase();
    final insert = _gewaehrt(grants, 'insert');
    final update = _gewaehrt(grants, 'update');
    for (final spalte in _legacyDirectWriteColumns) {
      expect(insert, contains(spalte), reason: '$spalte ohne insert-Grant');
      expect(update, contains(spalte), reason: '$spalte ohne update-Grant');
    }
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
      final row = encodeSyncOperationPayload(
        SyncOp.profileUpsert(const UserProfile(onboardingCompleted: true)),
      )['row'] as Map;
      expect(row.keys, isNot(contains(spalte)));
    });
  });
}
