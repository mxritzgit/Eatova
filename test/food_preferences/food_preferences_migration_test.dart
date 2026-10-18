// WIRING GUARD for supabase/migrations/20261018100000_profiles_food_preferences.sql.
//
// Structural check of the SQL text, like migration_profiles_energy_check_test:
// PostgreSQL itself runs test/migrations/profile_food_preferences.sql in the
// RLS job. This goes red when the three copies of the closed code list drift
// apart (Dart enum, SQL check, coach-chat), when the caps differ, when a
// later apply_sync_operation forgets the columns or the keep-on-missing-key
// rule, or when a migration grants the columns to clients.

import 'dart:io';

import 'package:eatova/src/models/user_profile.dart';
import 'package:flutter_test/flutter_test.dart';

const String _pfad =
    'supabase/migrations/20261018100000_profiles_food_preferences.sql';
const String _recipePreferencesTs =
    'supabase/functions/coach-chat/recipe_preferences.ts';

String _ohneKommentare(String sql) => sql
    .split('\n')
    .map((zeile) {
      final i = zeile.indexOf('--');
      return i < 0 ? zeile : zeile.substring(0, i);
    })
    .join('\n')
    .toLowerCase();

String get _sql => _ohneKommentare(File(_pfad).readAsStringSync());

List<String> _quoted(String text) => RegExp(
  "['\"]([a-z]+)['\"]",
).allMatches(text).map((m) => m.group(1)!).toList();

/// The migration that defines apply_sync_operation LAST, i.e. the one live.
File get _letzteSyncOperation {
  final dateien =
      Directory('supabase/migrations')
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.sql'))
          .where(
            (f) => _ohneKommentare(f.readAsStringSync()).contains(
              'create or replace function public.apply_sync_operation(',
            ),
          )
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  return dateien.last;
}

void main() {
  final codes = FoodAvoidance.values.map((a) => a.name).toList();

  test('both columns exist idempotently with their defaults', () {
    expect(
      RegExp(
        r"add\s+column\s+if\s+not\s+exists\s+food_avoidances\s+text\[\]\s+not\s+null\s+default\s+'\{\}'",
      ).hasMatch(_sql),
      isTrue,
    );
    expect(
      RegExp(
        r"add\s+column\s+if\s+not\s+exists\s+food_dislikes\s+text\s+not\s+null\s+default\s+''",
      ).hasMatch(_sql),
      isTrue,
    );
  });

  test('the closed code list is the same in Dart, SQL and coach-chat', () {
    final allowed = RegExp(
      r'food_avoidances\s*<@\s*array\[([^\]]*)\]',
    ).firstMatch(_sql);
    expect(allowed, isNotNull, reason: 'the containment check');
    expect(_quoted(allowed!.group(1)!), codes);

    // Each code may appear once: one array_positions count per code.
    final einmal = RegExp(
      r"cardinality\(array_positions\(food_avoidances,\s*'([a-z]+)'\)\)\s*<=\s*1",
    ).allMatches(_sql).map((m) => m.group(1)!).toList();
    expect(einmal, codes, reason: 'duplicates must be impossible for all');
    expect(
      RegExp(
        'cardinality\\(food_avoidances\\)\\s*<=\\s*${codes.length}\\b',
      ).hasMatch(_sql),
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
    expect(
      RegExp(
        'char_length\\(food_dislikes\\)\\s*<=\\s*$kFoodDislikesMaxChars\\b',
      ).hasMatch(_sql),
      isTrue,
    );
    expect(
      _sql,
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

  test('the live apply_sync_operation writes both and keeps them on a '
      'missing key', () {
    final sql = _ohneKommentare(_letzteSyncOperation.readAsStringSync());
    final branch = RegExp(
      r"elsif\s+p_kind\s*=\s*'profileupsert'(.*?)elsif\s+p_kind",
      dotAll: true,
    ).firstMatch(sql);
    expect(branch, isNotNull, reason: _letzteSyncOperation.path);
    final body = branch!.group(1)!;
    final insert = RegExp(
      r'insert\s+into\s+public\.profiles\s+as\s+current_row\s*\(([^)]*)\)',
    ).firstMatch(body);
    expect(insert, isNotNull);
    final spalten = insert!.group(1)!.split(',').map((c) => c.trim());
    for (final column in <String>['food_avoidances', 'food_dislikes']) {
      expect(spalten, contains(column), reason: _letzteSyncOperation.path);
      expect(
        RegExp(
          "$column\\s*=\\s*case\\s+when\\s+\\(p_payload->'row'\\)\\s*\\?\\s*'$column'",
        ).hasMatch(body),
        isTrue,
        reason: 'an op an older build queued must not clear $column',
      );
    }
  });

  test('no migration grants the columns to clients', () {
    for (final file in Directory('supabase/migrations').listSync()) {
      if (file is! File || !file.path.endsWith('.sql')) continue;
      final sql = _ohneKommentare(file.readAsStringSync());
      expect(
        RegExp(
          r'grant\s+\w+\s*\([^)]*food_(avoidances|dislikes)',
        ).hasMatch(sql),
        isFalse,
        reason: '${file.path}: health data, written only through the RPC',
      );
    }
  });

  test('the load reads both columns, the export takes the whole row', () {
    final load = File('lib/src/services/profile_sync.dart').readAsStringSync();
    expect(load, contains('food_avoidances, food_dislikes'));
    final export = File('lib/src/services/data_export.dart').readAsStringSync();
    expect(
      export,
      contains(".select('*')"),
      reason: 'GDPR art. 20: new profile columns reach the export unasked',
    );
  });
}
