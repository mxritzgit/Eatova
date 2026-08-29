// P8-02 / P8-09 — the gram field of the component adjust sheet.
//
// P8-02: the row printed the RAW typed value while kcal, total card and save
// path all ran through `clampPortionGrams` (1..10000 g). Typing 12000 read
// "12000 g · <kcal for 10000 g>", the card below read "10000 g" and
// "Übernehmen" silently saved 10000 g. Clearing a field showed "0 g · 0 kcal"
// in the row while the total kept counting 1 g for the same item.
//
// `model_limits.dart` states the project line: REJECT what the user types,
// never bend it ("Clamping 755 kg to 300 kg silently falsifies the input").
// So an implausible weight now locks the button and says why; row and total
// keep citing the last valid value — one number, not two.
//
// P8-09: `controller.text = …` collapses the selection to offset -1
// (editable_text.dart), and the stepper does not pull focus off the field, so
// the next typed digits landed at the START of the number.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/meal_component.dart';
import 'package:eatova/src/widgets/meal/meal_widgets.dart';

import 'support/harness.dart' hide testWidgetsRobust;

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

/// One component, 100 g / 521 kcal — the density is consistent, so every number
/// in this suite is easy to follow: n g are 5,21 * n kcal.
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

/// Two components, so "eine Zeile ist ungültig" can be told apart from
/// "das ganze Sheet ist ungültig".
const _zweiPosten = MealAnalysisResult(
  mealName: 'Bowl',
  caloriesKcal: 300,
  estimatedGrams: 200,
  kcalPer100G: 150,
  protein: '-',
  carbs: '-',
  fat: '-',
  confidence: 'Mittel',
  portionNotes: 'Testmahlzeit.',
  sourceLabel: 'Foto-KI',
  items: [
    MealComponent(
      name: 'Reis',
      grams: 100,
      caloriesKcal: 100,
      kcalPer100G: 100,
    ),
    MealComponent(
      name: 'Bohnen',
      grams: 100,
      caloriesKcal: 200,
      kcalPer100G: 200,
    ),
  ],
);

Widget _host(MealAnalysisResult result, void Function(Object?) onResult) {
  return localizedApp(
    Builder(
      builder: (context) => TextButton(
        key: const ValueKey('open-adjust'),
        onPressed: () async =>
            onResult(await showWeightAdjustmentSheet(context, result)),
        child: const Text('anpassen'),
      ),
    ),
    reducedMotion: false,
    safeArea: false,
  );
}

Future<void> _oeffne(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('open-adjust')));
  await tester.pumpAndSettle();
}

Finder _feld(int index) =>
    find.byKey(ValueKey('analyse-item-weight-input-$index'));

TextEditingController _controller(WidgetTester tester, int index) =>
    tester.widget<TextField>(_feld(index)).controller!;

/// The stepper buttons live INSIDE the item card; the "Bestandteil hinzufügen"
/// button outside it also carries `Icons.add_rounded`, hence the descendant.
Finder _stepper(int index, IconData icon) => find.descendant(
  of: find.byKey(ValueKey('analyse-item-card-$index')),
  matching: find.byIcon(icon),
);

Future<void> _tippe(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

/// `true` if "Übernehmen" is tappable.
bool _uebernehmenAktiv(WidgetTester tester) {
  final button = tester.widget<FilledButton>(
    find.byKey(const ValueKey('analyse-save-weight-button')),
  );
  return button.onPressed != null;
}

/// Every `<n> g · <k> kcal` line the sheet currently renders, as (g, kcal).
List<(int, int)> _postenZeilen(WidgetTester tester) {
  final muster = RegExp(r'^(\d+) g · (\d+) kcal$');
  return tester
      .widgetList<Text>(find.byType(Text))
      .map((t) => t.data)
      .whereType<String>()
      .map(muster.firstMatch)
      .whereType<RegExpMatch>()
      .map((m) => (int.parse(m.group(1)!), int.parse(m.group(2)!)))
      .toList(growable: false);
}

void main() {
  group('P8-02 — zu grosse Gewichte werden abgelehnt, nicht gebogen', () {
    testWidgetsRobust(
      '12000 g sperrt Übernehmen und der Grund steht sichtbar da',
      (tester) async {
        Object? gespeichert;
        await tester.pumpWidget(_host(_einPosten, (v) => gespeichert = v));
        await _oeffne(tester);
        expect(_uebernehmenAktiv(tester), isTrue);

        await tester.enterText(_feld(0), '12000');
        await tester.pumpAndSettle();

        expect(
          _uebernehmenAktiv(tester),
          isFalse,
          reason:
              'Ein unmögliches Gewicht darf nicht still gekürzt gespeichert '
              'werden.',
        );
        // Der Grund muss sichtbar sein — an der Zeile UND am gesperrten Knopf.
        expect(
          find.byKey(const ValueKey('analyse-item-weight-hint-0')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('analyse-invalid-weight-hint')),
          findsOneWidget,
        );
        expect(find.textContaining('10000'), findsWidgets);

        // Und nichts wurde gespeichert.
        expect(gespeichert, isNull);
      },
    );

    testWidgetsRobust(
      'Zeile und Summenkarte nennen dieselbe Zahl — keine 12000 in der Zeile',
      (tester) async {
        await tester.pumpWidget(_host(_einPosten, (_) {}));
        await _oeffne(tester);

        await tester.enterText(_feld(0), '12000');
        await tester.pumpAndSettle();

        // Vorher: Zeile "12000 g · 52100 kcal", Karte "10000 g ≈ 52100 kcal".
        expect(
          _postenZeilen(tester),
          const [(100, 521)],
          reason:
              'Die Zeile muss den letzten gültigen Wert zeigen, nicht den '
              'getippten Unsinn.',
        );
        expect(find.text('100 g ≈ 521 kcal'), findsOneWidget);
        expect(find.textContaining('12000 g'), findsNothing);
      },
    );

    testWidgetsRobust(
      'ein geleertes Feld zeigt in Zeile und Summe dasselbe',
      (tester) async {
        await tester.pumpWidget(_host(_einPosten, (_) {}));
        await _oeffne(tester);

        await tester.enterText(_feld(0), '');
        await tester.pumpAndSettle();

        // Vorher: Zeile "0 g · 0 kcal", Karte "1 g ≈ 5 kcal".
        expect(_postenZeilen(tester), const [(100, 521)]);
        expect(find.text('100 g ≈ 521 kcal'), findsOneWidget);
        expect(_uebernehmenAktiv(tester), isFalse);
        expect(
          find.byKey(const ValueKey('analyse-item-weight-hint-0')),
          findsOneWidget,
        );
      },
    );

    testWidgetsRobust(
      'die Korrektur macht Übernehmen wieder frei und speichert genau sie',
      (tester) async {
        Object? gespeichert;
        await tester.pumpWidget(_host(_einPosten, (v) => gespeichert = v));
        await _oeffne(tester);

        await tester.enterText(_feld(0), '12000');
        await tester.pumpAndSettle();
        expect(_uebernehmenAktiv(tester), isFalse);

        await tester.enterText(_feld(0), '300');
        await tester.pumpAndSettle();
        expect(_uebernehmenAktiv(tester), isTrue);
        expect(
          find.byKey(const ValueKey('analyse-item-weight-hint-0')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('analyse-invalid-weight-hint')),
          findsNothing,
        );

        await tester.tap(
          find.byKey(const ValueKey('analyse-save-weight-button')),
        );
        await tester.pumpAndSettle();

        final posten = gespeichert as List<MealComponent>;
        expect(posten.single.grams, 300);
        expect(posten.single.caloriesKcal, 1563);
      },
    );

    testWidgetsRobust(
      'nur die betroffene Zeile bekommt den Hinweis, gesperrt ist alles',
      (tester) async {
        await tester.pumpWidget(_host(_zweiPosten, (_) {}));
        await _oeffne(tester);

        await tester.enterText(_feld(1), '0');
        await tester.pumpAndSettle();

        expect(
          find.byKey(const ValueKey('analyse-item-weight-hint-1')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('analyse-item-weight-hint-0')),
          findsNothing,
        );
        expect(_uebernehmenAktiv(tester), isFalse);
        // Beide Zeilen zeigen weiter ihren letzten gültigen Wert.
        expect(_postenZeilen(tester), const [(100, 100), (100, 200)]);
      },
    );

    testWidgetsRobust(
      'ein entfernter Posten mit Unsinn im Feld blockiert nicht mehr',
      (tester) async {
        await tester.pumpWidget(_host(_zweiPosten, (_) {}));
        await _oeffne(tester);

        await tester.enterText(_feld(1), '99999');
        await tester.pumpAndSettle();
        expect(_uebernehmenAktiv(tester), isFalse);

        await _tippe(tester, find.byKey(const ValueKey('analyse-item-remove-1')));
        expect(_uebernehmenAktiv(tester), isTrue);
      },
    );
  });

  group('P8-09 — der Stepper laesst den Cursor am Ende stehen', () {
    testWidgetsRobust(
      'nach + steht die Auswahl am Textende, nicht auf -1',
      (tester) async {
        await tester.pumpWidget(_host(_einPosten, (_) {}));
        await _oeffne(tester);

        // Fokus wie beim echten Tippen: erst ins Feld, dann steppen. Der
        // Stepper zieht ihn nicht ab, also entscheidet die Auswahl, wo die
        // naechste Ziffer landet.
        await tester.showKeyboard(_feld(0));
        await tester.pumpAndSettle();

        // Zwei Schritte, weil der ERSTE das Sheet erst „dirty" macht: dabei
        // tauscht `_DiscardDragGuard` seinen Knoten, der Teilbaum wird neu
        // aufgebaut und `EditableText` repariert die Auswahl beim Fokussieren.
        // Ab dem zweiten Schritt bleibt der kaputte Offset stehen.
        await _tippe(tester, _stepper(0, Icons.add_rounded));
        await _tippe(tester, _stepper(0, Icons.add_rounded));

        final controller = _controller(tester, 0);
        expect(controller.text, '120');
        expect(
          controller.selection.isValid,
          isTrue,
          reason:
              'controller.text setzt die Auswahl auf offset -1 — die '
              'naechsten Ziffern landen dann am Textanfang.',
        );
        expect(controller.selection.isCollapsed, isTrue);
        expect(controller.selection.baseOffset, controller.text.length);
      },
    );

    testWidgetsRobust(
      'auch nach - und nach einem Longpress steht der Cursor am Ende',
      (tester) async {
        await tester.pumpWidget(_host(_einPosten, (_) {}));
        await _oeffne(tester);
        await tester.showKeyboard(_feld(0));
        await tester.pumpAndSettle();

        await _tippe(tester, _stepper(0, Icons.remove_rounded));
        var controller = _controller(tester, 0);
        expect(controller.text, '90');
        expect(controller.selection.baseOffset, 2);

        final plus = _stepper(0, Icons.add_rounded);
        await tester.ensureVisible(plus);
        await tester.pumpAndSettle();
        await tester.longPress(plus);
        await tester.pumpAndSettle();
        controller = _controller(tester, 0);
        expect(controller.text, '140');
        expect(controller.selection.baseOffset, 3);
      },
    );

    testWidgetsRobust(
      'der Stepper bleibt in seinen Grenzen und aktualisiert Zeile und Summe',
      (tester) async {
        await tester.pumpWidget(_host(_einPosten, (_) {}));
        await _oeffne(tester);

        // Gegen die untere Grenze steppen ist eine Geste ohne Zahl — dort ist
        // Klemmen richtig, anders als beim Tippen.
        for (var i = 0; i < 12; i++) {
          await _tippe(tester, _stepper(0, Icons.remove_rounded));
        }

        final controller = _controller(tester, 0);
        expect(controller.text, '1');
        expect(controller.selection.baseOffset, 1);
        expect(_postenZeilen(tester), const [(1, 5)]);
        expect(find.text('1 g ≈ 5 kcal'), findsOneWidget);
        expect(_uebernehmenAktiv(tester), isTrue);
      },
    );
  });
}
