import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Growing guard against German hardcoded strings (i18n-design.md §6).
///
/// [_migriertePfade] is a COVERAGE list, not an exception list: every finished
/// i18n package appends its directory or file, and the list only ever grows.
/// At the end of the migration it covers `lib/` completely.
///
/// Heuristic, deliberately simple:
///   * Only single-quoted literals (`'...'`) — this repo never uses `"..."`,
///     raw or triple-quoted strings for UI text.
///   * Comments are stripped first, or an explanatory German comment would
///     trip the check.
///   * A finding is a literal containing ä/ö/ü/Ä/Ö/Ü/ß/„. In this repo those
///     characters appear only in real German prose: keys, asset paths and
///     log/Sentry texts are ASCII kebab-case or English. A key carrying one
///     would be a bug in its own right (keys are language-neutral, spec §4).
///
/// The character filter is blind to German words without umlauts. A second
/// layer catches part of that class — see [_anzeigeWoerterOhneUmlaut]. Full
/// extraction stays manual per package; this test is a safety net.
///
/// Deliberate, permanent exclusions from [_migriertePfade] — design decisions,
/// not migration gaps:
///  * `main.dart` — the boot error screen runs before l10n exists, so
///    `AppLocalizations.of` is structurally unreachable there.
///  * `lib/src/app/home_store.dart` — `coachContext`/`_todaysFoodSummary` are
///    free-text CONTEXT for the coach prompt, never rendered; the model reads
///    German context regardless of the answer language.
///  * `lib/src/models/recipe_catalog_de.dart` — German content by design.
///  * `lib/src/models/meal_analysis_result.dart` — remaining hits are legacy
///    compatibility DATA the `resolve()` methods must recognise, plus the
///    `portionNotes` sentences in `adjustedToGrams`/`adjustedToItems` and
///    `fromOpenFoodFacts`, which still need the same backwards-compatible
///    care (old rows carry finished German free text). Documented follow-up.
///
/// Service files without a BuildContext (`sync_error_messages.dart`,
/// `coach_chat_service.dart`, `kcal_calculator.dart`, `meal_analyzer.dart`)
/// are covered: they take an optional `[AppLocalizations? l10n]` with a German
/// default, or receive one via a setter, so context-free tests keep working.
const List<String> _migriertePfade = <String>[
  'lib/src/screens/today/',
  'lib/src/screens/meal_analysis_screen.dart',
  'lib/src/screens/barcode_scanner_sheet.dart',
  'lib/src/screens/meal_camera_sheet.dart',
  'lib/src/widgets/kcal/',
  'lib/src/widgets/meal/',
  'lib/src/services/kcal_format.dart',
  'lib/src/theme/meal_slot_style.dart',
  'lib/src/screens/recipes/',
  'lib/src/screens/coach/',
  'lib/src/screens/profile_screen.dart',
  'lib/src/widgets/profile/',
  'lib/src/screens/trends_screen.dart',
  'lib/src/screens/settings/',
  'lib/src/widgets/shared/',
  'lib/src/screens/onboarding_screen.dart',
  'lib/src/models/user_profile.dart',
  'lib/src/services/kcal_calculator.dart',
  'lib/src/services/sync_error_messages.dart',
  'lib/src/services/coach_chat_service.dart',
  'lib/src/app/home_store_meals.dart',
  'lib/src/app/home_store_sync.dart',
  'lib/src/app/home_store_tracking.dart',
  'lib/src/widgets/design/rows.dart',
  'lib/src/models/fitness_recipe.dart',
  'lib/src/models/recipe_catalog_en.dart',
  'lib/src/services/meal_analyzer.dart',
  'lib/src/services/open_food_facts_product_service.dart',
  'lib/src/services/notification_service.dart',
  'lib/src/services/streak_reminder_planner.dart',
  'lib/src/app/home_store_profile.dart',
  'lib/src/app/eatova_home_page.dart',
  'lib/src/app/eatova_app.dart',
  'lib/src/app/auth_gate.dart',
  'lib/src/app/locale_controller.dart',
  'lib/src/screens/auth_screen.dart',
  'lib/src/screens/auth_code_screen.dart',
  'lib/src/widgets/auth/',
  'lib/src/auth/',
];

/// Documented per-literal exceptions (file -> literals): deliberately
/// unmigrated single hits inside otherwise migrated files. A short, justified
/// deny list, not a coverage list. `_supabaseTrendLoader()` is a `static`
/// function without a `BuildContext`; TrendsScreen always catches the throw
/// and never renders it raw — same category as log/Sentry text (spec §4).
const Map<String, List<String>> _bekannteAusnahmen = <String, List<String>>{
  'lib/src/screens/meal_analysis_screen.dart': [
    "'Kein angemeldeter Nutzer für die Trend-Ansicht.'",
  ],
  // The `operation` argument of `_reportSyncError`/`_syncOrQueue` only reaches
  // `dev.log` and `CrashReporter.capture(context: ...)` — diagnostic text,
  // never in the UI. The other operation labels carry no umlaut and pass the
  // character filter anyway.
  'lib/src/app/home_store_sync.dart': [
    "'Konto-Löschung'",
  ],
};

/// Second layer: German display words WITHOUT umlauts, which the character
/// filter is structurally blind to.
///
/// Selection is short and exclusively lowercase:
///  * Time adverbs and confirmation participles are the vocabulary of snack
///    and status texts, and almost never carry an umlaut.
///  * German NOUNS (Mahlzeit, Favorit, Rezept, Tag) stay off the list: here
///    they are the outbox operation labels of `_syncOrQueue`, i.e. dev.log
///    text. A list including them would be half exceptions.
///  * Matching is case-SENSITIVE, and that is the real cut: `'Heute'` is a
///    language-neutral ValueKey, "heute" in prose is display text. Capitals
///    separate nouns and identifiers from adverbs and participles more
///    reliably than any exception list.
///
/// Missing on purpose: "entfernt". Its only current hit
/// (`'Favorit entfernt'`) has no ARB key yet, so the word would turn the
/// guard red with no way to make it green. Add it once the key exists.
const List<String> _anzeigeWoerterOhneUmlaut = <String>[
  'heute',
  'gestern',
  'morgen',
  'gespeichert',
  'aktualisiert',
  'verschoben',
  'geloescht',
  'hinzugefuegt',
];

final RegExp _literal = RegExp(r"'[^'\n]*'");
final RegExp _deutschesZeichen = RegExp('[äöüÄÖÜß„]');

/// Literals that are keys, paths or channel ids here: all-ASCII lowercase
/// joined by `-`/`_`/`.`/`/`. Only the WORD layer skips them — a list word
/// inside one is part of an identifier, not a sentence. Layer 1 still
/// applies: an umlaut in a key is a bug of its own (spec §4).
final RegExp _bezeichnerLiteral = RegExp(r'^[a-z0-9]+([-_./][a-z0-9]+)+$');

final List<RegExp> _wortTreffer = _anzeigeWoerterOhneUmlaut
    .map((wort) => RegExp('\\b$wort\\b'))
    .toList(growable: false);

/// Both layers for ONE literal, quotes included as [_literal] returns it. Its
/// own function so the self-check below can feed it directly instead of
/// walking the file tree.
bool _istDeutscheHartkodierung(String literalMitQuotes) {
  if (_deutschesZeichen.hasMatch(literalMitQuotes)) return true;
  final inhalt = literalMitQuotes.substring(1, literalMitQuotes.length - 1);
  if (_bezeichnerLiteral.hasMatch(inhalt)) return false;
  return _wortTreffer.any((treffer) => treffer.hasMatch(inhalt));
}

String _ohneKommentare(String quelle) => quelle
    .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
    .split('\n')
    .map((zeile) {
      final i = zeile.indexOf('//');
      return i < 0 ? zeile : zeile.substring(0, i);
    })
    .join('\n');

/// All findings of one source file, formatted as `path: literal`. [ausnahmen]
/// is the [_bekannteAusnahmen] entry and covers BOTH layers.
List<String> _fundeIn(String relativ, String quelle, List<String> ausnahmen) {
  final funde = <String>[];
  for (final match in _literal.allMatches(_ohneKommentare(quelle))) {
    final text = match.group(0)!;
    if (ausnahmen.contains(text)) continue;
    if (_istDeutscheHartkodierung(text)) funde.add('$relativ: $text');
  }
  return funde;
}

void main() {
  /// Accepts either a directory path (searched recursively) or a single
  /// `.dart` file, since some migrated screens have no folder of their own.
  List<File> dartDateien(String pfad) {
    final einzelDatei = File(pfad);
    if (einzelDatei.existsSync()) {
      return <File>[einzelDatei];
    }
    final dir = Directory(pfad);
    if (!dir.existsSync()) {
      fail('$pfad fehlt (aufgelöst von ${Directory.current.path}) — '
          'Tippfehler in _migriertePfade?');
    }
    return dir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .toList(growable: false);
  }

  test('die migrierten Pfade tragen keine deutschen Hartkodierungen mehr',
      () {
    final funde = <String>[];
    for (final pfad in _migriertePfade) {
      for (final datei in dartDateien(pfad)) {
        final relativ = datei.path.replaceAll(r'\', '/');
        funde.addAll(_fundeIn(
          relativ,
          datei.readAsStringSync(),
          _bekannteAusnahmen[relativ] ?? const <String>[],
        ));
      }
    }
    expect(
      funde,
      isEmpty,
      reason: 'Diese String-Literale tragen noch deutsche Hartkodierungen '
          '(Umlaut/ß/„ oder ein Wort aus _anzeigeWoerterOhneUmlaut) unter '
          'einem als migriert gemeldeten Pfad — entweder fehlt die '
          'ARB-Extraktion, oder der Pfad wurde zu früh '
          'eingetragen:\n${funde.join('\n')}',
    );
  });

  group('die Wort-Lage (umlautlose Anzeige-Texte)', () {
    test('sieht genau die Klasse, an der der Zeichenfilter vorbeilief', () {
      // The exact lines `home_store_meals.dart` once carried unnoticed,
      // restated here so the self-check does not depend on that file.
      const uebersehen = <String>[
        r"'Mahlzeit auf ${_moveDayLabel(updated.loggedAt)} verschoben.'",
        "'Mahlzeit aktualisiert.'",
        "'heute'",
        "'gestern'",
        "'Rezept gespeichert.'",
      ];
      for (final probe in uebersehen) {
        expect(_istDeutscheHartkodierung(probe), isTrue, reason: probe);
        expect(_deutschesZeichen.hasMatch(probe), isFalse,
            reason: 'sonst hätte Lage 1 gereicht und die Probe taugt nicht: '
                '$probe');
      }
    });

    test('lässt Bezeichner, Operationslabels und Englisch in Ruhe', () {
      // Forms that COULD carry the same words without being display text:
      // keys, diagnostics, paths, another language.
      const durchgelassen = <String>[
        "'Heute'", // navigation ValueKey id
        "'Mahlzeit-Update'", // outbox operation label, dev.log only
        "'Tag-Nachladen'",
        "'analyse-portion-notes'", // ValueKey
        "'assets/images/onboarding.png'",
        // Why [_bezeichnerLiteral] exists: a key may contain a list word and
        // is never rendered.
        "'food-heute-strip'",
        "'Meal updated.'", // English log text
      ];
      for (final probe in durchgelassen) {
        expect(_istDeutscheHartkodierung(probe), isFalse, reason: probe);
      }
    });

    test('löst in Kommentaren nicht aus', () {
      // Same trap as the character filter: the guard explains itself in German
      // comments and would otherwise flag itself.
      const quelle = '''
// heute verschoben und gespeichert — reiner Erklärtext
/* gestern aktualisiert */
/// heute
const x = 'today';
''';
      expect(_fundeIn('probe.dart', quelle, const <String>[]), isEmpty);
    });

    test('eine dokumentierte Ausnahme deckt beide Lagen', () {
      const quelle = "const x = 'heute';";
      expect(_fundeIn('probe.dart', quelle, const <String>[]), hasLength(1));
      expect(_fundeIn('probe.dart', quelle, const <String>["'heute'"]),
          isEmpty);
    });
  });

  test('die migrierten Pfade existieren wirklich (kein Tippfehler)', () {
    for (final pfad in _migriertePfade) {
      expect(
        Directory(pfad).existsSync() || File(pfad).existsSync(),
        isTrue,
        reason: pfad,
      );
    }
  });
}
