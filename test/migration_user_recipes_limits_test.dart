// VERDRAHTUNGS-WAECHTER — die Groessen- und Wertegrenzen von
// `public.user_recipes` und `public.chat_sessions.title`.
//
// Migration: supabase/migrations/20260819140000_user_recipes_limits.sql
// (Komplettreview 2026-08-19).
//
// AUSGANGSLAGE. `user_recipes` entstand 13 Tage NACH der Haertungsmigration
// 20260517220000_security_hardening.sql und ist deshalb nie in deren
// `<tabelle>_safe_ranges_check`-Block gewandert — sie war bis zu dieser
// Migration die einzige client-beschreibbare Tabelle ohne Laengen- oder
// Wertebereichsgrenze. Genau dieses Vergessen kann sich wiederholen: eine
// NEUE Spalte in `user_recipes` faellt ohne Waechter still aus dem Check.
//
// WAS DIESE DATEI IST UND WAS NICHT. Sie liest die Migration, die in die
// Datenbank geht, und prueft sie STRUKTURELL: SQL-Kommentare werden entfernt,
// die Check-Ruempfe der beiden Constraints herausgeschnitten und die Grenzen
// als Zahlen gelesen. Einrueckung, Reihenfolge der Konjunkte und
// Kommentartext sind ihr damit egal. Was sie NICHT kann: beweisen, dass
// PostgreSQL die Migration akzeptiert oder dass die Constraint auf der
// Produktivdatenbank angelegt wurde — dafuer braeuchte es eine echte DB.
//
// DER TEIL, DER MEHR IST ALS EINE ZEILENPRUEFUNG. Drei Behauptungen sind
// ABHAENGIGKEITEN zwischen Migration und Schreibpfad und werden rot, wenn
// jemand nur EINE Seite anfasst:
//
//   * jede client-beschreibbare Spalte aus 20260530091000_user_recipes.sql
//     kommt im Check vor (neue Spalte ohne Grenze -> rot),
//   * jede Grenze ist mindestens so gross wie das, was die App real schreibt
//     (Client: LoggedMealLimits; Coach: RECIPE_LIMITS aus recipe.ts) — eine
//     Grenze, die legitime Nutzerdaten abweist, waere schlimmer als keine,
//   * `chat_sessions.title` fasst den Auto-Titel der Edge Function
//     (handler.ts, `trimmed.slice(0, N)`).
//
// EINSTUFUNG: mittel. Kein `contains` ueber eine Quelltextzeile, aber auch
// keine Wirkungspruefung gegen eine laufende Datenbank.

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

/// Spalten aus dem `create table`-Block, die NICHT vom Client kommen: die
/// vergibt die DB per Default bzw. Trigger, bzw. RLS haelt sie fest.
const Set<String> _keineClientSpalten = {'id', 'user_id', 'created_at', 'updated_at'};

/// Zeilenanfaenge im `create table`-Block, die keine Spalte sind.
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

/// Entfernt `--`-Kommentare. Ohne das matcht die Begruendung im Kopf der
/// Migration (sie nennt jede Spalte und jede Zahl) genauso wie der echte
/// Check-Rumpf, und der Waechter waere wertlos.
String _ohneKommentare(String sql) => sql
    .split('\n')
    .map((zeile) {
      final i = zeile.indexOf('--');
      return i < 0 ? zeile : zeile.substring(0, i);
    })
    .join('\n');

/// Der Rumpf EINER Constraint: von `add constraint <name>` bis `not valid`.
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

/// Obergrenze aus `<ausdruck> between <min> and <max>`.
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

/// Obergrenze aus `<ausdruck> <= <max>`.
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

/// Ein Wert aus dem `RECIPE_LIMITS`-Objekt in recipe.ts. TypeScript-Zahlen
/// duerfen `_` als Tausendertrenner tragen (`2_000`).
int _tsLimit(String ts, String name) {
  final treffer =
      RegExp('${RegExp.escape(name)}\\s*:\\s*([0-9_]+)').firstMatch(ts);
  expect(treffer, isNotNull, reason: '$name steht nicht mehr in recipe.ts.');
  return int.parse(treffer!.group(1)!.replaceAll('_', ''));
}

/// Spaltennamen aus dem `create table … public.user_recipes (` -Block.
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

/// Die Migration ohne Kommentare. Bewusst pro Test gelesen statt in einem
/// `setUpAll`: `_lies` prueft selbst mit `expect`, und das gehoert in einen
/// Testrumpf.
String _migration() => _ohneKommentare(_lies(_migrationPfad));

/// Der Check-Rumpf von `user_recipes_safe_ranges_check`.
String _userRecipesRumpf() => _checkRumpf(_migration(), _userRecipesCheck);

void main() {
  group('20260819140000_user_recipes_limits — Struktur', () {
    test('beide Constraints werden idempotent ueber pg_constraint geprobt', () {
      final migration = _migration();
      // Muster aus 20260517220000_security_hardening.sql, Abschnitt 3: ohne
      // die Probe bricht ein zweiter Lauf der Migration mit 42710 ab.
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
      // _checkRumpf wirft sonst schon; hier zusaetzlich fuer chat_sessions.
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
      // Der eigentliche Fund war eine VERGESSENE Tabelle. Dieselbe Luecke
      // entsteht wieder, sobald jemand eine Spalte ergaenzt und den Check
      // nicht nachzieht — deshalb kommt die Spaltenliste aus der
      // Tabellen-Migration und nicht aus einer Handliste hier.
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
      // Ein Rezept wird ueber FitnessRecipe.toMealResult zur Mahlzeit und
      // muss dort durch logged_meals_safe_ranges_check. Waere user_recipes
      // ENGER, liesse sich eine geloggte Mahlzeit nicht mehr als Rezept
      // speichern.
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

      // Titel: das Anlege-Sheet begrenzt per `maxLength` auf
      // LoggedMealLimits.mealNameMaxChars, der Coach kappt auf titleMaxChars.
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
      // ingredients UND preparation kommen aus demselben Coach-Limit; das
      // Sheet-Feld fuer Zutaten ist sogar ganz ohne maxLength.
      final langtext = _tsLimit(ts, 'longTextMaxChars');
      expect(
        _obergrenze(userRecipesRumpf, 'char_length(ingredients)'),
        greaterThanOrEqualTo(langtext),
      );
      expect(
        _obergrenze(userRecipesRumpf, 'char_length(preparation)'),
        greaterThanOrEqualTo(langtext),
      );

      // image_asset traegt `local:img_<32 hex>.jpg` (~46 Zeichen) bzw. einen
      // Bundle-Assetpfad. 256 ist die Untergrenze, unter der es eng wuerde.
      expect(
        _obergrenze(userRecipesRumpf, 'char_length(image_asset)'),
        greaterThanOrEqualTo(256),
      );

      // slug: `user_coach_<message-uuid>` ist mit 47 Zeichen der laengste.
      final slug = _bereich(userRecipesRumpf, 'char_length(slug)');
      expect(slug.min, lessThanOrEqualTo(1));
      expect(slug.max, greaterThanOrEqualTo(128));
    });

    test('categories ist nach Anzahl UND Gesamtlaenge gedeckelt', () {
      // Nur `cardinality` (das Muster von daily_logs) liesse den EINZELNEN
      // Eintrag unbegrenzt — 1 Kategorie mit 100 MB waere weiter erlaubt.
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
      // handler.ts (maybeAutoTitle) kappt bei N Zeichen und haengt eine
      // Ellipse an — N + 1 ist der laengste Titel, den der Server je schreibt.
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
