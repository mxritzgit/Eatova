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

// ---------------------------------------------------------------------------
// The shared character scanner
//
// Both source-text helpers below ([_dartOhneKommentare] and [_bisKlammerZu])
// have to tell CODE from the inside of a STRING LITERAL, so they share these
// three primitives instead of each guessing on its own.
//
// P10-03b: the comment stripper used to cut every line at its first `//`,
// literals included. `defaultValue: 'https://eatova.de/meili'` became
// `defaultValue: 'https:` — closing quote and paren gone — and the declaration
// parser then ran past the end of that call into the next one. A probe
// declaration whose default was a URL and that stood LAST in its file was read
// as the empty string, which made the "empty value deletes a compiled default"
// rule go green on exactly the regression it exists for.
// ---------------------------------------------------------------------------

const int _zEinfach = 0x27; // '
const int _zDoppelt = 0x22; // "
const int _zSchraeg = 0x2f; // /
const int _zStern = 0x2a; // *
const int _zR = 0x72; // r

/// Identifier characters, so the `r` in `for'` is not read as a raw literal.
final RegExp _bezeichnerZeichen = RegExp(r'[A-Za-z0-9_$]');

/// True when a string literal starts at [i]: a quote, or the `r` of `r'…'`.
bool _literalBeginnt(String quelle, int i) {
  final c = quelle.codeUnitAt(i);
  if (c == _zEinfach || c == _zDoppelt) return true;
  if (c != _zR || i + 1 >= quelle.length) return false;
  final naechste = quelle.codeUnitAt(i + 1);
  if (naechste != _zEinfach && naechste != _zDoppelt) return false;
  return i == 0 || !_bezeichnerZeichen.hasMatch(quelle[i - 1]);
}

/// Index just past the literal that starts at [i] (see [_literalBeginnt]).
///
/// Handles both quote characters, `r'…'` raw literals (no escapes inside),
/// `'''…'''` blocks, escaped quotes and `${…}` interpolations — the last one
/// because `'${x.split('.').first}'` carries quotes that belong to the
/// EXPRESSION, not to the literal. A single-quoted literal ends at the line
/// break at the latest: an unbalanced quote must not swallow the rest of the
/// file.
int _literalEnde(String quelle, int i) {
  var j = i;
  final roh = quelle.codeUnitAt(j) == _zR;
  if (roh) j++;
  final anfuehrung = quelle[j];
  final dreifach = quelle.startsWith(anfuehrung * 3, j);
  final schluss = dreifach ? anfuehrung * 3 : anfuehrung;
  j += schluss.length;
  while (j < quelle.length) {
    if (quelle.startsWith(schluss, j)) return j + schluss.length;
    final c = quelle[j];
    if (!dreifach && c == '\n') return j;
    if (!roh && c == r'\') {
      j += 2;
      continue;
    }
    if (!roh && quelle.startsWith(r'${', j)) {
      j = _geschweiftEnde(quelle, j + 2);
      continue;
    }
    j++;
  }
  return quelle.length;
}

/// Index just past the `}` matching the `${` whose body starts at [start].
int _geschweiftEnde(String quelle, int start) {
  var tiefe = 1;
  var j = start;
  while (j < quelle.length) {
    if (_literalBeginnt(quelle, j)) {
      j = _literalEnde(quelle, j);
      continue;
    }
    final c = quelle[j];
    if (c == '{') {
      tiefe++;
    } else if (c == '}') {
      tiefe--;
      if (tiefe == 0) return j + 1;
    }
    j++;
  }
  return quelle.length;
}

/// Source without comments, else an explanatory comment would trip a scan.
///
/// Literal-aware (P10-03b): a `//` or `/*` INSIDE a string literal is text,
/// not a comment. Block comments nest as Dart nests them and leave their line
/// breaks behind, so line-based rules stay on their own line.
String _dartOhneKommentare(String quelle) {
  final aus = StringBuffer();
  var i = 0;
  var laufAb = 0;
  while (i < quelle.length) {
    final c = quelle.codeUnitAt(i);
    if ((c == _zEinfach || c == _zDoppelt || c == _zR) &&
        _literalBeginnt(quelle, i)) {
      i = _literalEnde(quelle, i); // stays inside the copied run
      continue;
    }
    if (c != _zSchraeg || i + 1 >= quelle.length) {
      i++;
      continue;
    }
    final naechste = quelle.codeUnitAt(i + 1);
    if (naechste == _zSchraeg) {
      aus.write(quelle.substring(laufAb, i));
      while (i < quelle.length && quelle[i] != '\n') {
        i++;
      }
      laufAb = i;
      continue;
    }
    if (naechste == _zStern) {
      aus.write(quelle.substring(laufAb, i));
      final von = i;
      var tiefe = 0;
      while (i < quelle.length) {
        if (quelle.startsWith('/*', i)) {
          tiefe++;
          i += 2;
        } else if (quelle.startsWith('*/', i)) {
          tiefe--;
          i += 2;
          if (tiefe == 0) break;
        } else {
          i++;
        }
      }
      aus.write('\n' * (quelle.substring(von, i).split('\n').length - 1));
      laufAb = i;
      continue;
    }
    i++;
  }
  aus.write(quelle.substring(laufAb));
  return aus.toString();
}

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
// "Echte Fotos" — the claim detector behind the recipesSubtitle rule below
// ---------------------------------------------------------------------------

/// Stems naming a picture, matched as a PREFIX so German compounds and plurals
/// ("Bildern", "Aufnahmen", "images") are covered without a word list.
const List<String> _bildStaemme = <String>[
  'bild',
  'foto',
  'photo',
  'aufnahme',
  'image',
  'picture',
];

/// Stems claiming photographic reality. Prefix matching also catches
/// "realistisch"/"realistic", which is the same claim in a softer coat.
const List<String> _echtStaemme = <String>[
  'echt',
  'real',
  'authentisch',
  'authentic',
  'original',
  'genuine',
  'naturgetreu',
];

bool _hatStamm(String wort, List<String> staemme) =>
    staemme.any(wort.startsWith);

/// Returns WHY [satz] claims real photography, or null if it does not.
///
/// The window is deliberately asymmetric — two words BEFORE the picture word,
/// one after. Both German and English put the adjective in front of its noun,
/// so that is where the claim lives ("echte Bilder", "real photos"). Reaching
/// two words to the RIGHT as well would flag the honest sentence this rule was
/// written for: in "KI-Bildern und echten Tracker-Werten" the "echt" belongs to
/// the VALUES, which really are real — a false alarm there would get the guard
/// deleted instead of the copy fixed.
String? _echtheitsBehauptung(String satz) {
  final woerter = satz
      .toLowerCase()
      // Range starts at ß, not à: otherwise "groß" would split mid-word.
      .split(RegExp(r'[^a-zß-öø-ÿ]+'))
      .where((w) => w.isNotEmpty)
      .toList();
  for (var i = 0; i < woerter.length; i++) {
    if (!_hatStamm(woerter[i], _bildStaemme)) continue;
    final von = i - 2 < 0 ? 0 : i - 2;
    final bis = i + 1 >= woerter.length ? woerter.length - 1 : i + 1;
    for (var j = von; j <= bis; j++) {
      if (j == i) continue;
      if (_hatStamm(woerter[j], _echtStaemme)) {
        return '"${woerter[j]}" steht neben "${woerter[i]}"';
      }
    }
  }
  return null;
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

/// Files that may name the raw heading properties (`header:`,
/// `headingLevel:`) themselves, each with its reason. See the rule
/// "Ueberschriften kommen aus HeadingSemantics" below.
const Map<String, String> _eigeneUeberschriftErlaubt = <String, String>{
  'lib/src/widgets/design/surfaces.dart':
      'defines HeadingSemantics — the one place both properties are set, and the only one that can guarantee they stay paired',
};

/// Every way of asking the device for its display mode. The argument is
/// `[^)]*` on purpose: `context`, `ctx`, `c` and `this.context` are the same
/// branch, and pinning one spelling is what let the rule be walked around.
final RegExp _helligkeitsAbzweig = RegExp(
  r'Theme\.(?:of|maybeOf)\([^)]*\)[?!]?\.brightness'
  r'|platformBrightnessOf\('
  r'|MediaQuery\.(?:of|maybeOf)\([^)]*\)[?!]?\.platformBrightness'
  r'|\.platformDispatcher\.platformBrightness',
);

/// The two Semantics properties that make a jump mark. `header` alone is what
/// TalkBack and VoiceOver navigate by, `headingLevel` alone is the rank —
/// either without the other is the exact defect P9-06/P9-06b found, so both
/// are banned outside [HeadingSemantics].
final RegExp _ueberschriftEigenschaft =
    RegExp(r'\b(header|headingLevel)\s*:');

/// Findings for ONE source. Own function so the self-checks below can feed it
/// a snippet instead of walking the tree.
List<String> _eigeneUeberschriftFunde(String pfad, String quelle) {
  final funde = <String>[];
  for (final zeile in _dartOhneKommentare(quelle).split('\n')) {
    if (_ueberschriftEigenschaft.hasMatch(zeile)) {
      funde.add('$pfad: ${zeile.trim()}');
    }
  }
  return funde;
}

/// [_migriertePfade] is a COVERAGE list, not an exception list: every finished
/// i18n package appends its directory or file, and the list only ever grows.
/// At the end of the migration it covers `lib/` completely.
///
/// Deliberate, permanent exclusions — design decisions, not migration gaps:
///  * `main.dart` — the boot error screen runs before l10n exists, so
///    `AppLocalizations.of` is structurally unreachable there.
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
  'lib/src/app/home_store.dart',
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
///
/// P1-04: `home_store.dart` used to be excluded as a WHOLE file, justified
/// with the coach prompt context. A file is the wrong unit — the exclusion
/// also covered a rendered `_emitSnack` two hundred lines further down, which
/// stayed German through two i18n rounds. The prompt context is now listed
/// literal by literal, so a new German literal in that file is a finding.
const Map<String, List<String>> _bekannteAusnahmen = <String, List<String>>{
  'lib/src/screens/meal_analysis_screen.dart': [
    "'Kein angemeldeter Nutzer für die Trend-Ansicht.'",
  ],
  // `coachContext`/`_todaysSlotSummary`/`_todaysFoodSummary`: free-text
  // CONTEXT for the coach prompt, never rendered. The model reads German
  // context regardless of the answer language (the reply language is set by
  // the system prompt), so these lines stay German on purpose.
  'lib/src/app/home_store.dart': [
    "'Körpergewicht: \${p.weightKg} kg (Ziel \${p.targetWeightKg} kg).'",
    "'(noch \$remKcal kcal übrig).'",
    "'Makros heute noch offen: Protein \$remProt g, Kohlenhydrate \$remCarbs g, '",
    "'\$n Einträge'",
    "'Pro Mahlzeit heute: \$parts.'",
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

/// Third layer (P1-04): German FUNCTION words — the skeleton of a sentence,
/// not its subject.
///
/// The first two layers both look for the same thing in the end: a word this
/// repo happens to have written down. They missed two rendered snacks at
/// once —
///  * `'Deine Sitzung ist abgelaufen. Bitte melde dich erneut an.'` carries no
///    umlaut and none of the eight display words, and
///  * `'… Deine Daten auf dem Server sind unberuehrt — … Eintraege …'` was
///    typed in ASCII transliteration, which makes the CHARACTER filter
///    structurally blind: `ue`/`ae`/`oe` are exactly what a German text looks
///    like once someone avoids umlauts.
///
/// Function words need no umlaut and survive every transliteration, so this
/// layer is immune to the trick that beat layers 1 and 2. It is also the
/// layer that cannot be enumerated away: German prose without `der/die/ist/
/// nicht/und` does not exist, while a nouns-only list would have to grow with
/// every feature.
///
/// Matching is case-INSENSITIVE (unlike [_anzeigeWoerterOhneUmlaut], where
/// capitals do the cutting): a sentence starts with a capital, and "Deine"
/// vs "deine" is not the distinction that matters here. The cut is
/// [_satzSchwelle] instead — see there.
///
/// Words that also exist in English (`die`, `den`, `dir`, `war`, `man`, `in`,
/// `an`, `so`) stay OUT: this layer must not turn an English log line into a
/// finding.
const List<String> _deutscheSatzWoerter = <String>[
  'aber', 'auf', 'aus', 'beim', 'bereits', 'bitte', 'dein', 'deine', //
  'deinem', 'deinen', 'deiner', 'dem', 'der', 'des', 'dich', 'diese', //
  'diesem', 'diesen', 'dieser', 'dieses', 'doch', 'dort', 'du', 'ein', //
  'eine', 'einem', 'einen', 'einer', 'erneut', 'erst', 'hier', 'ihre', //
  'ist', 'jetzt', 'kann', 'kannst', 'keine', 'keinen', 'konnte', 'mit', //
  'muss', 'musst', 'musste', 'nicht', 'noch', 'nur', 'oder', 'sich', //
  'sind', 'und', 'vom', 'von', 'werden', 'wieder', 'wird', 'wirst', //
  'wurde', 'wurden', 'zum', 'zur',
];

/// How many DIFFERENT [_deutscheSatzWoerter] make a literal a German sentence.
///
/// One is too little: a single `von`/`ist` also shows up in a product name or
/// a mixed-language diagnostic. Two independent function words in one literal
/// no longer happen by accident — measured against the whole migrated tree,
/// two produces exactly the real findings and not one false positive, while
/// one additionally hits three German exception messages in
/// `coach_chat_service.dart` and the coach-context lines.
const int _satzSchwelle = 2;

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
// layer catches part of that class — see [_anzeigeWoerterOhneUmlaut] — and a
// third one the sentences neither of them sees ([_deutscheSatzWoerter]). Full
// extraction stays manual per package; this is a safety net.
//
// Diagnostics are cut out STRUCTURALLY, not per literal: everything inside a
// `dev.log(...)` call is exempt (spec §4), see [_diagnoseBereiche].
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

final List<RegExp> _satzTreffer = _deutscheSatzWoerter
    .map((wort) => RegExp('\\b$wort\\b', caseSensitive: false))
    .toList(growable: false);

// ---------------------------------------------------------------------------
// Build-time environment declarations
//
// One parse of every `*.fromEnvironment(...)` / `bool.hasEnvironment(...)` in
// `lib/`, so the rule below compares the example file against the CODE rather
// than a hardcoded list.
// ---------------------------------------------------------------------------

/// One `String.fromEnvironment` call site: the declaration name and the
/// compiled-in default (concatenated literals behind `defaultValue:`, empty
/// when the argument is absent).
class _Deklaration {
  const _Deklaration(this.name, this.standard);

  final String name;
  final String standard;
}

final RegExp _fromEnvironment =
    RegExp(r'(String|bool|int)\.fromEnvironment\(');
final RegExp _hasEnvironment = RegExp(r"bool\.hasEnvironment\(\s*'([^']+)'");

/// Text from [start] (just past the opening paren) to its matching `)`,
/// skipping over string literals so a paren inside a string cannot close the
/// argument list early. Uses the same [_literalEnde] scanner as
/// [_dartOhneKommentare], so both helpers draw the literal boundaries at the
/// same places — double quotes, `r'…'` and interpolations included.
String _bisKlammerZu(String quelle, int start) {
  var tiefe = 1;
  var i = start;
  while (i < quelle.length) {
    if (_literalBeginnt(quelle, i)) {
      i = _literalEnde(quelle, i);
      continue;
    }
    final c = quelle[i];
    if (c == '(') {
      tiefe++;
    } else if (c == ')') {
      tiefe--;
      if (tiefe == 0) return quelle.substring(start, i);
    }
    i++;
  }
  return quelle.substring(start);
}

/// Every declaration `lib/` reads, keyed by name — or, with [quellen] given,
/// every declaration in those RAW sources. The parameter exists so the
/// self-check below can feed the parser a snippet instead of the file tree,
/// comment stripping included.
Map<String, _Deklaration> _deklarationen([Iterable<String>? quellen]) {
  final gefunden = <String, _Deklaration>{};
  for (final roh in quellen ?? _libQuellen.map((q) => q.roh)) {
    final text = _dartOhneKommentare(roh);
    for (final m in _fromEnvironment.allMatches(text)) {
      final rumpf = _bisKlammerZu(text, m.end);
      final literale =
          _literal.allMatches(rumpf).map((l) => l.group(0)!).toList();
      if (literale.isEmpty) continue;
      final name = literale.first.substring(1, literale.first.length - 1);
      final standardIndex = rumpf.indexOf('defaultValue:');
      final standard = standardIndex < 0
          ? ''
          : _literal
              .allMatches(rumpf.substring(standardIndex))
              .map((l) => l.group(0)!.substring(1, l.group(0)!.length - 1))
              .join();
      gefunden[name] = _Deklaration(name, standard);
    }
    for (final m in _hasEnvironment.allMatches(text)) {
      gefunden.putIfAbsent(
          m.group(1)!, () => _Deklaration(m.group(1)!, ''));
    }
  }
  return gefunden;
}

/// All three layers for ONE literal, quotes included as [_literal] returns it.
/// Its own function so the self-check below can feed it directly instead of
/// walking the file tree.
bool _istDeutscheHartkodierung(String literalMitQuotes) {
  if (_deutschesZeichen.hasMatch(literalMitQuotes)) return true;
  final inhalt = literalMitQuotes.substring(1, literalMitQuotes.length - 1);
  if (_bezeichnerLiteral.hasMatch(inhalt)) return false;
  if (_wortTreffer.any((treffer) => treffer.hasMatch(inhalt))) return true;
  // Layer 3 asks for a SENTENCE. A single token stays out: it is a label, a
  // key or a name, and prose it is not.
  if (!inhalt.trim().contains(' ')) return false;
  var gefunden = 0;
  for (final treffer in _satzTreffer) {
    if (treffer.hasMatch(inhalt) && ++gefunden >= _satzSchwelle) return true;
  }
  return false;
}

/// Half-open char ranges of the `dev.log(...)` calls in [code].
///
/// Spec §4 exempts diagnostics: `dev.log` text never reaches a screen, and
/// `dart:developer` never leaves the device. Listing those sentences one by
/// one in [_bekannteAusnahmen] would fill a deny list — meant for real
/// UI-adjacent decisions — with text nobody ever reads, and a deny list nobody
/// can survey stops being read at all. So diagnostics are cut by CALL.
///
/// [_bisKlammerZu] counts parens string-aware, which this needs:
/// `dev.log('(noch 3 kcal)')` would otherwise close the call inside its own
/// message.
List<({int von, int bis})> _diagnoseBereiche(String code) => _devLog
    .allMatches(code)
    .map((m) => (von: m.start, bis: m.end + _bisKlammerZu(code, m.end).length))
    .toList(growable: false);

final RegExp _devLog = RegExp(r'\bdev\.log\(');

/// All findings of one source file, formatted as `path: literal`. [ausnahmen]
/// is the [_bekannteAusnahmen] entry and covers ALL THREE layers.
List<String> _fundeIn(String relativ, String quelle, List<String> ausnahmen) {
  final code = _dartOhneKommentare(quelle);
  final diagnose = _diagnoseBereiche(code);
  final funde = <String>[];
  for (final match in _literal.allMatches(code)) {
    final text = match.group(0)!;
    if (ausnahmen.contains(text)) continue;
    if (diagnose.any((b) => b.von <= match.start && match.end <= b.bis)) {
      continue;
    }
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
      //
      // T12: two of the three needles used to be LITERAL, and both named the
      // variable `context`. `Theme.of(ctx).brightness` — the spelling of every
      // `builder: (ctx, _) =>` callback — walked straight through. The needle
      // is the CALL now, not one way of spelling its argument.
      final treffer = <String>[];
      for (final quelle in _libQuellen) {
        if (quelle.pfad.startsWith('lib/src/theme/')) continue;
        for (final zeile in quelle.ohneKommentare.split('\n')) {
          if (_helligkeitsAbzweig.hasMatch(zeile)) {
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

    test('die Brightness-Regel haengt nicht am Bezeichner `context`', () {
      // Without this the rule above proves only that nobody writes the ONE
      // spelling it used to know. Every line here is the same branch.
      for (final abzweig in const <String>[
        'final dark = Theme.of(context).brightness == Brightness.dark;',
        'final dark = Theme.of(ctx).brightness == Brightness.dark;',
        'if (Theme.of(c).brightness == Brightness.dark) return AppTokens.dark;',
        'final b = MediaQuery.of(ctx).platformBrightness;',
        'final b = MediaQuery.platformBrightnessOf(ctx);',
        'final b = View.of(context).platformDispatcher.platformBrightness;',
      ]) {
        expect(_helligkeitsAbzweig.hasMatch(abzweig), isTrue, reason: abzweig);
      }
      // And what must stay quiet — including the token lookup the whole rule
      // exists to steer people towards.
      for (final ok in const <String>[
        'final t = context.t;',
        'return AppTokens.dark;',
        'Brightness get brightness => Brightness.light;',
        'const Color scrim = Color(0x66000000);',
      ]) {
        expect(_helligkeitsAbzweig.hasMatch(ok), isFalse, reason: ok);
      }
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
  // A11y — jump marks (review 2026-08-29, P9-06d)
  //
  // P9-06 gave the shared widgets a heading each; P9-06b/c found six titles
  // that had drifted away from them — two with a hand-written
  // `Semantics(header: true)` and no rank, four with nothing at all. Both
  // halves matter: `header` is the trait TalkBack and VoiceOver navigate by,
  // `headingLevel` is the rank (aria-level on web, isHeading on Android), and
  // a hand-written annotation reliably carries only one of them.
  //
  // The rule is deliberately narrow: it names the two HEADING properties, not
  // `Semantics` as such. `Semantics(button: true, label: ...)`,
  // `ExcludeSemantics`, `MergeSemantics` and every other annotation stay
  // untouched — those are not titles and have nothing to do with this.
  // =========================================================================
  group('Ueberschriften kommen aus HeadingSemantics', () {
    test('niemand setzt header:/headingLevel: von Hand (Allowlist mit '
        'Begruendung)', () {
      final treffer = <String>[];
      for (final quelle in _libQuellen) {
        if (_eigeneUeberschriftErlaubt.containsKey(quelle.pfad)) continue;
        treffer.addAll(_eigeneUeberschriftFunde(quelle.pfad, quelle.roh));
      }
      expect(
        treffer,
        isEmpty,
        reason: 'Ein Seitentitel wird mit HeadingSemantics(level: …) '
            'ausgezeichnet (lib/src/widgets/design/surfaces.dart, ueber das '
            'design.dart-Barrel). Von Hand gesetzt fehlt regelmaessig die '
            'zweite Haelfte: header ohne Rang (Android/Web kennen die Ebene '
            'nicht) oder Rang ohne header (iOS findet die Marke gar '
            'nicht):\n${treffer.join('\n')}',
      );
      // The allowlist must not outlive its files.
      for (final pfad in _eigeneUeberschriftErlaubt.keys) {
        expect(File(pfad).existsSync(), isTrue, reason: '$pfad fehlt');
      }
    });

    test('die Regel haette genau den alten Zustand gefangen', () {
      // Verbatim from eatova_home_page.dart and favorites_sheet.dart before
      // P9-06b — restated here so the self-check does not depend on those
      // files having kept the shape.
      const alt = '''
Semantics(
  header: true,
  child: Text(l10n.commonBootUnansweredTitle),
),
''';
      expect(_eigeneUeberschriftFunde('probe.dart', alt), hasLength(1));
      // The other half of the defect: a rank without the trait.
      const nurRang = 'Semantics(headingLevel: 1, child: Text(titel)),';
      expect(_eigeneUeberschriftFunde('probe.dart', nurRang), hasLength(1));
    });

    test('die Regel laesst Nicht-Titel-Semantics und Kommentare in Ruhe', () {
      // Everything `Semantics` is legitimately used for elsewhere in this
      // repo, plus the shared widget's own call site.
      const harmlos = '''
// `header: true` waere hier falsch — reiner Erklaertext
/// Streak pill in the header: lime dot plus day count.
Semantics(button: true, label: l10n.todaySemanticsOpenProfile, child: tile),
Semantics(container: true, liveRegion: true, child: Text(status)),
ExcludeSemantics(child: handle),
MergeSemantics(child: row),
HeadingSemantics(level: 1, child: Text(titel)),
''';
      expect(_eigeneUeberschriftFunde('probe.dart', harmlos), isEmpty);
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
            '(Umlaut/ß/„, ein Wort aus _anzeigeWoerterOhneUmlaut oder '
            '$_satzSchwelle Funktionswoerter aus _deutscheSatzWoerter) unter '
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

    test(
        'die Satz-Lage sieht die zwei Snacks, an denen Zeichenfilter UND '
        'Wortliste vorbeiliefen (P1-04)', () {
      // The literals as auth_gate.dart and home_store.dart really carried them
      // — restated here so the self-check survives their localisation.
      //
      // The second one is the interesting case: it was typed in ASCII
      // transliteration ("unberuehrt", "Eintraege"), and that is precisely
      // what German prose looks like once someone avoids umlauts. A guard that
      // only knows umlauts is blind to exactly the texts written by people who
      // avoid umlauts.
      const uebersehen = <String>[
        "'Deine Sitzung ist abgelaufen. Bitte melde dich erneut an.'",
        "'Der Offline-Speicher musste neu angelegt werden. Deine Daten auf dem '",
        "'Server sind unberuehrt — nur noch nicht synchronisierte Eintraege '",
      ];
      for (final probe in uebersehen) {
        expect(_istDeutscheHartkodierung(probe), isTrue, reason: probe);
        expect(_deutschesZeichen.hasMatch(probe), isFalse,
            reason: 'sonst haette Lage 1 gereicht und die Probe taugt nicht: '
                '$probe');
        expect(_wortTreffer.any((t) => t.hasMatch(probe)), isFalse,
            reason: 'sonst haette Lage 2 gereicht und die Probe taugt nicht: '
                '$probe');
      }
    });

    test('die Satz-Lage braucht einen SATZ, kein einzelnes Funktionswort', () {
      // The threshold is the whole point: one `von`/`ist` also shows up in a
      // product name or a mixed-language diagnostic.
      const einzeln = <String>[
        "'Kein Nutzer'", // no word from the list at all
        "'ist'", // one word, and not even a sentence
        "'Der'",
        "'Protein von Alpro'", // one word inside a product line
      ];
      for (final probe in einzeln) {
        expect(_istDeutscheHartkodierung(probe), isFalse, reason: probe);
      }
      // Counter-check, so the threshold cannot go silently unreachable: two
      // function words in one literal ARE a finding.
      expect(_istDeutscheHartkodierung("'Protein von der Alpro-Reihe'"), isTrue);
    });

    test('die Satz-Lage laesst Englisch und Bezeichner in Ruhe', () {
      const durchgelassen = <String>[
        "'Meal updated.'",
        "'No signed-in user for the trend view.'",
        "'the meal was updated and is now in the outbox'",
        "'assets/images/onboarding.png'",
        "'food-heute-strip'",
        "'Content-Type'",
      ];
      for (final probe in durchgelassen) {
        expect(_istDeutscheHartkodierung(probe), isFalse, reason: probe);
      }
    });

    test('dev.log-Texte sind Diagnose, der Aufruf daneben aber nicht', () {
      // Spec §4: log text never reaches a screen. The paren counting has to be
      // string-aware, or the `)` inside the message would end the call early
      // and the following line would silently drop out of the scan too.
      const quelle = '''
void f() {
  dev.log(
      'Boot-Budget aufgebraucht — die App wird ohne '
      'Server-Antwort angezeigt (noch nicht fertig), der Boot laeuft weiter',
      name: 'eatova_sync');
  _emitSnack('Der Speicher wurde neu angelegt und ist jetzt leer.');
}
''';
      expect(
        _fundeIn('probe.dart', quelle, const <String>[]),
        <String>[
          "probe.dart: 'Der Speicher wurde neu angelegt und ist jetzt leer.'",
        ],
      );
    });

    test('ein https:// im Literal schneidet den Rest der Zeile nicht weg '
        '(P10-03b)', () {
      // Second victim of the comment stripper: it feeds THIS rule too. Cutting
      // the line at the `//` inside the URL dropped everything behind it out
      // of the scan — here the German snack text on the very same line.
      const quelle = '''
void f() {
  _oeffne('https://eatova.de/agb', 'Die Mahlzeit wurde gespeichert.');
}
''';
      expect(
        _fundeIn('probe.dart', quelle, const <String>[]),
        <String>[
          "probe.dart: 'Die Mahlzeit wurde gespeichert.'",
        ],
      );
    });

    test('ein doppelt gequotetes dev.log mit Apostroph dehnt die Ausnahme '
        'nicht aus (P10-03b)', () {
      // The dangerous half: the `dev.log(...)` range is an EXEMPTION. When the
      // paren counting only knew single quotes, the apostrophe in a
      // DOUBLE-quoted message opened a literal that ran to the next quote in
      // the file — the exempt range grew over the following code and swallowed
      // real findings without a word. Measured today: the 141 `dev.log` ranges
      // in lib/ span at most seven lines, so nothing is triggered yet; one
      // `"it's"` in a log line is enough to tip it.
      const quelle = '''
void f() {
  dev.log("cache miss, it's cold", name: 'eatova_sync');
  _emitSnack('Die Mahlzeit wurde gespeichert.');
}
''';
      expect(
        _fundeIn('probe.dart', quelle, const <String>[]),
        <String>[
          "probe.dart: 'Die Mahlzeit wurde gespeichert.'",
        ],
      );
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

    // -----------------------------------------------------------------------
    // recipesSubtitle darf keine echten Fotos behaupten
    //
    // Every one of the 30 catalog images in `assets/recipes/` is AI-generated
    // and carries a burnt-in "AI Generated" badge in its bottom right corner —
    // verified image by image. The imprint on eatova.de declares them as such.
    // The subtitle used to read "Clean Meals mit echten Bildern …" /
    // "… with real photos …", so the user read "real photos" one line above a
    // grid of pictures each stamped "AI Generated", and the app contradicted
    // its own imprint.
    //
    // The rule is about the CLAIM, not about one wording: an image word with a
    // reality word next to it. That way "echte Fotos", "reale Aufnahmen" and
    // "realistic images" fall over too, while "KI-Bildern und fertigen
    // Tracker-Werten" passes — the values really are real, only the pictures
    // are not.
    // -----------------------------------------------------------------------
    test('recipesSubtitle behauptet in keiner Sprache echte Fotos', () {
      final treffer = <String>[];
      for (final pfad in const <String>[
        'lib/l10n/app_de.arb',
        'lib/l10n/app_en.arb',
      ]) {
        final wert =
            (jsonDecode(_lies(pfad)) as Map<String, dynamic>)['recipesSubtitle']
                as String?;
        expect(wert, isNotNull, reason: '$pfad kennt recipesSubtitle nicht');
        final grund = _echtheitsBehauptung(wert!);
        if (grund != null) treffer.add('$pfad: "$wert" — $grund');
      }
      expect(
        treffer,
        isEmpty,
        reason: 'Die Katalogbilder sind KI-generiert und tragen ein '
            'eingebranntes "AI Generated"-Abzeichen; das Impressum sagt das '
            'auch. Die Unterzeile darf ihnen nicht widersprechen:\n'
            '${treffer.join('\n')}',
      );
    });

    test('die Regel haette genau den alten Zustand gefangen', () {
      // The two texts that stood here until 2026-09-01, verbatim.
      expect(
        _echtheitsBehauptung('Clean Meals mit echten Bildern und '
            'Tracker-Werten.'),
        isNotNull,
      );
      expect(
        _echtheitsBehauptung('Clean meals with real photos and tracked '
            'macros.'),
        isNotNull,
      );
      // And the wordings a careless rewrite would reach for next.
      for (final rueckfall in const <String>[
        'Clean Meals mit echten Fotos.',
        'Clean Meals mit realen Aufnahmen und Werten.',
        'Clean meals, real images included.',
        'Clean meals with realistic photos.',
      ]) {
        expect(_echtheitsBehauptung(rueckfall), isNotNull,
            reason: 'unerkannt: $rueckfall');
      }
    });

    test('die Regel laesst die ehrliche Fassung und echte WERTE in Ruhe', () {
      // The live texts, plus the trap the rule must NOT fall into: "echt" is
      // allowed as long as it is not sitting next to a picture — the tracker
      // values are real.
      for (final ok in const <String>[
        'Clean Meals mit KI-Bildern und fertigen Tracker-Werten.',
        'Clean meals with AI images and macros ready to track.',
        'Clean Meals mit KI-Bildern und echten Tracker-Werten.',
        'Clean meals with AI images and real macros from the database.',
      ]) {
        expect(_echtheitsBehauptung(ok), isNull, reason: 'Fehlalarm: $ok');
      }
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

  // =========================================================================
  // dart_defines.example.json — an empty value is NOT "unset" (P10-03)
  //
  // README tells everyone to copy this file, so every key in it ships in the
  // builds people make from the repo. `String.fromEnvironment` takes its
  // `defaultValue` only when the declaration is UNDEFINED; a key present with
  // '' defines it as the empty string and wipes the compiled-in default.
  // Measured with the SDK: no define -> the 64-char key, `--define=
  // OFF_MIRROR_SEARCH_KEY=` -> length 0. That is why the example file must
  // never carry a documentation-only entry for a declaration that HAS a
  // default — the mirror search would silently degrade to the public Open
  // Food Facts search, which still returns plausible results.
  // =========================================================================
  group('dart_defines.example.json', () {
    late Map<String, dynamic> beispiel;
    late Map<String, _Deklaration> deklarationen;

    setUpAll(() {
      beispiel =
          jsonDecode(_lies('dart_defines.example.json')) as Map<String, dynamic>;
      deklarationen = _deklarationen();
    });

    test('die Datei ist eine flache Map aus Strings', () {
      // `--dart-define-from-file` turns every entry into one -D NAME=VALUE.
      for (final eintrag in beispiel.entries) {
        expect(eintrag.value, isA<String>(), reason: eintrag.key);
      }
      expect(deklarationen.keys, contains('SUPABASE_URL'),
          reason: 'sonst hat der Scanner nichts gefunden und die Regel unten '
              'ist blind');
    });

    test('kein Schluessel mit leerem Wert loescht einen kompilierten Standard',
        () {
      final funde = <String>[];
      for (final eintrag in beispiel.entries) {
        if (eintrag.key.startsWith('_')) continue; // documentation entry
        final wert = eintrag.value as String;
        if (wert.trim().isNotEmpty) continue;
        final standard = deklarationen[eintrag.key]?.standard ?? '';
        if (standard.trim().isNotEmpty) {
          funde.add('${eintrag.key}: "" ueberschreibt den Standard '
              '"${standard.substring(0, standard.length.clamp(0, 12))}…"');
        }
      }
      expect(funde, isEmpty,
          reason: 'Wer die Datei laut README kopiert, baut damit eine App '
              'OHNE diese Werte. Entweder einen echten Wert eintragen oder '
              'den Schluessel weglassen (und im _README-Eintrag '
              'dokumentieren):\n${funde.join('\n')}');
    });

    test('jeder Schluessel wird von lib/ ueberhaupt gelesen', () {
      // The other direction: a key nobody reads is dead documentation, and a
      // renamed declaration would leave exactly that behind.
      final unbekannt = beispiel.keys
          .where((k) => !k.startsWith('_'))
          .where((k) => !deklarationen.containsKey(k))
          .toList();
      expect(unbekannt, isEmpty,
          reason: 'Diese Schluessel liest kein String.fromEnvironment in '
              'lib/:\n${unbekannt.join('\n')}');
    });

    test('der Scanner erkennt Standard und Nicht-Standard auseinander', () {
      // Self-check: without it the rule above would go green on a broken
      // parse. Both forms occur in lib/ today.
      expect(deklarationen['OFF_MIRROR_SEARCH_KEY']?.standard, isNotNull,
          reason: 'OFF_MIRROR_SEARCH_KEY nicht gefunden');
      expect(deklarationen['OFF_MIRROR_SEARCH_KEY']!.standard, isNotEmpty,
          reason: 'der eincompilierte Suchschluessel ist der Standard, um den '
              'es geht');
      expect(deklarationen['SENTRY_DSN']?.standard, '',
          reason: 'SENTRY_DSN hat bewusst keinen Standard — deshalb darf es '
              'als "" in der Beispieldatei stehen');
    });

    test('ein URL-Standard wird ganz gelesen, nicht bis zum // (P10-03b)', () {
      // The assertion that nails the defect: `OFF_MIRROR_URL` is the one
      // declaration whose default CONTAINS a `//`. The old comment stripper
      // cut the line there, so the scanner read `https:` and ran on into the
      // next declaration. `OFF_MIRROR_SEARCH_KEY` above cannot see this — its
      // default carries no slash.
      expect(deklarationen['OFF_MIRROR_URL']?.standard,
          'https://eatova.de/meili',
          reason: 'der Standard muss VOLLSTAENDIG gelesen werden, sonst ist '
              'das Urteil der Regel oben Zufall');
      expect(deklarationen['SUPABASE_URL']?.standard,
          startsWith('https://'),
          reason: 'zweiter URL-Standard, gleiche Falle');
    });

    test('der Parser haengt nicht an der Nachbardeklaration (P10-03b)', () {
      // The probe that showed the blind spot, kept as a permanent test: a
      // declaration with a URL default standing LAST in its file. That is the
      // case where the broken parse produced the EMPTY string — and an empty
      // default is exactly what makes the rule above wave a key through.
      const letzte = '''
class Probe {
  static const String url = String.fromEnvironment(
    'PROBE_URL',
    defaultValue: 'https://example.invalid/probe',
  );
}
''';
      expect(_deklarationen(<String>[letzte])['PROBE_URL']?.standard,
          'https://example.invalid/probe');

      // Same declaration on ONE line, so the fix does not depend on the line
      // break between name and default.
      const einzeiler =
          "const u = String.fromEnvironment('PROBE_URL', defaultValue: "
          "'https://example.invalid/probe');";
      expect(_deklarationen(<String>[einzeiler])['PROBE_URL']?.standard,
          'https://example.invalid/probe');

      // Counter-check, so the two assertions above cannot pass on a parser
      // that simply reports every default: no `defaultValue:` stays empty.
      const ohne = "const u = String.fromEnvironment('PROBE_URL');";
      expect(_deklarationen(<String>[ohne])['PROBE_URL']?.standard, '');
    });
  });
}
