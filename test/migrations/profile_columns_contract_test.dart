// The profile columns between the app and supabase/migrations/.
//
// PostgreSQL itself proves persistence, the keep-on-missing-key rule, the
// range and character checks and the missing client grants
// (test/migrations/offline_sync_receipts.sql, profile_food_preferences.sql,
// run by the rls-postgres job); rls_invariants_test.dart pins the exact
// column grants. What neither sees is the Dart side, so this file pins the
// contract across languages: every column the client writes is written by
// the LIVE apply_sync_operation and read back by ProfileSync.load, and the
// closed lists and caps are the same in Dart, SQL and the coach function.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/services/profile_sync.dart';
import 'package:eatova/src/services/sync_operation_payload.dart';
import 'package:eatova/src/services/sync_outbox.dart';

const String _foodPreferencesSql =
    'supabase/migrations/20261018100000_profiles_food_preferences.sql';
const String _recipePreferencesTs =
    'supabase/functions/coach-chat/recipe_preferences.ts';

/// Server-only: set by the migration's backfill, never sent or read.
const String _serverOnlySnapshot = 'daily_kcal_goal_before_live_reset';

String _withoutComments(String sql) => sql
    .split('\n')
    .map((line) {
      final i = line.indexOf('--');
      return i < 0 ? line : line.substring(0, i);
    })
    .join('\n')
    .toLowerCase();

List<String> _quoted(String text) => RegExp(
  "['\"]([a-z]+)['\"]",
).allMatches(text).map((m) => m.group(1)!).toList();

/// The migration that defines apply_sync_operation LAST, i.e. the live one.
File get _liveSyncOperation {
  final files =
      Directory('supabase/migrations')
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.sql'))
          .where(
            (f) => _withoutComments(f.readAsStringSync()).contains(
              'create or replace function public.apply_sync_operation(',
            ),
          )
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  return files.last;
}

/// The keys of the `row` the client sends with a profile operation.
Set<String> _clientRowKeys() =>
    (encodeSyncOperationPayload(
              SyncOp.profileUpsert(
                UserProfile(
                  onboardingCompleted: true,
                  energyCheckedOn: DateTime(2026, 10, 3),
                ),
              ),
            )['row']
            as Map)
        .keys
        .cast<String>()
        .toSet();

void main() {
  test('the live apply_sync_operation inserts and updates every column the '
      'client sends', () {
    final file = _liveSyncOperation;
    final branch = RegExp(
      r"elsif\s+p_kind\s*=\s*'profileupsert'(.*?)elsif\s+p_kind",
      dotAll: true,
    ).firstMatch(_withoutComments(file.readAsStringSync()));
    expect(branch, isNotNull, reason: file.path);
    final body = branch!.group(1)!;
    final insert = RegExp(
      r'insert\s+into\s+public\.profiles(?:\s+as\s+\w+)?\s*\(([^)]*)\)',
    ).firstMatch(body);
    expect(insert, isNotNull, reason: file.path);
    final inserted = insert!.group(1)!.split(',').map((c) => c.trim()).toSet();
    final update = body.substring(body.indexOf('do update set'));

    final keys = _clientRowKeys();
    expect(keys, isNot(contains(_serverOnlySnapshot)));
    for (final column in keys) {
      expect(inserted, contains(column), reason: '${file.path}: $column');
      expect(
        update,
        matches(RegExp('\\b$column\\s*=')),
        reason: '${file.path}: an existing row would keep a stale $column',
      );
    }
  });

  test(
    'ProfileSync.load reads exactly the columns the client writes',
    () async {
      String? select;
      final client = SupabaseClient(
        'https://example.supabase.co',
        'test-anon-key',
        httpClient: MockClient((request) async {
          select = request.url.queryParameters['select'];
          return http.Response(
            '[]',
            200,
            request: request,
            headers: const {'content-type': 'application/json'},
          );
        }),
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
      addTearDown(client.dispose);

      await ProfileSync(client, 'user-1').load();

      expect(select, isNotNull);
      final read = select!.split(',').map((c) => c.trim()).toSet();
      // A written column that is never read back is overwritten with the
      // local default by the next save (food preferences, energy check).
      expect(read, _clientRowKeys());
      expect(read, isNot(contains(_serverOnlySnapshot)));
    },
  );

  test('the food avoidance codes are the same in Dart, SQL and coach-chat', () {
    final codes = FoodAvoidance.values.map((a) => a.name).toList();
    final sql = _withoutComments(File(_foodPreferencesSql).readAsStringSync());
    final allowed = RegExp(
      r'food_avoidances\s*<@\s*array\[([^\]]*)\]',
    ).firstMatch(sql);
    expect(allowed, isNotNull, reason: 'the containment check');
    expect(_quoted(allowed!.group(1)!), codes);

    // Each code may appear once: one array_positions count per code.
    final once = RegExp(
      r"cardinality\(array_positions\(food_avoidances,\s*'([a-z]+)'\)\)\s*<=\s*1",
    ).allMatches(sql).map((m) => m.group(1)!).toList();
    expect(once, codes, reason: 'duplicates must be impossible for all');
    expect(
      RegExp(
        'cardinality\\(food_avoidances\\)\\s*<=\\s*${codes.length}\\b',
      ).hasMatch(sql),
      isTrue,
    );

    final ts = File(_recipePreferencesTs).readAsStringSync();
    final tsList = RegExp(
      r'FOOD_AVOIDANCE_CODES\s*=\s*\[([^\]]*)\]',
    ).firstMatch(ts);
    expect(tsList, isNotNull);
    expect(_quoted(tsList!.group(1)!), codes);
  });

  test('the dislikes cap and character rule are the same everywhere', () {
    final sql = _withoutComments(File(_foodPreferencesSql).readAsStringSync());
    expect(
      RegExp(
        'char_length\\(food_dislikes\\)\\s*<=\\s*$kFoodDislikesMaxChars\\b',
      ).hasMatch(sql),
      isTrue,
    );
    expect(
      sql,
      contains(r"food_dislikes !~ e'[\\x01-\\x1f\\x7f-\\x9f<>]'"),
      reason: 'normalizeFoodDislikes removes exactly these classes',
    );
    final ts = File(_recipePreferencesTs).readAsStringSync();
    expect(
      RegExp(
        'MAX_DISLIKES_CHARS\\s*=\\s*$kFoodDislikesMaxChars\\b',
      ).hasMatch(ts),
      isTrue,
    );
  });

  test('the export takes whole rows, so new profile columns reach it', () {
    final export = File('lib/src/services/data_export.dart').readAsStringSync();
    expect(
      export,
      contains(".select('*')"),
      reason: 'GDPR art. 20: new profile columns reach the export unasked',
    );
  });
}
