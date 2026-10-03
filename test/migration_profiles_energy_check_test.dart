// WIRING GUARD for supabase/migrations/20261003100000_profiles_energy_check.sql
// (weekly energy check, docs/WEIGHT-TREND.md stage 2).
//
// Structural check of the SQL text, like migration_*_test.dart: PostgreSQL
// itself runs it in the RLS job (test/migrations/offline_sync_receipts.sql
// proves persistence, the keep-on-missing-key rule and the range check).
// This goes red if either side moves: the columns, their write path in
// apply_sync_operation, the absence of client grants, or the client wire.

import 'dart:io';

import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/services/sync_operation_payload.dart';
import 'package:eatova/src/services/sync_outbox.dart';
import 'package:flutter_test/flutter_test.dart';

const String _pfad =
    'supabase/migrations/20261003100000_profiles_energy_check.sql';

String _ohneKommentare(String sql) => sql
    .split('\n')
    .map((zeile) {
      final i = zeile.indexOf('--');
      return i < 0 ? zeile : zeile.substring(0, i);
    })
    .join('\n')
    .toLowerCase();

String get _sql => _ohneKommentare(File(_pfad).readAsStringSync());

void main() {
  test('both columns exist idempotently with the right types', () {
    expect(
      RegExp(r'add\s+column\s+if\s+not\s+exists\s+energy_adjustment_kcal\s+smallint\s+not\s+null\s+default\s+0')
          .hasMatch(_sql),
      isTrue,
    );
    expect(
      RegExp(r'add\s+column\s+if\s+not\s+exists\s+energy_checked_on\s+date\b')
          .hasMatch(_sql),
      isTrue,
    );
    expect(
      RegExp(r'check\s*\(\s*energy_adjustment_kcal\s+between\s+-1000\s+and\s+1000\s*\)')
          .hasMatch(_sql),
      isTrue,
      reason: 'the server backstop for the client cap of ±500',
    );
  });

  test('apply_sync_operation writes both and keeps them on a missing key', () {
    final branch = RegExp(
      r"elsif\s+p_kind\s*=\s*'profileupsert'(.*?)elsif\s+p_kind",
      dotAll: true,
    ).firstMatch(_sql);
    expect(branch, isNotNull, reason: 'the migration redefines the function');
    final body = branch!.group(1)!;
    for (final column in ['energy_adjustment_kcal', 'energy_checked_on']) {
      expect(body, contains(column));
      expect(
        RegExp("\\(p_payload->'row'\\)\\s*\\?\\s*'$column'").hasMatch(body),
        isTrue,
        reason: 'an older build without $column must not reset it',
      );
    }
  });

  test('no migration grants the new columns to clients', () {
    for (final file in Directory('supabase/migrations').listSync()) {
      if (file is! File || !file.path.endsWith('.sql')) continue;
      final sql = _ohneKommentare(file.readAsStringSync());
      expect(
        RegExp(r'grant\s+\w+\s*\([^)]*energy_(adjustment_kcal|checked_on)')
            .hasMatch(sql),
        isFalse,
        reason: '${file.path}: written only through the SECURITY DEFINER RPC',
      );
    }
  });

  test('the client wire and the server load carry both fields', () {
    final payload = encodeSyncOperationPayload(
      SyncOp.profileUpsert(
        UserProfile(
          onboardingCompleted: true,
          energyAdjustmentKcal: -150,
          energyCheckedOn: DateTime(2026, 10, 3),
        ),
      ),
    );
    final row = payload['row'] as Map;
    expect(row['energy_adjustment_kcal'], -150);
    expect(row['energy_checked_on'], '2026-10-03');

    final load = File('lib/src/services/profile_sync.dart').readAsStringSync();
    expect(load, contains('energy_adjustment_kcal, energy_checked_on'));
  });
}
