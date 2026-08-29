// ---------------------------------------------------------------------------
// P9-02c — SOURCE RULE for the app-wide selection language.
//
// The language moved from `forest`/`onForest` to [SelectionTone]
// (`ink`/`bg`, lib/src/widgets/design/controls.dart) because `forest` is
// itself a dark SURFACE in the dark palette: as a selection fill it measured
// 1.3349:1 against `surf`, 1.1008:1 against the `tile` track, and the two
// labels 1.0440:1 against each other — far under the 3:1 WCAG 2.1 / 1.4.11
// asks of the visual information that identifies a control's state.
//
// The move was incomplete: `SegmentedPill`, `FilterChipPill`,
// `_SettingsChoicePill`, `chipTheme`, `datePickerTheme` and `_FoodQuickChip`
// carried it, while FOUR live controls kept painting `forest` — the food tab's
// date strip, its calendar button, the same chips in the edit sheet, and the
// onboarding cards. Nothing noticed, because no rule existed. This is that
// rule.
//
// WHAT IT FORBIDS: `forest` / `onForest` in a CONDITIONAL — the shape
// `<condition> ? t.forest : …` (and the mirrored `… : t.forest`), i.e. a
// colour that depends on a state. A state is exactly what these two tokens
// cannot carry in both palettes.
//
// WHAT STAYS ALLOWED: static `t.forest` without a condition. `forest` keeps
// every job it has as a brand SURFACE — the kcal tile and the profile badge in
// the food tab, the onboarding intro badge and hero, the today hero, the
// snackbar, the welcome screen. Those are not state indicators.
//
// The rule reads SOURCE TEXT. It is deliberately NOT in
// test/repo_rules_test.dart: it belongs next to the contrast assertions in
// auswahl_sprache_verwendung_test.dart, which prove the same claim on mounted
// widgets. Source rule and usage test are the two halves of one guard.
// ---------------------------------------------------------------------------

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// --- the tree walk ----------------------------------------------------------

/// One Dart source under `lib/`: path with `/` and the RAW text.
///
/// Raw on purpose — [_funde] folds it itself. Folding here and folding again
/// there would run the comment stripper over a file that is one single line by
/// then, and the first `//` inside a string literal (a URL) would swallow
/// everything after it.
class _Quelle {
  _Quelle(this.pfad, this.roh);

  final String pfad;
  final String roh;
}

/// Source without comments, else an explanatory comment would trip the scan.
String _ohneKommentare(String quelle) => quelle
    .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
    .split('\n')
    .map((z) {
      final i = z.indexOf('//');
      return i < 0 ? z : z.substring(0, i);
    })
    .join('\n');

/// Comments out, every whitespace run collapsed to one blank. dartfmt breaks
/// `cond ? a : b` across three lines as soon as it is long enough; without
/// this fold a line-wise scan would see `? t.forest` but never
/// `? t.surf : t.forest`.
String _gefaltet(String roh) =>
    _ohneKommentare(roh).replaceAll(RegExp(r'\s+'), ' ');

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

// --- the rule ---------------------------------------------------------------

/// THEN branch: `<condition> ? t.forest` / `? context.t.onForest`.
///
/// The negative lookbehind and lookahead keep `farbe ?? t.onForest` out — a
/// null fallback is not a condition, and `today_hero.dart`,
/// `meters.dart`, `eatova_wordmark.dart` and `app_snack.dart` all use it for
/// a default that is a plain surface colour.
final RegExp _dannZweig =
    RegExp(r'(?<!\?)\?\s*(?!\?)(?:context\.)?t\.(forest|onForest)\b');

/// ELSE branch: `<condition> ? <something> : t.forest`.
///
/// The middle is barred from `, ; ? :` so the match cannot jump across a
/// statement or an unrelated argument — `a ?? b, color: t.forest` stays clean.
final RegExp _sonstZweig = RegExp(
  r'\?\s*(?!\?)[^,;?:]{1,60}:\s*(?:context\.)?t\.(forest|onForest)\b',
);

/// Findings for ONE source. Own function so the self-checks below can feed it
/// a snippet instead of walking the tree.
List<String> _funde(String pfad, String roh) {
  final text = _gefaltet(roh);
  final treffer = <String>[];
  for (final muster in <RegExp>[_dannZweig, _sonstZweig]) {
    for (final m in muster.allMatches(text)) {
      // Enough context to recognise the call site in the failure message.
      final von = (m.start - 45).clamp(0, text.length);
      final bis = (m.end + 20).clamp(0, text.length);
      treffer.add('$pfad: …${text.substring(von, bis).trim()}…');
    }
  }
  return treffer;
}

/// Files that may name `forest`/`onForest` in a condition, each with its
/// reason. Every entry is checked against its file below: it must exist AND
/// still contain a match, so a stale exception cannot outlive its code.
///
/// The bar for a new entry: the condition must NOT be a selection state, and
/// the state must be carried by something other than these two tokens.
const Map<String, String> _bedingtesForestErlaubt = <String, String>{
  'lib/src/widgets/design/controls.dart':
      'AppToggle track: not a selection, and the state is carried by the KNOB '
          '(position left/right plus lime/surf with an ink2 ring at 3.3-3.5:1 '
          'against the track) — the track is decoration, documented in place',
  'lib/src/screens/coach/coach_composer.dart':
      'send button ENABLED vs. disabled — WCAG 1.4.11 exempts inactive '
          'components, and the button is the only element of its own capsule, '
          'so nothing sits next to it that could be confused with it',
  'lib/src/screens/coach/coach_message_list.dart':
      'chat bubble by AUTHOR, not by selection: who wrote a message is also '
          'carried by side (left/right alignment) and by the tail radius, and '
          'the two bubbles never touch',
  'lib/src/screens/recipes/recipe_atoms.dart':
      '_RecipeBadge(filled:) and the onImage flag are STYLE variants fixed at '
          'the call site (marker on a photo vs. hint on a card), never a state '
          'the same widget switches between',
  'lib/src/screens/today/today_hero.dart':
      'over/under budget: both branches are text ON the forest hero, so '
          'neither is a fill — the signal is carried by lime plus the changed '
          'wording, and `danger` is illegible on forest in light mode',
  'lib/src/widgets/profile/profile_widgets_hero.dart':
      'solid vs. soft pill: a STYLE variant of the hero chips fixed at the '
          'call site, not a state the widget toggles',
};

void main() {
  late List<_Quelle> libQuellen;

  setUpAll(() {
    libQuellen = _leseLib();
  });

  group('Auswahlzustaende nutzen SelectionTone, nicht forest/onForest', () {
    test('kein bedingtes t.forest/t.onForest in lib/ (Allowlist mit '
        'Begruendung)', () {
      final treffer = <String>[];
      for (final quelle in libQuellen) {
        if (_bedingtesForestErlaubt.containsKey(quelle.pfad)) continue;
        treffer.addAll(_funde(quelle.pfad, quelle.roh));
      }
      expect(
        treffer,
        isEmpty,
        reason: 'Eine Farbe, die von einer Bedingung abhaengt, ist ein '
            'ZUSTAND — und `forest`/`onForest` koennen ihn nicht tragen: im '
            'Dunkelmodus ist `forest` selbst eine dunkle Flaeche (1,3349:1 '
            'gegen surf, 1,1008:1 gegen die tile-Spur, 1,0440:1 zwischen den '
            'beiden Beschriftungen). Die App-Sprache dafuer ist '
            '`SelectionTone` aus lib/src/widgets/design/controls.dart: '
            'Fuellung `t.selectedFill`, Beschriftung `t.onSelected` '
            '(16,78:1 hell / 14,92:1 dunkel gegen surf). Statisches '
            '`t.forest` ohne Bedingung bleibt erlaubt:\n'
            '${treffer.join('\n')}',
      );
    });

    test('die Allowlist wird gegen ihre Dateien geprueft', () {
      for (final eintrag in _bedingtesForestErlaubt.entries) {
        final datei = File(eintrag.key);
        expect(
          datei.existsSync(),
          isTrue,
          reason: '${eintrag.key} fehlt — Eintrag loeschen',
        );
        // A stale exception is worse than none: it silently covers whatever
        // moves into that file next.
        expect(
          _funde(eintrag.key, datei.readAsStringSync()),
          isNotEmpty,
          reason: '${eintrag.key} braucht die Ausnahme nicht mehr '
              '(kein bedingtes forest/onForest im Code) — Eintrag loeschen. '
              'Begruendung war: ${eintrag.value}',
        );
        expect(
          eintrag.value.length,
          greaterThan(40),
          reason: '${eintrag.key}: eine Ausnahme braucht eine Begruendung',
        );
      }
    });

    test('die vier reparierten Stellen tragen SelectionTone', () {
      // Positive counterpart to the ban: the rule going green because the
      // code no longer paints ANY selection would be worthless.
      const stellen = <String, int>{
        'lib/src/screens/meal_analysis_screen.dart': 4, // Chip + Kalenderknopf
        'lib/src/widgets/kcal/edit_meal_sheet.dart': 1, // Tages-Chips
        'lib/src/screens/onboarding_screen.dart': 2, // _TileCard + _RowCard
      };
      stellen.forEach((pfad, mindestens) {
        final text = _gefaltet(File(pfad).readAsStringSync());
        expect(
          RegExp(r'\?\s*t\.selectedFill\b').allMatches(text).length,
          greaterThanOrEqualTo(mindestens),
          reason: '$pfad malt seine Auswahl nicht mehr mit t.selectedFill',
        );
        expect(
          text.contains('t.onSelected'),
          isTrue,
          reason: '$pfad beschriftet seine Auswahl nicht mit t.onSelected',
        );
      });
    });
  });

  group('Selbstpruefung der Regel', () {
    test('sie haette genau den alten Zustand gefangen', () {
      // Verbatim from the four sites before the fix — restated here so the
      // self-check does not depend on those files having kept their shape.
      const dateChip = '''
decoration: BoxDecoration(
  color: selected ? t.forest : t.surf,
  borderRadius: BorderRadius.circular(rChip),
  border: Border.all(color: selected ? Colors.transparent : t.line),
),
''';
      expect(_funde('probe.dart', dateChip), hasLength(1));

      const datumsZahl = '''
style: AppType.display(
  11.5,
  weight: FontWeight.w700,
  color: selected ? t.onForest : t.ink,
),
''';
      expect(_funde('probe.dart', datumsZahl), hasLength(1));

      // The onboarding row card: fill AND border in one decoration.
      const rowCard = '''
decoration: BoxDecoration(
  color: selected ? t.forest : t.surf,
  borderRadius: BorderRadius.circular(rCard),
  border: Border.all(color: selected ? t.forest : t.line),
),
''';
      expect(_funde('probe.dart', rowCard), hasLength(2));

      // dartfmt breaks a long ternary across three lines — the fold is what
      // makes that finding survive.
      const umgebrochen = '''
color: value == sex
    ? t.onForest
    : t.ink2,
''';
      expect(_funde('probe.dart', umgebrochen), hasLength(1));

      // And the mirrored shape nobody wrote yet, but which is the same defect.
      const sonstZweig = 'color: filled ? t.surf : t.forest,';
      expect(_funde('probe.dart', sonstZweig), hasLength(1));
    });

    test('sie laesst unbedenkliche Muster in Ruhe', () {
      // Everything `forest` legitimately does in this repo.
      const harmlos = '''
// color: selected ? t.forest : t.surf — so stand es vor P9-02c
/// Selected used to be `forest` with `onForest`.
Container(decoration: BoxDecoration(color: t.forest)),
Text(label, style: AppType.ui(12, color: t.onForest)),
final ground = snackTheme.backgroundColor ?? context.t.forest;
final onGround = snackTheme.contentTextStyle?.color ?? context.t.onForest;
color: trackColor ?? t.onForest.withValues(alpha: 0.20),
color: textColor ?? t.onForest,
color: selected ? t.selectedFill : t.surf,
color: selected ? t.onSelected : t.ink,
color: active ? t.lime : Colors.transparent,
color: t.onForest.withValues(alpha: 0.07),
''';
      expect(_funde('probe.dart', harmlos), isEmpty);
    });

    test('sie springt nicht ueber eine Anweisung hinweg', () {
      // The trap of a naive `: t.forest` rule: an unrelated ternary earlier in
      // the line and a STATIC forest later.
      const gemischt = 'final x = a ? b : c; Container(color: t.forest),';
      expect(_funde('probe.dart', gemischt), isEmpty);
    });

    test('die Regel findet ueberhaupt etwas (kein toter Scanner)', () {
      // Guard against the rule silently matching nothing at all — e.g. after
      // a token rename. The allowlist entries are the live proof.
      final gefunden = <String>[];
      for (final pfad in _bedingtesForestErlaubt.keys) {
        gefunden.addAll(_funde(pfad, File(pfad).readAsStringSync()));
      }
      expect(gefunden, isNotEmpty);
    });
  });
}
