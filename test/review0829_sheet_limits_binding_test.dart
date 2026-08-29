// P8-02c — the adjust sheet's input bounds belong to the MODEL, not to the
// sheet.
//
// `_postenMinG`, `_postenMaxG`, `_postenMaxKcal` and `_makroMaxG` in
// lib/src/widgets/meal/meal_widgets_adjust.dart used to be hand-copied
// literals (1 / 10000 / 10000 / 1000), tied to `LoggedMealLimits` and
// `PlausibilityLimits` by nothing but a doc comment. They agreed — but a
// surface that knows a DIFFERENT number than the clamp behind it is exactly
// how the third silent bend came about that P8-02b had to close: the field let
// a value through, `adjustedToGrams` quietly folded it onto the model bound
// and the meal was saved with a number nobody typed.
//
// The literals are gone (the sheet takes the bounds from `model_limits.dart`
// now), and this suite keeps them gone in both directions:
//
//   1. SOURCE: every one of the four declarations must still be a REFERENCE
//      into the model — and into the RIGHT member. A number pasted back in
//      turns this red and says which constant it was.
//   2. BEHAVIOUR: the sheet must really accept the model bound and really
//      reject bound + 1 — including the one derivative that stays a number of
//      its own, the digit budget of the input fields
//      (`LengthLimitingTextInputFormatter`). Raising a bound past five digits
//      makes the field unable to hold its own maximum; that is the drift the
//      source rule cannot see, so it is measured on the running widget.
//
// The extraction follows the rule for `MAX_INPUT_CHARS` / `MAX_INPUT_BYTES` in
// repo_rules_test.dart: read the number where it lives, never transcribe it.
// It stays out of that file for the reason its own header names — this pins
// ONE pair of files against each other and needs a mounted widget, not a tree
// walk over `lib/`.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/meal_component.dart';
import 'package:eatova/src/models/model_limits.dart';
import 'package:eatova/src/widgets/meal/meal_widgets.dart';

import 'support/harness.dart' hide testWidgetsRobust;

// ---------------------------------------------------------------------------
// Layer 1 — the source rule
// ---------------------------------------------------------------------------

const String _sheetPfad = 'lib/src/widgets/meal/meal_widgets_adjust.dart';
const String _bibliothekPfad = 'lib/src/widgets/meal/meal_widgets.dart';

/// Every bound the sheet uses, mapped to the model member it MUST be taken
/// from. Naming the member (not the number) is the whole point: a wrong but
/// numerically equal binding — `_postenMaxKcal = estimatedGMax` — is still a
/// bug, and today all three happen to be 10000.
const Map<String, String> _erwarteteBindung = <String, String>{
  '_postenMinG': 'PlausibilityLimits.portionGramsMin',
  '_postenMaxG': 'PlausibilityLimits.portionGramsMax',
  '_postenMaxKcal': 'LoggedMealLimits.caloriesKcalMax',
  '_makroMaxG': 'LoggedMealLimits.macroGMax',
};

/// The members above with their real values — so "is a reference" can be
/// upgraded to "is a reference AND resolves to the number the sheet shows".
const Map<String, num> _modellWerte = <String, num>{
  'PlausibilityLimits.portionGramsMin': PlausibilityLimits.portionGramsMin,
  'PlausibilityLimits.portionGramsMax': PlausibilityLimits.portionGramsMax,
  'LoggedMealLimits.caloriesKcalMax': LoggedMealLimits.caloriesKcalMax,
  'LoggedMealLimits.macroGMax': LoggedMealLimits.macroGMax,
};

String _lies(String pfad) {
  final datei = File(pfad);
  if (!datei.existsSync()) {
    fail('$pfad fehlt (aufgeloest von ${Directory.current.path})');
  }
  return datei.readAsStringSync();
}

/// Right-hand side of `const <typ> <name> = …;` in [quelle], trimmed.
String _rechteSeite(String quelle, String name) {
  final treffer = RegExp(
    'const\\s+(?:int|double|num)\\s+$name\\s*=\\s*([^;]+);',
  ).firstMatch(quelle);
  expect(
    treffer,
    isNotNull,
    reason:
        'Die Deklaration `const … $name = …;` steht nicht mehr in $_sheetPfad. '
        'Ohne sie ist diese Regel blind — Deklaration umbenannt? Dann hier '
        'nachziehen, NICHT die Zahl abschreiben.',
  );
  return treffer!.group(1)!.trim();
}

// ---------------------------------------------------------------------------
// Layer 2 — the running sheet
// ---------------------------------------------------------------------------

/// Viewport pinning plus overflow tolerance, as in the other sheet suites.
void testWidgetsRobust(String description, WidgetTesterCallback callback) {
  testWidgets(description, (tester) async {
    tester.view.physicalSize = const Size(1179, 2556);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final prior = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exception.toString().contains('overflowed')) return;
      prior?.call(details);
    };
    addTearDown(() => FlutterError.onError = prior);

    await callback(tester);
  });
}

/// One component with a consistent density, so nothing in the sheet depends on
/// the numbers this suite types.
const _einPosten = MealAnalysisResult(
  mealName: 'Nussmus',
  caloriesKcal: 521,
  estimatedGrams: 100,
  kcalPer100G: 521,
  protein: '20 g',
  carbs: '12 g',
  fat: '45 g',
  confidence: 'Mittel',
  portionNotes: 'Testposten.',
  sourceLabel: 'Foto-KI',
  items: [
    MealComponent(
      name: 'Nussmus',
      grams: 100,
      caloriesKcal: 521,
      kcalPer100G: 521,
    ),
  ],
);

Widget _host() => localizedApp(
  Builder(
    builder: (context) => TextButton(
      key: const ValueKey('open-adjust'),
      onPressed: () async {
        await showWeightAdjustmentSheet(context, _einPosten);
      },
      child: const Text('anpassen'),
    ),
  ),
  reducedMotion: false,
  safeArea: false,
);

Future<void> _oeffneSheet(WidgetTester tester) async {
  await tester.pumpWidget(_host());
  await tester.tap(find.byKey(const ValueKey('open-adjust')));
  await tester.pumpAndSettle();
}

Future<void> _oeffneDialog(WidgetTester tester) async {
  final knopf = find.byKey(const ValueKey('analyse-item-add-button'));
  await tester.ensureVisible(knopf);
  await tester.pumpAndSettle();
  await tester.tap(knopf);
  await tester.pumpAndSettle();
  expect(find.byKey(const ValueKey('analyse-add-item-name')), findsOneWidget);
}

Future<void> _tippe(WidgetTester tester, String key, String text) async {
  await tester.enterText(find.byKey(ValueKey(key)), text);
  await tester.pumpAndSettle();
}

String _feldText(WidgetTester tester, String key) =>
    tester.widget<TextField>(find.byKey(ValueKey(key))).controller!.text;

/// `true` if „Hinzufügen" im Dialog tappbar ist.
bool _hinzufuegenAktiv(WidgetTester tester) {
  final button = tester.widget<FilledButton>(
    find.byKey(const ValueKey('analyse-add-item-save')),
  );
  return button.onPressed != null;
}

/// `true` if „Übernehmen" im Sheet tappbar ist.
bool _uebernehmenAktiv(WidgetTester tester) {
  final button = tester.widget<FilledButton>(
    find.byKey(const ValueKey('analyse-save-weight-button')),
  );
  return button.onPressed != null;
}

/// Did the field [key] keep every character of [bound] that was just typed
/// into it? The digit budget of the field is a NUMBER OF ITS OWN
/// (`LengthLimitingTextInputFormatter`), derived from the bound by hand — so a
/// bound that outgrows it cannot even be entered any more. THIS is the drift
/// the source rule above cannot see, and it is why the sheet gets mounted.
void _erwarteFeldFasstWert(WidgetTester tester, String key, num bound) {
  final erwartet = '$bound';
  expect(
    _feldText(tester, key),
    erwartet,
    reason:
        'Das Feld `$key` kann seine EIGENE Obergrenze ($erwartet) nicht '
        'fassen — der LengthLimitingTextInputFormatter im Anpassen-Sheet '
        'wurde von Hand aus der alten Grenze abgeleitet und ist nicht '
        'mitgewachsen. Getippt wurde $erwartet, im Feld steht '
        '"${_feldText(tester, key)}". Ergebnis auf dem Geraet: der zulaessige '
        'Hoechstwert ist nicht eingebbar. `_postenEingabeZiffern` in '
        '$_sheetPfad nachziehen — und dabei die Breite der Gewichtskapsel '
        'pruefen.',
  );
}

void main() {
  // -------------------------------------------------------------------------
  group('P8-02c — die Grenzen kommen aus model_limits.dart', () {
    late String sheetQuelle;

    setUpAll(() => sheetQuelle = _lies(_sheetPfad));

    test('die Bibliothek importiert die Grenzen ueberhaupt', () {
      // A `part` file cannot import; the library file has to. Without this the
      // rule below could only be satisfied by copying the numbers back.
      expect(
        _lies(_bibliothekPfad),
        contains("import '../../models/model_limits.dart'"),
        reason:
            '$_bibliothekPfad importiert model_limits.dart nicht mehr — dann '
            'kann das part-File die Grenzen nur noch abschreiben, und genau '
            'das war P8-02c.',
      );
    });

    test('jede Grenze ist eine Referenz auf das Modell, keine Zahl', () {
      for (final eintrag in _erwarteteBindung.entries) {
        final rechts = _rechteSeite(sheetQuelle, eintrag.key);
        expect(
          double.tryParse(rechts.replaceAll('_', '')),
          isNull,
          reason:
              '`${eintrag.key}` ist wieder ein Literal ($rechts). Genau diese '
              'Doppelpflege hat den dritten Klemm-Pfad erzeugt (P8-02b): das '
              'Feld liess einen Wert durch, `adjustedToGrams` hat ihn still '
              'auf ${eintrag.value} gebogen und gespeichert wurde eine Zahl, '
              'die niemand getippt hat. Erwartet: '
              '`${eintrag.key} = ${eintrag.value}`.',
        );
        expect(
          rechts,
          eintrag.value,
          reason:
              '`${eintrag.key}` haengt an `$rechts` statt an '
              '`${eintrag.value}`. Numerisch gleich ist nicht dasselbe wie '
              'richtig gebunden — heute sind drei der vier Grenzen 10000.',
        );
      }
    });

    test('die referenzierten Modellwerte sind die, die das Sheet zeigt', () {
      // The reference is resolved here, so a member RENAMED in model_limits
      // (or a rule pointing at one that no longer exists) does not pass as
      // "is a reference, fine".
      for (final ziel in _erwarteteBindung.values) {
        expect(
          _modellWerte[ziel],
          isNotNull,
          reason: '$ziel gibt es in model_limits.dart nicht (mehr)',
        );
      }
      expect(
        PlausibilityLimits.portionGramsMax,
        LoggedMealLimits.estimatedGMax,
        reason:
            'Die Portionsgrenze ist per Definition die DB-Grenze für '
            '`estimated_g`; fällt das auseinander, zeigt das Sheet eine '
            'andere Zahl als die Spalte erlaubt.',
      );
    });
  });

  // -------------------------------------------------------------------------
  group('P8-02c — das laufende Sheet haelt genau diese Grenzen', () {
    testWidgetsRobust(
      'die Postenzeile nimmt portionGramsMax und lehnt eins mehr ab',
      (tester) async {
        await _oeffneSheet(tester);
        const feld = 'analyse-item-weight-input-0';
        const grenze = PlausibilityLimits.portionGramsMax;

        await _tippe(tester, feld, '$grenze');
        _erwarteFeldFasstWert(tester, feld, grenze);
        expect(
          _uebernehmenAktiv(tester),
          isTrue,
          reason: 'die Modellgrenze selbst muss speicherbar sein',
        );
        expect(
          find.byKey(const ValueKey('analyse-item-weight-hint-0')),
          findsNothing,
        );

        await _tippe(tester, feld, '${grenze + 1}');
        expect(
          _uebernehmenAktiv(tester),
          isFalse,
          reason:
              'ueber der Modellgrenze muss das Sheet ABLEHNEN, nicht klemmen',
        );
        expect(
          find.byKey(const ValueKey('analyse-item-weight-hint-0')),
          findsOneWidget,
        );
      },
    );

    testWidgetsRobust(
      'der Hinzufuegen-Dialog nimmt caloriesKcalMax und lehnt eins mehr ab',
      (tester) async {
        await _oeffneSheet(tester);
        await _oeffneDialog(tester);
        const feld = 'analyse-add-item-kcal';
        const grenze = LoggedMealLimits.caloriesKcalMax;

        await _tippe(tester, 'analyse-add-item-name', 'Riesenportion');
        await _tippe(tester, 'analyse-add-item-grams', '100');
        await _tippe(tester, feld, '$grenze');
        _erwarteFeldFasstWert(tester, feld, grenze);
        expect(_hinzufuegenAktiv(tester), isTrue);
        expect(
          find.byKey(const ValueKey('analyse-add-item-kcal-hint')),
          findsNothing,
        );

        await _tippe(tester, feld, '${grenze + 1}');
        expect(_hinzufuegenAktiv(tester), isFalse);
        expect(
          find.byKey(const ValueKey('analyse-add-item-kcal-hint')),
          findsOneWidget,
          reason: 'der gesperrte Knopf muss seinen Grund nennen (P8-02)',
        );
      },
    );

    testWidgetsRobust(
      'der Hinzufuegen-Dialog nimmt portionGramsMax und lehnt eins mehr ab',
      (tester) async {
        await _oeffneSheet(tester);
        await _oeffneDialog(tester);
        const feld = 'analyse-add-item-grams';
        const grenze = PlausibilityLimits.portionGramsMax;

        await _tippe(tester, 'analyse-add-item-name', 'Riesenportion');
        await _tippe(tester, 'analyse-add-item-kcal', '100');
        await _tippe(tester, feld, '$grenze');
        _erwarteFeldFasstWert(tester, feld, grenze);
        expect(_hinzufuegenAktiv(tester), isTrue);

        await _tippe(tester, feld, '${grenze + 1}');
        expect(_hinzufuegenAktiv(tester), isFalse);
        expect(
          find.byKey(const ValueKey('analyse-add-item-grams-hint')),
          findsOneWidget,
        );
      },
    );

    testWidgetsRobust(
      'die Makrofelder nehmen macroGMax und lehnen eins mehr ab',
      (tester) async {
        await _oeffneSheet(tester);
        await _oeffneDialog(tester);
        const grenze = LoggedMealLimits.macroGMax;

        await _tippe(tester, 'analyse-add-item-name', 'Riesenportion');
        await _tippe(tester, 'analyse-add-item-grams', '100');
        await _tippe(tester, 'analyse-add-item-kcal', '100');
        await tester.tap(
          find.byKey(const ValueKey('analyse-add-item-macros-toggle')),
        );
        await tester.pumpAndSettle();

        // All three, otherwise `_alleMakrosGesetzt` stays false and the
        // Hinzufügen button says nothing about the range.
        for (final feld in const <String>[
          'analyse-add-item-protein',
          'analyse-add-item-carbs',
          'analyse-add-item-fat',
        ]) {
          await _tippe(tester, feld, '${grenze.toInt()}');
        }
        expect(
          _hinzufuegenAktiv(tester),
          isTrue,
          reason: 'die Makrogrenze selbst muss eingebbar bleiben',
        );

        await _tippe(
          tester,
          'analyse-add-item-protein',
          '${grenze.toInt() + 1}',
        );
        expect(
          _hinzufuegenAktiv(tester),
          isFalse,
          reason:
              'ueber `LoggedMealLimits.macroGMax` wuerde die DB den Schreib'
              'vorgang mit 23514 ablehnen — der Dialog muss vorher ablehnen',
        );
      },
    );
  });
}
