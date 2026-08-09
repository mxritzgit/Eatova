// W6-06 / D5: das Bestandteil-Anpassen-Sheet verwarf ausgefuellte Formulare
// kommentarlos.
//
// Es ist das vierte Sheet mit dem Fund und zugleich das, das die drei bereits
// geschuetzten Sheets fuer ihren datenintensivsten Schritt aufrufen
// (edit_meal_sheet.dart:257, meal_analysis_sheet.dart:212). Gefaehrdeter
// Zustand: ein Gewichtsfeld pro Bestandteil, das Entfernt-Set, die manuell
// ergaenzten Posten — plus die sechs Felder des Hinzufuegen-Dialogs.
//
// Die Schliesswege laufen im Framework VERSCHIEDEN, deshalb wird jeder
// einzeln geprueft (je dirty und nicht-dirty):
//
//   Barriere-Tap → ModalBarrier.handleDismiss → Navigator.maybePop
//                  (modal_barrier.dart:225-230)  → fragt PopScope
//   Ziehen       → BottomSheet._handleDragEnd → onClosing → Navigator.pop
//                  (bottom_sheet.dart:769-771)   → fragt PopScope NICHT
//   Griff        → _DragHandle(onSemanticsTap: widget.onClosing)
//                  (bottom_sheet.dart:368)       → derselbe Navigator.pop
//
// Der Griff ist hier der Sonderfall: `showDragHandle: true` liess die Route
// den Griff als Stack-Geschwister NEBEN dem builder-Kind zeichnen
// (bottom_sheet.dart:397-410) — also ausserhalb jedes Guards im Sheet. Ein
// Zug genau am Griff und der TalkBack-Dismiss darauf liefen an der
// Rueckfrage vorbei.

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/meal_component.dart';
import 'package:eatova/src/theme/app_theme.dart';
import 'package:eatova/src/widgets/meal/meal_widgets.dart';

/// Viewport-Pinning + Overflow-Toleranz wie in den uebrigen Widget-Suiten.
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

MealComponent _posten(String name, int grams, int kcal) => MealComponent(
  name: name,
  grams: grams,
  caloriesKcal: kcal,
  kcalPer100G: kcal * 100 / grams,
  proteinG: 5,
  carbsG: 10,
  fatG: 2,
);

MealAnalysisResult _ergebnis({int postenAnzahl = 2}) => MealAnalysisResult(
  mealName: 'Bowl',
  caloriesKcal: 520,
  estimatedGrams: 400,
  kcalPer100G: 130,
  protein: '30 g',
  carbs: '50 g',
  fat: '18 g',
  confidence: 'Hoch',
  portionNotes: 'Testmahlzeit.',
  sourceLabel: 'KI-Scan',
  items: [
    for (var i = 0; i < postenAnzahl; i++)
      _posten('Bestandteil $i', 100 + i * 10, 120 + i * 10),
  ],
);

/// Faengt ab, was `showWeightAdjustmentSheet` zurueckgibt — genau der Wert,
/// den die aufrufenden Sheets an `adjustedToItems` weiterreichen. `null` heisst
/// dort "nichts uebernehmen"; abgebrochen und verworfen muessen deshalb
/// beide `null` liefern.
class _Fang {
  Object? wert;
  int aufrufe = 0;
}

Future<void> _oeffne(
  WidgetTester tester,
  _Fang fang, {
  int postenAnzahl = 2,
}) async {
  final result = _ergebnis(postenAnzahl: postenAnzahl);
  await tester.pumpWidget(
    MaterialApp(
      // Seit dem Design-Refactor lesen die Anpassen-Flaechen ihre Farben aus
      // der AppTokens-ThemeExtension; ein blankes MaterialApp-Theme traegt sie
      // nicht und AppTokens.of wirft dann bewusst.
      theme: buildEatovaTheme(Brightness.dark),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            key: const ValueKey('open-adjust'),
            onPressed: () async {
              final r = await showWeightAdjustmentSheet(context, result);
              fang
                ..wert = r
                ..aufrufe += 1;
            },
            child: const Text('anpassen'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const ValueKey('open-adjust')));
  await tester.pumpAndSettle();
}

bool _sheetOffen(WidgetTester tester) =>
    find.text('Bestandteile anpassen').evaluate().isNotEmpty;

bool _dialogOffen(WidgetTester tester) =>
    find.byKey(const ValueKey('discard-changes-dialog')).evaluate().isNotEmpty;

Offset _sheetOben(WidgetTester tester) => tester.getTopLeft(
  find
      .descendant(of: find.byType(BottomSheet), matching: find.byType(Material))
      .first,
);

/// Weg 1: Tap knapp UEBER das Sheet — genau die Geste, mit der man die
/// Tastatur schliessen will.
///
/// Der Streifen ueber dem Sheet ist je nach Postenzahl nur ein paar Pixel
/// hoch; `dy - 40` laege dann ausserhalb des Fensters und der Tap traefe gar
/// nichts (still gruen fuer die falschen Faelle).
Future<void> _tippeAufBarriere(WidgetTester tester) async {
  final oben = _sheetOben(tester).dy;
  expect(oben, greaterThan(4), reason: 'ohne Barriere gaebe es nichts zu tippen');
  await tester.tapAt(Offset(196, oben > 48 ? oben - 40 : oben / 2));
  await tester.pumpAndSettle();
}

/// Weg 2: das Sheet an seinem Inhalt nach unten ziehen.
Future<void> _ziehAmInhalt(WidgetTester tester) async {
  await tester.fling(
    find.text('Bestandteile anpassen'),
    const Offset(0, 400),
    2000,
  );
  await tester.pumpAndSettle();
}

/// Weg 3a: ziehen genau am Griff (oberste 24 px des Sheets).
Future<void> _ziehAmGriff(WidgetTester tester) async {
  await tester.flingFrom(
    Offset(196, _sheetOben(tester).dy + 12),
    const Offset(0, 400),
    2000,
  );
  await tester.pumpAndSettle();
}

/// Weg 3b: der Dismiss-Knoten, den TalkBack/VoiceOver am Sheet anbietet.
///
/// Vor dem Fix ist das der Route-Griff (`_DragHandle`), dessen
/// `onSemanticsTap` direkt `Navigator.pop` ruft; danach der eigene Griff im
/// Sheet, der ueber `maybePop` und damit ueber die Rueckfrage laeuft. Beide
/// tragen `MaterialLocalizations.modalBarrierDismissLabel` — im Test-Host
/// (englische Default-Lokalisierung) also „Dismiss".
///
/// Die Barriere selbst taucht hier NICHT auf: `ModalBarrier` setzt Label und
/// Dismiss-Aktion nur, wenn `platformSupportsDismissingBarrier` gilt, und das
/// ist auf Android (Default-Plattform im Test) false.
final _griffKnoten = find.semantics.byLabel('Dismiss');

void main() {
  // ── Weg 1: Barriere-Tap ─────────────────────────────────────────────────

  group('D5 Weg 1 — Barriere-Tap', () {
    testWidgetsRobust('fragt nach, wenn ein Gewicht geaendert wurde', (
      tester,
    ) async {
      final fang = _Fang();
      await _oeffne(tester, fang);

      await tester.enterText(
        find.byKey(const ValueKey('analyse-item-weight-input-0')),
        '250',
      );
      await tester.pumpAndSettle();

      await _tippeAufBarriere(tester);

      expect(_sheetOffen(tester), isTrue, reason: 'nichts darf still verpuffen');
      expect(_dialogOffen(tester), isTrue);
      expect(find.text('Änderungen verwerfen?'), findsOneWidget);
      expect(fang.aufrufe, 0);

      // „Weiter bearbeiten" laesst die Eingabe stehen.
      await tester.tap(find.byKey(const ValueKey('discard-changes-cancel')));
      await tester.pumpAndSettle();
      expect(_sheetOffen(tester), isTrue);
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('analyse-item-weight-input-0')),
            )
            .controller!
            .text,
        '250',
      );

      // Und „Verwerfen" schliesst wirklich — ohne Ergebnis.
      await _tippeAufBarriere(tester);
      await tester.tap(find.byKey(const ValueKey('discard-changes-confirm')));
      await tester.pumpAndSettle();
      expect(_sheetOffen(tester), isFalse);
      expect(fang.aufrufe, 1);
      expect(fang.wert, isNull);
    });

    testWidgetsRobust('schliesst ein unveraendertes Sheet sofort', (
      tester,
    ) async {
      final fang = _Fang();
      await _oeffne(tester, fang);

      await _tippeAufBarriere(tester);

      expect(_dialogOffen(tester), isFalse);
      expect(_sheetOffen(tester), isFalse);
      expect(fang.wert, isNull);
    });
  });

  // ── Weg 2: Ziehen ───────────────────────────────────────────────────────

  group('D5 Weg 2 — Ziehen', () {
    testWidgetsRobust('fragt nach, wenn ein Gewicht geaendert wurde', (
      tester,
    ) async {
      final fang = _Fang();
      await _oeffne(tester, fang);

      await tester.enterText(
        find.byKey(const ValueKey('analyse-item-weight-input-0')),
        '250',
      );
      await tester.pumpAndSettle();

      await _ziehAmInhalt(tester);

      expect(
        _sheetOffen(tester),
        isTrue,
        reason: 'PopScope sieht diesen Weg nicht — der Drag-Guard muss ran',
      );
      expect(_dialogOffen(tester), isTrue);
      expect(fang.aufrufe, 0);

      await tester.tap(find.byKey(const ValueKey('discard-changes-confirm')));
      await tester.pumpAndSettle();
      expect(_sheetOffen(tester), isFalse);
      expect(fang.wert, isNull);
    });

    testWidgetsRobust('laesst ein unveraendertes Sheet weiterhin wegziehen', (
      tester,
    ) async {
      // Zugleich der Beleg, dass dieser Weg ueberhaupt schliesst — sonst saehe
      // man am dirty-Fall darueber gar keinen Unterschied.
      final fang = _Fang();
      await _oeffne(tester, fang);

      await _ziehAmInhalt(tester);

      expect(_dialogOffen(tester), isFalse);
      expect(_sheetOffen(tester), isFalse);
      expect(fang.wert, isNull);
    });
  });

  // ── Weg 3: Griff (Ziehen + Semantics-Dismiss) ───────────────────────────

  group('D5 Weg 3 — Griff', () {
    testWidgetsRobust('Ziehen am Griff fragt nach', (tester) async {
      final fang = _Fang();
      await _oeffne(tester, fang);

      await tester.enterText(
        find.byKey(const ValueKey('analyse-item-weight-input-0')),
        '250',
      );
      await tester.pumpAndSettle();

      await _ziehAmGriff(tester);

      expect(
        _sheetOffen(tester),
        isTrue,
        reason:
            'Der Route-Griff liegt als Stack-Geschwister ausserhalb des '
            'Guards — er muss durch einen eigenen Griff IM Sheet ersetzt sein',
      );
      expect(_dialogOffen(tester), isTrue);
      expect(fang.aufrufe, 0);
    });

    testWidgetsRobust('am Griff bleibt ein unveraendertes Sheet wegziehbar', (
      tester,
    ) async {
      final fang = _Fang();
      await _oeffne(tester, fang);

      await _ziehAmGriff(tester);

      expect(_dialogOffen(tester), isFalse);
      expect(_sheetOffen(tester), isFalse);
      expect(fang.wert, isNull);
    });

    testWidgetsRobust('der Semantics-Dismiss (TalkBack) fragt nach', (
      tester,
    ) async {
      // Bewusst ohne addTearDown: die Handle-Pruefung des Frameworks laeuft
      // VOR den Teardowns.
      final semantik = tester.ensureSemantics();
      final fang = _Fang();
      await _oeffne(tester, fang);

      await tester.enterText(
        find.byKey(const ValueKey('analyse-item-weight-input-0')),
        '250',
      );
      await tester.pumpAndSettle();

      expect(
        _griffKnoten,
        findsOne,
        reason:
            'Ohne Dismiss-Knoten kaeme ein TalkBack-Nutzer aus dem Sheet gar '
            'nicht mehr heraus — das Sheet hat keinen Schliessen-Knopf',
      );
      tester.semantics.performAction(_griffKnoten, SemanticsAction.tap);
      await tester.pumpAndSettle();

      expect(
        _sheetOffen(tester),
        isTrue,
        reason: 'onSemanticsTap des Route-Griffs ruft direkt Navigator.pop',
      );
      expect(_dialogOffen(tester), isTrue);
      semantik.dispose();
    });

    testWidgetsRobust(
      'der Semantics-Dismiss schliesst ein unveraendertes Sheet sofort',
      (tester) async {
        final semantik = tester.ensureSemantics();
        final fang = _Fang();
        await _oeffne(tester, fang);

        tester.semantics.performAction(_griffKnoten, SemanticsAction.tap);
        await tester.pumpAndSettle();

        expect(_dialogOffen(tester), isFalse);
        expect(_sheetOffen(tester), isFalse);
        expect(fang.wert, isNull);
        semantik.dispose();
      },
    );
  });

  // ── Was „geaendert" bei variabler Postenzahl heisst ─────────────────────

  group('D5 — _dirty bei variabler Postenzahl', () {
    testWidgetsRobust('ein entfernter Bestandteil zaehlt als Aenderung', (
      tester,
    ) async {
      final fang = _Fang();
      await _oeffne(tester, fang);

      await tester.tap(find.byKey(const ValueKey('analyse-item-remove-0')));
      await tester.pumpAndSettle();

      await _tippeAufBarriere(tester);

      expect(_dialogOffen(tester), isTrue);
      expect(_sheetOffen(tester), isTrue);
    });

    testWidgetsRobust('entfernt und wiederhergestellt ist keine Aenderung', (
      tester,
    ) async {
      final fang = _Fang();
      await _oeffne(tester, fang);

      await tester.tap(find.byKey(const ValueKey('analyse-item-remove-0')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Wiederherstellen'));
      await tester.pumpAndSettle();

      await _tippeAufBarriere(tester);

      expect(
        _dialogOffen(tester),
        isFalse,
        reason: 'der Ausgangszustand ist wiederhergestellt',
      );
      expect(_sheetOffen(tester), isFalse);
    });

    testWidgetsRobust('zurueckgetipptes Gewicht ist keine Aenderung', (
      tester,
    ) async {
      final fang = _Fang();
      await _oeffne(tester, fang);

      await tester.enterText(
        find.byKey(const ValueKey('analyse-item-weight-input-0')),
        '250',
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('analyse-item-weight-input-0')),
        '100',
      );
      await tester.pumpAndSettle();

      await _tippeAufBarriere(tester);

      expect(_dialogOffen(tester), isFalse);
      expect(_sheetOffen(tester), isFalse);
    });

    testWidgetsRobust(
      'hinzugefuegt und wieder entfernt ist keine Aenderung',
      (tester) async {
        // Nur ein Startposten: mit dem manuell ergaenzten dazu bleibt oben
        // noch ein Barrierestreifen uebrig, auf den sich tippen laesst.
        final fang = _Fang();
        await _oeffne(tester, fang, postenAnzahl: 1);

        await tester.tap(find.byKey(const ValueKey('analyse-item-add-button')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('analyse-add-item-name')),
          'Brot',
        );
        await tester.enterText(
          find.byKey(const ValueKey('analyse-add-item-grams')),
          '50',
        );
        await tester.enterText(
          find.byKey(const ValueKey('analyse-add-item-kcal')),
          '130',
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('analyse-add-item-save')));
        await tester.pumpAndSettle();

        // Der neue Posten haengt hinten dran — und fliegt gleich wieder raus.
        await tester.tap(find.byKey(const ValueKey('analyse-item-remove-1')));
        await tester.pumpAndSettle();

        await _tippeAufBarriere(tester);

        expect(
          _dialogOffen(tester),
          isFalse,
          reason: 'unterm Strich steht wieder der Ausgangszustand',
        );
        expect(_sheetOffen(tester), isFalse);
      },
    );

    testWidgetsRobust('ein hinzugefuegter Bestandteil zaehlt als Aenderung', (
      tester,
    ) async {
      // Nur ein Startposten — sonst fuellt das Sheet mit dem ergaenzten
      // Bestandteil den Bildschirm und es bleibt keine Barriere zum Tippen.
      final fang = _Fang();
      await _oeffne(tester, fang, postenAnzahl: 1);

      await tester.tap(find.byKey(const ValueKey('analyse-item-add-button')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('analyse-add-item-name')),
        'Brot',
      );
      await tester.enterText(
        find.byKey(const ValueKey('analyse-add-item-grams')),
        '50',
      );
      await tester.enterText(
        find.byKey(const ValueKey('analyse-add-item-kcal')),
        '130',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('analyse-add-item-save')));
      await tester.pumpAndSettle();

      await _tippeAufBarriere(tester);

      expect(_dialogOffen(tester), isTrue);
      expect(_sheetOffen(tester), isTrue);
    });
  });

  // ── Drei Ebenen: Verwerfen-Dialog ueber Dialog ueber Sheet ──────────────

  group('D5 — Hinzufuegen-Dialog ueber dem Sheet', () {
    Future<void> oeffneDialogMitEingabe(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('analyse-item-add-button')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('analyse-add-item-name')),
        'Olivenöl',
      );
      await tester.enterText(
        find.byKey(const ValueKey('analyse-add-item-grams')),
        '20',
      );
      await tester.pumpAndSettle();
    }

    testWidgetsRobust(
      'ein Tap neben den Dialog verwirft die sechs Felder nicht',
      (tester) async {
        final fang = _Fang();
        await _oeffne(tester, fang);
        await oeffneDialogMitEingabe(tester);

        await tester.tapAt(const Offset(196, 16));
        await tester.pumpAndSettle();

        expect(_dialogOffen(tester), isTrue);
        expect(
          find.byKey(const ValueKey('analyse-add-item-name')),
          findsOneWidget,
          reason: 'der Hinzufuegen-Dialog bleibt unter der Rueckfrage stehen',
        );
      },
    );

    testWidgetsRobust(
      '„Weiter bearbeiten" laesst den Hinzufuegen-Dialog mit Inhalt offen',
      (tester) async {
        final fang = _Fang();
        await _oeffne(tester, fang);
        await oeffneDialogMitEingabe(tester);

        await tester.tapAt(const Offset(196, 16));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('discard-changes-cancel')));
        await tester.pumpAndSettle();

        expect(_dialogOffen(tester), isFalse);
        expect(
          tester
              .widget<TextField>(
                find.byKey(const ValueKey('analyse-add-item-name')),
              )
              .controller!
              .text,
          'Olivenöl',
          reason: '„Abbrechen" muss genau die mittlere Ebene offen lassen',
        );
        expect(_sheetOffen(tester), isTrue);
      },
    );

    testWidgetsRobust('„Verwerfen" schliesst nur den Dialog, nicht das Sheet', (
      tester,
    ) async {
      final fang = _Fang();
      await _oeffne(tester, fang);
      await oeffneDialogMitEingabe(tester);

      await tester.tapAt(const Offset(196, 16));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('discard-changes-confirm')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('analyse-add-item-name')), findsNothing);
      expect(_sheetOffen(tester), isTrue);
      expect(fang.aufrufe, 0, reason: 'das Sheet lebt weiter');
      // Kein Posten dazugekommen.
      expect(find.byKey(const ValueKey('analyse-item-card-2')), findsNothing);
    });

    testWidgetsRobust('ein leerer Hinzufuegen-Dialog schliesst kommentarlos', (
      tester,
    ) async {
      final fang = _Fang();
      await _oeffne(tester, fang);
      await tester.tap(find.byKey(const ValueKey('analyse-item-add-button')));
      await tester.pumpAndSettle();

      await tester.tapAt(const Offset(196, 16));
      await tester.pumpAndSettle();

      expect(_dialogOffen(tester), isFalse);
      expect(find.byKey(const ValueKey('analyse-add-item-name')), findsNothing);
      expect(_sheetOffen(tester), isTrue);
    });
  });

  // ── Der Rueckgabewert darf sich nicht verschieben ───────────────────────

  group('D5 — Rueckgabewert bleibt, wie die Aufrufer ihn erwarten', () {
    testWidgetsRobust('„Übernehmen" liefert weiterhin die Postenliste', (
      tester,
    ) async {
      final fang = _Fang();
      await _oeffne(tester, fang);

      await tester.enterText(
        find.byKey(const ValueKey('analyse-item-weight-input-0')),
        '250',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('analyse-save-weight-button')));
      await tester.pumpAndSettle();

      expect(fang.aufrufe, 1);
      expect(fang.wert, isA<List<MealComponent>>());
      final liste = fang.wert! as List<MealComponent>;
      expect(liste, hasLength(2));
      expect(liste.first.grams, 250);
    });

    testWidgetsRobust(
      'unveraendert bestaetigt liefert ebenfalls die Liste (PopScope blockt '
      '„Übernehmen" nicht)',
      (tester) async {
        final fang = _Fang();
        await _oeffne(tester, fang);

        await tester.tap(
          find.byKey(const ValueKey('analyse-save-weight-button')),
        );
        await tester.pumpAndSettle();

        expect(fang.aufrufe, 1);
        expect(fang.wert, isA<List<MealComponent>>());
        expect((fang.wert! as List<MealComponent>).first.grams, 100);
      },
    );
  });

  // ── Der Guard darf sonst nichts blockieren ─────────────────────────────

  group('D5 — der Guard stoert die Bedienung nicht', () {
    testWidgetsRobust('Tippen und Entfernen gehen bei aktivem Guard weiter', (
      tester,
    ) async {
      final fang = _Fang();
      await _oeffne(tester, fang);

      // Ab hier ist der Guard aktiv.
      await tester.enterText(
        find.byKey(const ValueKey('analyse-item-weight-input-0')),
        '250',
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey('analyse-item-weight-input-1')),
        '333',
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('analyse-item-weight-input-1')),
            )
            .controller!
            .text,
        '333',
      );

      await tester.tap(find.byKey(const ValueKey('analyse-item-remove-1')));
      await tester.pumpAndSettle();
      expect(find.text('Wiederherstellen'), findsOneWidget);
      expect(_dialogOffen(tester), isFalse);
    });

    testWidgetsRobust('ein langes Sheet laesst sich weiterhin scrollen', (
      tester,
    ) async {
      final fang = _Fang();
      await _oeffne(tester, fang, postenAnzahl: 8);

      await tester.enterText(
        find.byKey(const ValueKey('analyse-item-weight-input-0')),
        '250',
      );
      await tester.pumpAndSettle();

      final vorher = tester.getTopLeft(find.text('Bestandteile anpassen')).dy;
      await tester.drag(
        find.byType(SingleChildScrollView),
        const Offset(0, -200),
      );
      await tester.pumpAndSettle();

      expect(
        tester.getTopLeft(find.text('Bestandteile anpassen')).dy,
        lessThan(vorher),
      );
      expect(_sheetOffen(tester), isTrue);
      expect(_dialogOffen(tester), isFalse);
    });
  });
}
