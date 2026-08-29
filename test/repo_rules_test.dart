// REPO RULES — every guard that reads SOURCE TEXT instead of running code.
//
// These rules used to sit in eight files, each walking `lib/` on its own. The
// rules themselves are unchanged, allowlists and rationales included; only the
// file tree is now read ONCE (see [_libQuellen]) and shared by all of them.
// Each rule is one `test(...)` and carries the reason it exists.
//
// Guards that assert real BEHAVIOUR stay in their own files:
//   * services/crash_reporter_wiring_test.dart — layers 1 and 3 run
//     `configureSentry` and `buildEatovaApp()`; only its source layer moved
//     here.
//   * wire_search_key_envelope_test.dart — pins the wire contract of ONE pair
//     of files against each other, no tree walk, no shared allowlist.
//   * migration_*_test.dart, fixlauf_g_manual_energy_migration_test.dart,
//     wiring_android_manifest_test.dart, wiring_notification_small_icon_test
//     .dart — SQL, XML and VectorDrawable parsers; folding them in would bury
//     these rules under three parsers.
//   * services/local_cache_test.dart — reads the model source only to BUILD
//     the expectation for a real write-through roundtrip.
//   * profile_export_sheet_test.dart — its migrations drift guard shares the
//     table literal with the strict PostgREST mock in the same file; splitting
//     them would duplicate exactly the constant the guard protects.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/home_store.dart' show kCoachContextCapChars;
import 'package:eatova/src/screens/coach/coach_chat_screen.dart'
    show kCoachMaxInputBytes, kCoachMaxInputChars;

// ---------------------------------------------------------------------------
// The single tree walk
// ---------------------------------------------------------------------------

/// One Dart source under `lib/`: path with `/`, raw text, and the text with
/// comments stripped. Built once, reused by every rule below.
class _Quelle {
  _Quelle(this.pfad, this.roh) : ohneKommentare = _dartOhneKommentare(roh);

  final String pfad;
  final String roh;
  final String ohneKommentare;

  String get basisName => pfad.split('/').last;
}

/// Source without comments, else an explanatory comment would trip a scan.
String _dartOhneKommentare(String quelle) => quelle
    .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
    .split('\n')
    .map((z) {
      final i = z.indexOf('//');
      return i < 0 ? z : z.substring(0, i);
    })
    .join('\n');

late List<_Quelle> _libQuellen;

List<_Quelle> _leseLib() {
  final wurzel = Directory('lib');
  if (!wurzel.existsSync()) {
    fail('lib/ fehlt (aufgeloest von ${Directory.current.path})');
  }
  final quellen = <_Quelle>[];
  for (final e in wurzel.listSync(recursive: true)) {
    if (e is! File || !e.path.endsWith('.dart')) continue;
    quellen.add(_Quelle(e.path.replaceAll(r'\', '/'), e.readAsStringSync()));
  }
  expect(quellen, isNotEmpty);
  return quellen;
}

_Quelle _quelle(String pfad) => _libQuellen.firstWhere(
      (q) => q.pfad == pfad,
      orElse: () => fail('$pfad fehlt unter lib/'),
    );

/// Direct children of [ordner] (which ends with `/`), not recursing.
Iterable<_Quelle> _direktIn(String ordner) => _libQuellen.where(
      (q) =>
          q.pfad.startsWith(ordner) &&
          !q.pfad.substring(ordner.length).contains('/'),
    );

/// Sources under [pfad], which is either a directory (trailing `/`, searched
/// recursively) or a single `.dart` file — some migrated screens have no
/// folder of their own.
Iterable<_Quelle> _unter(String pfad) => _libQuellen.where(
      (q) => pfad.endsWith('/') ? q.pfad.startsWith(pfad) : q.pfad == pfad,
    );

String _lies(String pfad) {
  final datei = File(pfad);
  if (!datei.existsSync()) {
    fail('$pfad fehlt (aufgeloest von ${Directory.current.path})');
  }
  return datei.readAsStringSync();
}

// ---------------------------------------------------------------------------
// Allowlists — moved verbatim from the files that used to own them
// ---------------------------------------------------------------------------

/// Files that may hold fixed colors, each with its reason. Everything here is
/// a surface that must NOT follow the display mode; a new entry needs a
/// reason of the same kind.
const Map<String, String> _festeFarbenErlaubt = <String, String>{
  'lib/src/screens/auth_screen.dart':
      'Google "G" in the OAuth button: third-party brand colors per Google sign-in branding guidelines, never themed',
  'lib/src/screens/barcode_scanner_sheet.dart':
      'camera overlay on the live viewfinder: black/white scrims and glyphs on video, deliberately mode-independent',
  'lib/src/screens/meal_camera_sheet.dart':
      'camera overlay on the live viewfinder (see file comment), deliberately mode-independent',
  'lib/src/widgets/kcal/scan_slot_chips.dart':
      'slot chips drawn ON the camera overlay: black/white on video',
  'lib/src/screens/recipes/recipe_cards.dart':
      'legibility scrim over a recipe photo: black gradient on an image, not on a surface',
};

/// [_migriertePfade] is a COVERAGE list, not an exception list: every finished
/// i18n package appends its directory or file, and the list only ever grows.
/// At the end of the migration it covers `lib/` completely.
///
/// Deliberate, permanent exclusions — design decisions, not migration gaps:
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
/// Missing so far: "entfernt". It used to have no ARB key, so the word would
/// have turned the guard red with no way to make it green. That precondition
/// is gone — `'Favorit entfernt'` now lives only in
/// `lib/src/l10n/generated/` (key `commonFavoriteRemoved`), outside every
/// migrated path — and adding it here was measured green. Left out of this
/// consolidation on purpose: it would STRENGTHEN the rule, which is a
/// separate decision from moving it.
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

// ---------------------------------------------------------------------------
// i18n heuristic (spec §6)
//
// Deliberately simple:
//   * Only single-quoted literals (`'...'`) — this repo never uses `"..."`,
//     raw or triple-quoted strings for UI text.
//   * Comments are stripped first, or an explanatory German comment would trip
//     the check.
//   * A finding is a literal containing ä/ö/ü/Ä/Ö/Ü/ß/„. In this repo those
//     characters appear only in real German prose: keys, asset paths and
//     log/Sentry texts are ASCII kebab-case or English. A key carrying one
//     would be a bug in its own right (keys are language-neutral, spec §4).
//
// The character filter is blind to German words without umlauts. A second
// layer catches part of that class — see [_anzeigeWoerterOhneUmlaut]. Full
// extraction stays manual per package; this is a safety net.
// ---------------------------------------------------------------------------

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

/// All findings of one source file, formatted as `path: literal`. [ausnahmen]
/// is the [_bekannteAusnahmen] entry and covers BOTH layers.
List<String> _fundeIn(String relativ, String quelle, List<String> ausnahmen) {
  final funde = <String>[];
  for (final match in _literal.allMatches(_dartOhneKommentare(quelle))) {
    final text = match.group(0)!;
    if (ausnahmen.contains(text)) continue;
    if (_istDeutscheHartkodierung(text)) funde.add('$relativ: $text');
  }
  return funde;
}

// ---------------------------------------------------------------------------

void main() {
  setUpAll(() {
    _libQuellen = _leseLib();
  });

  // =========================================================================
  // Token discipline — the three hard rules from DESIGN_REFACTOR §3
  // =========================================================================
  group('Token-Disziplin in lib/', () {
    test('niemand importiert app_colors.dart mehr (die Datei ist weg)', () {
      expect(File('lib/src/theme/app_colors.dart').existsSync(), isFalse,
          reason: 'die alte Dunkel-Palette wurde mit der Auth-Runde geloescht');
      final treffer = <String>[];
      for (final quelle in _libQuellen) {
        if (quelle.ohneKommentare.contains('app_colors.dart')) {
          treffer.add(quelle.pfad);
        }
      }
      expect(
        treffer,
        isEmpty,
        reason: 'Diese Dateien haengen noch an der festen Dunkel-Palette und '
            'wuerden im Hell-Modus dunkle Flaechen zeichnen:\n'
            '${treffer.join('\n')}',
      );
    });

    test(
        'kein Color(0x…), Color.fromARGB( oder Colors.* ausserhalb von '
        'lib/src/theme/ (Allowlist mit Begruendung)', () {
      // `Colors.transparent` is no color choice and stays allowed everywhere.
      final feste = RegExp(
        r'Color\(0x|Color\.fromARGB\(|Colors\.(?!transparent\b)[a-zA-Z]',
      );
      final treffer = <String>[];
      for (final quelle in _libQuellen) {
        if (quelle.pfad.startsWith('lib/src/theme/')) continue;
        if (_festeFarbenErlaubt.containsKey(quelle.pfad)) continue;
        for (final zeile in quelle.ohneKommentare.split('\n')) {
          if (feste.hasMatch(zeile)) {
            treffer.add('${quelle.pfad}: ${zeile.trim()}');
          }
        }
      }
      expect(
        treffer,
        isEmpty,
        reason: 'Eine Konstante kann nicht hell UND dunkel sein — diese '
            'Farben gehoeren als Token nach app_tokens.dart (oder mit '
            'Begruendung in _festeFarbenErlaubt):\n${treffer.join('\n')}',
      );
      // The allowlist must not outlive its files.
      for (final pfad in _festeFarbenErlaubt.keys) {
        expect(File(pfad).existsSync(), isTrue, reason: '$pfad fehlt');
      }
    });

    test('kein Brightness-Abzweig fuer Farben ausserhalb von lib/src/theme/',
        () {
      // An `if (isDark)` in widget code rebuilds the palette a second time.
      // Allowed: the branch inside lib/src/theme/ (which picks the palette)
      // and the camera overlays, which name `AppTokens.dark` directly instead
      // of querying device brightness.
      final treffer = <String>[];
      for (final quelle in _libQuellen) {
        if (quelle.pfad.startsWith('lib/src/theme/')) continue;
        for (final zeile in quelle.ohneKommentare.split('\n')) {
          if (zeile.contains('Theme.of(context).brightness') ||
              zeile.contains('platformBrightnessOf') ||
              zeile.contains('MediaQuery.of(context).platformBrightness')) {
            treffer.add('${quelle.pfad}: ${zeile.trim()}');
          }
        }
      }
      expect(
        treffer,
        isEmpty,
        reason: 'Farbwahl ueber die Helligkeit gehoert als Token nach '
            'AppTokens:\n${treffer.join('\n')}',
      );
    });

    test('kein app_colors und keine harte Farbe mehr im Coach', () {
      // Coach design refactor: color comes exclusively from context.t
      // (AppTokens). Scans the RAW source on purpose — a leftover token name
      // in a comment is a leftover too.
      const verboten = <String>[
        'app_colors',
        'Color(0x',
        'coachAccent',
        'textPrimary',
        'textMuted',
        'surfaceSoft',
        'hairline',
        'cardShadow',
      ];
      final treffer = <String>[];
      for (final quelle in _direktIn('lib/src/screens/coach/')) {
        for (final wort in verboten) {
          if (quelle.roh.contains(wort)) {
            treffer.add('${quelle.basisName}: $wort');
          }
        }
      }
      expect(treffer, isEmpty,
          reason: 'Farbe kommt ausschliesslich aus context.t (AppTokens)');
    });
  });

  // =========================================================================
  // i18n — hardcoded German (spec §6)
  // =========================================================================
  group('Hartkodierungs-Waechter', () {
    test('die migrierten Pfade tragen keine deutschen Hartkodierungen mehr',
        () {
      final funde = <String>[];
      for (final pfad in _migriertePfade) {
        for (final quelle in _unter(pfad)) {
          funde.addAll(_fundeIn(
            quelle.pfad,
            quelle.roh,
            _bekannteAusnahmen[quelle.pfad] ?? const <String>[],
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

    test('die migrierten Pfade existieren wirklich (kein Tippfehler)', () {
      // Without this the rule above would go silently green on a typo: an
      // empty path contributes no findings.
      for (final pfad in _migriertePfade) {
        expect(
          Directory(pfad).existsSync() || File(pfad).existsSync(),
          isTrue,
          reason: pfad,
        );
        expect(_unter(pfad), isNotEmpty, reason: '$pfad enthaelt kein Dart');
      }
    });

    test('die Wort-Lage sieht genau die Klasse, an der der Zeichenfilter '
        'vorbeilief', () {
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

    test('die Wort-Lage laesst Bezeichner, Operationslabels und Englisch in '
        'Ruhe', () {
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

    test('die Wort-Lage loest in Kommentaren nicht aus', () {
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

    test('app_en.arb traegt exakt die Keys von app_de.arb', () {
      // Spec §6: a missing key would silently fall back to German — CI should
      // catch that, not the user. `@` entries are metadata, not texts.
      Set<String> keysOf(String pfad) =>
          (jsonDecode(_lies(pfad)) as Map<String, dynamic>)
              .keys
              .where((k) => !k.startsWith('@'))
              .toSet();

      final de = keysOf('lib/l10n/app_de.arb');
      final en = keysOf('lib/l10n/app_en.arb');
      expect(de, isNotEmpty, reason: 'app_de.arb ist die Vorlage');
      expect(en.difference(de), isEmpty,
          reason: 'app_en.arb hat Keys, die die Vorlage nicht kennt');
      expect(de.difference(en), isEmpty,
          reason: 'Diese Keys sind noch nicht uebersetzt');
    });
  });

  // =========================================================================
  // main.dart wiring — C1, leak 3, source layer
  //
  // Deleting the beforeSend assignment from `main.dart` once left 84 tests
  // green and `flutter analyze` clean: the whole filter was dead and nothing
  // noticed. The behaviour layers (configureSentry on real options, the built
  // widget's injected services) stay in
  // test/services/crash_reporter_wiring_test.dart — they alone would wave
  // through a never-called function, which is what this layer catches.
  // =========================================================================
  group('main.dart reicht die Konfiguration auch wirklich weiter', () {
    late String quelle;
    late String code;
    late String kompakt;

    setUpAll(() {
      quelle = _quelle('lib/main.dart').roh.replaceAll('\r\n', '\n');
      // Strip comment LINES only: the rationale in `main.dart` quotes the very
      // strings searched for here. A comment configures nothing and must
      // neither trip nor calm the guard.
      code = quelle
          .split('\n')
          .where((zeile) => !zeile.trimLeft().startsWith('//'))
          .join('\n');
      kompakt = code.replaceAll(RegExp(r'\s+'), ' ');
    });

    test('lib/main.dart ist ueberhaupt lesbar (sonst prueft die Lage nichts)',
        () {
      expect(quelle, contains('SentryFlutter.init'));
      expect(code, contains('SentryFlutter.init'),
          reason: 'sonst hat das Kommentar-Filter zu viel weggeworfen');
    });

    test('SentryFlutter.init bekommt configureSentry als erstes Argument', () {
      expect(kompakt, contains('SentryFlutter.init( configureSentry,'),
          reason: 'ohne diesen Aufruf ist der ganze Filter tot — genau die '
              'Mutation, die V3 in Welle 5 unbemerkt durchbekommen hat');
    });

    test(
        'main.dart konfiguriert die Optionen nicht mehr an configureSentry '
        'vorbei', () {
      // A reintroduced inline closure would replace configureSentry without
      // the behaviour layer noticing.
      expect(kompakt, isNot(contains('options.')),
          reason: 'die gesamte Sentry-Konfiguration gehoert in '
              'configureSentry, wo sie testbar ist');
    });

    test('main.dart ruft debugPrint nicht mehr auf', () {
      // C1, leak 1b: a boot-failure debugPrint sat two lines before the clean
      // capture, and DebugPrintIntegration would have turned it into a console
      // breadcrumb with the raw error and full stack in release.
      expect(code, isNot(contains('debugPrint')),
          reason: 'dart:developer verlaesst das Geraet nie, debugPrint schon');
    });

    test('der Boot-Fehler wird weiterhin lokal geloggt UND gemeldet', () {
      // The fix must not simply drop the developer diagnosis on boot failure.
      expect(kompakt, contains("name: 'boot'"));
      expect(
          kompakt,
          contains("CrashReporter.capture(error, stack, context: "
              "'boot')"));
    });
  });

  // =========================================================================
  // Cross-source constants
  // =========================================================================
  test('der Coach-Cap-Spiegel im Store stimmt mit guardrails.ts ueberein', () {
    // The store only mirrors the server limit; a stale mirror would make the
    // length assertions in home_store_coach_context_slots_test.dart worthless
    // (the edge function truncates `user_context` from the END).
    final source = _lies('supabase/functions/coach-chat/guardrails.ts');
    final match =
        RegExp(r'MAX_USER_CONTEXT_CHARS\s*=\s*(\d+)').firstMatch(source);
    expect(match, isNotNull,
        reason: 'Konstante in guardrails.ts nicht gefunden');
    expect(int.parse(match!.group(1)!), kCoachContextCapChars);
  });

  test('der Eingabe-Deckel im Composer stimmt mit coach-chat ueberein', () {
    // P5-03: the composer stops the draft AT the server's cap, so the 413
    // never happens and the message is never lost from an emptied field. The
    // client is only a mirror; TypeScript owns both numbers. A drift would
    // silently make the cap either useless (too high) or a false refusal of
    // messages the server accepts (too low).
    int zahl(String roh) => int.parse(roh.replaceAll('_', ''));

    final prefilter = _lies('supabase/functions/coach-chat/prefilter.ts');
    final zeichen =
        RegExp(r'MAX_INPUT_CHARS\s*=\s*([\d_]+)').firstMatch(prefilter);
    expect(zeichen, isNotNull,
        reason: 'MAX_INPUT_CHARS in prefilter.ts nicht gefunden');
    expect(zahl(zeichen!.group(1)!), kCoachMaxInputChars);

    final handler = _lies('supabase/functions/coach-chat/handler.ts');
    final bytes =
        RegExp(r'MAX_INPUT_BYTES\s*=\s*([\d_]+)').firstMatch(handler);
    expect(bytes, isNotNull,
        reason: 'MAX_INPUT_BYTES in handler.ts nicht gefunden');
    expect(zahl(bytes!.group(1)!), kCoachMaxInputBytes);
  });
}
