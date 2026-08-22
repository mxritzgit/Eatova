// WIRING GUARD for the limits of `public.user_recipes` and
// `public.chat_sessions.title` set in
// supabase/migrations/20260819140000_user_recipes_limits.sql. `user_recipes`
// postdates the hardening migration and never entered its
// `<table>_safe_ranges_check` block; a NEW column can drop out as silently.
//
// Checks the migration STRUCTURALLY, so it cannot prove PostgreSQL accepts
// it. Three assertions go red if only ONE side moves: every client-writable
// column appears in the check; every limit is at least what the app writes,
// since one rejecting legitimate data is worse than none; and
// `chat_sessions.title` holds the edge function's auto title.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/model_limits.dart';

const String _migrationPfad =
    'supabase/migrations/20260819140000_user_recipes_limits.sql';
const String _tabellenPfad =
    'supabase/migrations/20260530091000_user_recipes.sql';
const String _recipeTsPfad = 'supabase/functions/coach-chat/recipe.ts';
const String _handlerTsPfad = 'supabase/functions/coach-chat/handler.ts';

const String _userRecipesCheck = 'user_recipes_safe_ranges_check';
const String _chatSessionsCheck = 'chat_sessions_safe_ranges_check';

/// Columns the client never writes: DB default, trigger, or pinned by RLS.
const Set<String> _keineClientSpalten = {'id', 'user_id', 'created_at', 'updated_at'};

/// Line starts in the `create table` block that are not a column.
const Set<String> _keineSpaltenSchluesselwoerter = {
  'unique',
  'primary',
  'foreign',
  'constraint',
  'check',
  'exclude',
};

String _lies(String pfad) {
  final datei = File(pfad);
  expect(
    datei.existsSync(),
    isTrue,
    reason: '$pfad fehlt — ohne die Migration hat user_recipes keine Grenzen.',
  );
  return datei.readAsStringSync();
}

/// Strips `--` comments; the header rationale names every column and number
/// and would otherwise match like the real check body.
String _ohneKommentare(String sql) => sql
    .split('\n')
    .map((zeile) {
      final i = zeile.indexOf('--');
      return i < 0 ? zeile : zeile.substring(0, i);
    })
    .join('\n');

/// The body of ONE constraint: from `add constraint <name>` to `not valid`.
String _checkRumpf(String sql, String conname) {
  final start = sql.indexOf('add constraint $conname');
  expect(
    start,
    isNonNegative,
    reason: 'Die Migration legt $conname nicht an.',
  );
  final ende = sql.indexOf('not valid', start);
  expect(
    ende,
    isNonNegative,
    reason:
        '$conname ist nicht `not valid` — ADD CONSTRAINT validiert dann den '
        'kompletten Bestand und die Migration scheitert an der ersten '
        'Altzeile, die die Grenze reisst.',
  );
  return sql.substring(start, ende);
}

/// Bounds from `<expr> between <min> and <max>`.
({int min, int max}) _bereich(String rumpf, String ausdruck) {
  final treffer = RegExp(
    '${RegExp.escape(ausdruck)}\\s+between\\s+(\\d+)\\s+and\\s+(\\d+)',
  ).firstMatch(rumpf);
  expect(
    treffer,
    isNotNull,
    reason: 'Kein `$ausdruck between … and …` im Check-Rumpf.',
  );
  return (min: int.parse(treffer!.group(1)!), max: int.parse(treffer.group(2)!));
}

/// Upper bound from `<expr> <= <max>`.
int _obergrenze(String rumpf, String ausdruck) {
  final treffer = RegExp(
    '${RegExp.escape(ausdruck)}\\s*<=\\s*(\\d+)',
  ).firstMatch(rumpf);
  expect(
    treffer,
    isNotNull,
    reason: 'Kein `$ausdruck <= …` im Check-Rumpf.',
  );
  return int.parse(treffer!.group(1)!);
}

/// One `RECIPE_LIMITS` value from recipe.ts; TypeScript numbers may carry
/// `_` as a thousands separator.
int _tsLimit(String ts, String name) {
  final treffer =
      RegExp('${RegExp.escape(name)}\\s*:\\s*([0-9_]+)').firstMatch(ts);
  expect(treffer, isNotNull, reason: '$name steht nicht mehr in recipe.ts.');
  return int.parse(treffer!.group(1)!.replaceAll('_', ''));
}

/// Column names from the `create table … public.user_recipes (` block.
List<String> _spalten(String sql) {
  const kopf = 'create table if not exists public.user_recipes (';
  final start = sql.indexOf(kopf);
  expect(start, isNonNegative, reason: 'create table-Block nicht gefunden.');
  final ende = sql.indexOf('\n);', start);
  expect(ende, isNonNegative, reason: 'create table-Block nicht beendet.');
  final block = sql.substring(start + kopf.length, ende);
  final namen = <String>[];
  for (final zeile in block.split('\n')) {
    final treffer = RegExp(r'^\s*([a-z_]+)\s').firstMatch(zeile);
    if (treffer == null) continue;
    final name = treffer.group(1)!;
    if (_keineSpaltenSchluesselwoerter.contains(name)) continue;
    namen.add(name);
  }
  expect(namen, isNotEmpty, reason: 'Keine Spalten geparst.');
  return namen;
}

/// The migration without comments; read per test, since `_lies` asserts.
String _migration() => _ohneKommentare(_lies(_migrationPfad));

/// The check body of `user_recipes_safe_ranges_check`.
String _userRecipesRumpf() => _checkRumpf(_migration(), _userRecipesCheck);

void main() {
  group('20260819140000_user_recipes_limits — Struktur', () {
    test('beide Constraints werden idempotent ueber pg_constraint geprobt', () {
      final migration = _migration();
      // Without the probe, a second run of the migration aborts with 42710.
      for (final conname in [_userRecipesCheck, _chatSessionsCheck]) {
        expect(
          migration.contains(
            "select 1 from pg_constraint where conname = '$conname'",
          ),
          isTrue,
          reason: '$conname wird nicht ueber pg_constraint geprobt.',
        );
      }
    });

    test('beide Constraints sind `not valid`', () {
      final migration = _migration();
      // _checkRumpf already throws otherwise; here also for chat_sessions.
      expect(_checkRumpf(migration, _chatSessionsCheck), isNotEmpty);
      expect(
        RegExp('not valid').allMatches(migration).length,
        greaterThanOrEqualTo(2),
        reason:
            'Beide ADD CONSTRAINT muessen `not valid` sein — sonst scheitert '
            'die Migration auf der Produktivdatenbank an Altzeilen.',
      );
    });

    test('JEDE client-beschreibbare Spalte von user_recipes hat eine Grenze', () {
      // The finding was a FORGOTTEN table, so the column list comes from the
      // table migration, not a hand-written one.
      final userRecipesRumpf = _userRecipesRumpf();
      final spalten = _spalten(_ohneKommentare(_lies(_tabellenPfad)));
      for (final spalte in spalten) {
        if (_keineClientSpalten.contains(spalte)) continue;
        expect(
          userRecipesRumpf.contains(spalte),
          isTrue,
          reason:
              'Spalte `$spalte` kommt in $_userRecipesCheck nicht vor — sie '
              'ist damit unbegrenzt beschreibbar.',
        );
      }
    });
  });

  group('20260819140000_user_recipes_limits — Grenzen sind grosszuegig genug', () {
    test('Zahlen decken die logged_meals-Grenzen ab', () {
      // A recipe becomes a meal via toMealResult and must pass
      // logged_meals_safe_ranges_check, so it must not be tighter.
      final userRecipesRumpf = _userRecipesRumpf();
      final kcal = _bereich(userRecipesRumpf, 'calories_kcal');
      expect(kcal.min, lessThanOrEqualTo(UserRecipeLimits.caloriesKcalMin));
      expect(kcal.max, greaterThanOrEqualTo(LoggedMealLimits.caloriesKcalMax));

      final gramm = _bereich(userRecipesRumpf, 'estimated_g');
      expect(gramm.min, lessThanOrEqualTo(UserRecipeLimits.estimatedGMin));
      expect(gramm.max, greaterThanOrEqualTo(LoggedMealLimits.estimatedGMax));

      for (final makro in ['protein_g', 'carbs_g', 'fat_g']) {
        final bereich = _bereich(userRecipesRumpf, makro);
        expect(bereich.min, lessThanOrEqualTo(0), reason: '$makro Untergrenze');
        expect(
          bereich.max,
          greaterThanOrEqualTo(LoggedMealLimits.macroGMax.toInt()),
          reason: '$makro Obergrenze',
        );
      }
    });

    test('Texte decken ab, was die App real schreibt', () {
      final userRecipesRumpf = _userRecipesRumpf();
      final ts = _lies(_recipeTsPfad);

      // Title: the sheet caps at mealNameMaxChars, the coach at titleMaxChars.
      final titel = _bereich(userRecipesRumpf, 'char_length(title)');
      expect(titel.min, lessThanOrEqualTo(1));
      expect(
        titel.max,
        greaterThanOrEqualTo(LoggedMealLimits.mealNameMaxChars),
        reason: 'Ein 160-Zeichen-Titel aus dem Sheet muss durchgehen.',
      );
      expect(titel.max, greaterThanOrEqualTo(_tsLimit(ts, 'titleMaxChars')));

      expect(
        _obergrenze(userRecipesRumpf, 'char_length(description)'),
        greaterThanOrEqualTo(_tsLimit(ts, 'descriptionMaxChars')),
      );
      expect(
        _obergrenze(userRecipesRumpf, 'char_length(portion)'),
        greaterThanOrEqualTo(_tsLimit(ts, 'portionMaxChars')),
      );
      // Both share one coach limit; the ingredients field has no maxLength.
      final langtext = _tsLimit(ts, 'longTextMaxChars');
      expect(
        _obergrenze(userRecipesRumpf, 'char_length(ingredients)'),
        greaterThanOrEqualTo(langtext),
      );
      expect(
        _obergrenze(userRecipesRumpf, 'char_length(preparation)'),
        greaterThanOrEqualTo(langtext),
      );

      // image_asset holds `local:img_<32 hex>.jpg` (~46 chars) or a bundle
      // path, so 256 is the floor.
      expect(
        _obergrenze(userRecipesRumpf, 'char_length(image_asset)'),
        greaterThanOrEqualTo(256),
      );

      // slug: `user_coach_<message-uuid>` is the longest at 47 chars.
      final slug = _bereich(userRecipesRumpf, 'char_length(slug)');
      expect(slug.min, lessThanOrEqualTo(1));
      expect(slug.max, greaterThanOrEqualTo(128));
    });

    test('categories ist nach Anzahl UND Gesamtlaenge gedeckelt', () {
      // `cardinality` alone would leave the single entry unbounded.
      final userRecipesRumpf = _userRecipesRumpf();
      expect(
        _obergrenze(userRecipesRumpf, 'cardinality(categories)'),
        greaterThanOrEqualTo(8),
        reason: 'Muss den Filterkatalog (recipeFilters) fassen.',
      );
      expect(
        userRecipesRumpf.contains('array_to_string(categories'),
        isTrue,
        reason:
            'Ohne Laengengrenze ueber das Array bleibt die Einzel-Kategorie '
            'unbegrenzt.',
      );
    });

    test('chat_sessions.title fasst den Auto-Titel der Edge Function', () {
      // maybeAutoTitle cuts at N and appends an ellipsis, so N + 1 is the
      // longest title the server ever writes.
      final handler = _lies(_handlerTsPfad);
      final treffer =
          RegExp(r'trimmed\.slice\(0,\s*(\d+)\)').firstMatch(handler);
      expect(
        treffer,
        isNotNull,
        reason: 'Auto-Titel-Kappung in handler.ts nicht gefunden.',
      );
      final autoTitel = int.parse(treffer!.group(1)!) + 1;

      final titel = _bereich(
        _checkRumpf(_migration(), _chatSessionsCheck),
        'char_length(title)',
      );
      expect(titel.min, lessThanOrEqualTo(1));
      expect(
        titel.max,
        greaterThanOrEqualTo(autoTitel),
        reason:
            'Der Auto-Titel wuerde an der Constraint scheitern und die '
            'Coach-Antwort mit 23514 abbrechen.',
      );
    });
  });
}
