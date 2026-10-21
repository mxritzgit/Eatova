// P8-02c — the adjust sheet's input bounds belong to the MODEL, not to the
// sheet.
//
// `_postenMinG`, `_postenMaxG`, `_postenMaxKcal` and `_makroMaxG` in
// lib/src/widgets/meal/meal_widgets_adjust.dart used to be hand-copied
// literals. A surface that knows a DIFFERENT number than the clamp behind it
// is exactly how the third silent bend came about that P8-02b had to close:
// the field let a value through, `adjustedToGrams` quietly folded it onto
// the model bound and the meal was saved with a number nobody typed.
//
// Measured on the RUNNING sheet against the model constants: each field
// accepts the model bound and rejects bound + 1. That catches any drift
// between sheet and model — including the one number the sheet keeps on
// its own, the digit budget of its input fields
// (`LengthLimitingTextInputFormatter`): a bound that outgrows it can no
// longer be typed in at all.
//
// (A source grep that the four constants are written as references stood
// here too; it re-asserted what these cases measure.)

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/meal_component.dart';
import 'package:eatova/src/models/model_limits.dart';
import 'package:eatova/src/widgets/design/design.dart' show PrimaryActionButton;
import 'package:eatova/src/widgets/meal/meal_widgets.dart';

import '../support/harness.dart';

const String _sheetPfad = 'lib/src/widgets/meal/meal_widgets_adjust.dart';

// ---------------------------------------------------------------------------
// The running sheet
// ---------------------------------------------------------------------------

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
  final button = tester.widget<PrimaryActionButton>(
    find.byKey(const ValueKey('analyse-save-weight-button')),
  );
  return button.onTap != null;
}

/// Did the field [key] keep every character of [bound] that was just typed
/// into it? The digit budget of the field is a NUMBER OF ITS OWN
/// (`LengthLimitingTextInputFormatter`), derived from the bound by hand — so a
/// bound that outgrows it cannot even be entered any more.
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
