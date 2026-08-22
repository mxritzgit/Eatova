// W6-06 / D5: the component adjust sheet discarded filled-in forms silently.
//
// It is the sheet the three already guarded sheets call for their most
// data-heavy step. State at risk: a weight field per component, the removed
// set, manually added items, plus the six fields of the add dialog.
//
// The framework routes the close paths differently, so each is tested (dirty
// and non-dirty):
//
//   barrier tap → ModalBarrier.handleDismiss → Navigator.maybePop, which
//                 asks PopScope
//   drag        → BottomSheet._handleDragEnd → onClosing → Navigator.pop,
//                 which does NOT ask PopScope
//   handle      → _DragHandle(onSemanticsTap: widget.onClosing), same pop
//
// The handle is the special case: `showDragHandle: true` made the route draw
// it as a stack sibling NEXT TO the builder child, outside any guard in the
// sheet, so a drag on the handle and the TalkBack dismiss bypassed the
// confirmation.

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/meal_component.dart';
import 'package:eatova/src/theme/app_theme.dart';
import 'package:eatova/src/widgets/meal/meal_widgets.dart';

/// Viewport pinning + overflow tolerance, as in the other widget suites.
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

/// Captures what `showWeightAdjustmentSheet` returns — the value the calling
/// sheets pass to `adjustedToItems`. `null` means "apply nothing", so cancel
/// and discard must both yield `null`.
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
      // The adjust surfaces read their colours from the AppTokens theme
      // extension; a bare MaterialApp theme lacks it and AppTokens.of throws.
      theme: buildEatovaTheme(Brightness.dark),
      // showWeightAdjustmentSheet reads context.l10n.
      locale: const Locale('de'),
      supportedLocales: const [Locale('de'), Locale('en')],
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
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

/// Path 1: tap just ABOVE the sheet — the gesture used to dismiss the
/// keyboard.
///
/// Depending on the item count that strip is only a few pixels tall, so a flat
/// `dy - 40` would land outside the window and hit nothing.
Future<void> _tippeAufBarriere(WidgetTester tester) async {
  final oben = _sheetOben(tester).dy;
  expect(oben, greaterThan(4), reason: 'ohne Barriere gaebe es nichts zu tippen');
  await tester.tapAt(Offset(196, oben > 48 ? oben - 40 : oben / 2));
  await tester.pumpAndSettle();
}

/// Path 2: drag the sheet down by its content.
Future<void> _ziehAmInhalt(WidgetTester tester) async {
  await tester.fling(
    find.text('Bestandteile anpassen'),
    const Offset(0, 400),
    2000,
  );
  await tester.pumpAndSettle();
}

/// Path 3a: drag exactly on the handle (top 24 px of the sheet).
Future<void> _ziehAmGriff(WidgetTester tester) async {
  await tester.flingFrom(
    Offset(196, _sheetOben(tester).dy + 12),
    const Offset(0, 400),
    2000,
  );
  await tester.pumpAndSettle();
}

/// Path 3b: the dismiss node TalkBack/VoiceOver offers on the sheet.
///
/// Before the fix that is the route handle (`_DragHandle`), whose
/// `onSemanticsTap` calls `Navigator.pop` directly; afterwards it is the
/// sheet's own handle, which goes through `maybePop` and the confirmation.
/// Both carry `MaterialLocalizations.modalBarrierDismissLabel`, and this
/// MaterialApp runs under `de`, hence the German label.
///
/// The barrier itself does NOT appear here: `ModalBarrier` only sets label and
/// dismiss action when `platformSupportsDismissingBarrier` holds, which is
/// false on Android (the default test platform).
final _griffKnoten = find.semantics.byLabel('Schließen');

void main() {
  // ── Path 1: barrier tap ────────────────────────────────────────────────

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

      // "Keep editing" leaves the input in place.
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

      // And "discard" really closes, without a result.
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

  // ── Path 2: drag ────────────────────────────────────────────────────────

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
      // Also proves this path closes at all, otherwise the dirty case above
      // would show no difference.
      final fang = _Fang();
      await _oeffne(tester, fang);

      await _ziehAmInhalt(tester);

      expect(_dialogOffen(tester), isFalse);
      expect(_sheetOffen(tester), isFalse);
      expect(fang.wert, isNull);
    });
  });

  // ── Path 3: handle (drag + semantics dismiss) ───────────────────────────

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
      // No addTearDown on purpose: the framework's handle check runs BEFORE
      // the teardowns.
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

  // ── What "changed" means at a variable item count ───────────────────

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
        // One starting item, so with the manually added one there is still a
        // barrier strip left to tap.
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

        // The new item is appended, then removed again.
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
      // One starting item, or the sheet fills the screen and leaves no
      // barrier to tap.
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

  // ── Three layers: discard dialog over dialog over sheet ──────────────

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
      // No item was added.
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

  // ── The return value must not shift ───────────────────────────────

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

  // ── The guard must not block anything else ─────────────────────────────

  group('D5 — der Guard stoert die Bedienung nicht', () {
    testWidgetsRobust('Tippen und Entfernen gehen bei aktivem Guard weiter', (
      tester,
    ) async {
      final fang = _Fang();
      await _oeffne(tester, fang);

      // The guard is active from here on.
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
