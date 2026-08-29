import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/widgets/design/design.dart';
import 'package:eatova/src/widgets/kcal/diary_meal_card.dart';

import '../../support/harness.dart';

// ---------------------------------------------------------------------------
// P8-04 — the tap target of the slot card's plus button.
//
// The button was a bare `SizedBox(32, 32)` inside a Material: no padding, no
// constraints, no `MaterialTapTargetSize`. That clears WCAG 2.5.8 (24 pt), but
// not the project floor of 44 that `AppToggle`, `SquareIconButton` and the
// favorites search clear key all keep — and this is the main way to log into
// a slot that already has entries.
//
// Two halves, both measured, not just tapped:
//  1. the hit surface is 44 x 44,
//  2. nothing drawn moved a pixel — the 6 pt of transparent margin per side
//     come out of the header padding (15 -> 9) and the gap (8 -> 2).
//
// The numbers below were measured on the pre-fix build (see the golden block)
// and must survive every text scale.
// ---------------------------------------------------------------------------

/// Logical width of an iPhone 12/13/14, like the macro suite next door.
const double _breite = 390;

/// `AppCard`'s 1 pt border plus the header's 15 pt left/right padding: the
/// distance from the card edge to the drawn chip. Unchanged by the fix.
const double _kartenrand = 16;

/// The gap between text column and chip before the fix — 8 pt, of which 6 are
/// now the button's own transparent margin.
const double _spalt = 8;

MealAnalysisResult _ergebnis() => const MealAnalysisResult(
  mealName: 'Haferbrei',
  caloriesKcal: 320,
  estimatedGrams: 250,
  kcalPer100G: 128,
  protein: '12 g',
  carbs: '48 g',
  fat: '6 g',
  confidence: 'high',
  portionNotes: '',
);

LoggedMeal _mahlzeit(String id) => LoggedMeal(
  id: id,
  result: _ergebnis(),
  loggedAt: DateTime(2026, 8, 21, 12, 30),
  forcedSlot: MealSlot.lunch,
);

Future<void> _pump(
  WidgetTester tester, {
  required bool mitEintrag,
  double textScale = 1.0,
  ValueChanged<MealSlot>? onAddToSlot,
  ValueChanged<String>? onRemoveMeal,
}) async {
  tester.view.physicalSize = const Size(_breite * 3, 844 * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await pumpLocalized(
    tester,
    DiaryMealCard(
      slot: MealSlot.lunch,
      entries: mitEintrag
          ? <DiaryEntry>[DiaryEntry(_mahlzeit('m1'), 0)]
          : const <DiaryEntry>[],
      onAddToSlot: onAddToSlot ?? (_) {},
      onRemoveMeal: onRemoveMeal,
    ),
    textScale: textScale,
    // Same 20/12 shell padding as the food tab in EatovaHomePage.
    padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
  );
  await tester.pump();
}

final Finder _knopf = find.byKey(const ValueKey('food-slot-add-lunch'));

/// The InkWell of the plus button: exactly the surface that answers a tap.
Finder get _trefferflaeche =>
    find.descendant(of: _knopf, matching: find.byType(InkWell));

/// The drawn forest chip inside the button.
Finder get _chip =>
    find.descendant(of: _knopf, matching: find.byType(Container));

/// The header's text column (slot name, summary, macros).
Finder get _spalte => find
    .descendant(of: find.byType(AppCard), matching: find.byType(Column))
    .at(1);

void main() {
  // The geometry claims are only worth something with the real app fonts: the
  // headless test font is about twice as wide (see diary_meal_card_macros).
  setUpAll(() async {
    final archivo = FontLoader('Archivo');
    for (final datei in const <String>[
      'assets/fonts/Archivo-Regular.ttf',
      'assets/fonts/Archivo-Medium.ttf',
      'assets/fonts/Archivo-SemiBold.ttf',
      'assets/fonts/Archivo-Bold.ttf',
    ]) {
      archivo.addFont(
        File(datei).readAsBytes().then((b) => ByteData.sublistView(b)),
      );
    }
    final bricolage = FontLoader('BricolageGrotesque');
    for (final datei in const <String>[
      'assets/fonts/BricolageGrotesque-Bold.ttf',
      'assets/fonts/BricolageGrotesque-ExtraBold.ttf',
    ]) {
      bricolage.addFont(
        File(datei).readAsBytes().then((b) => ByteData.sublistView(b)),
      );
    }
    await Future.wait(<Future<void>>[archivo.load(), bricolage.load()]);
  });

  group('Plus-Knopf der Slot-Karte', () {
    testWidgets('die Trefferflaeche misst 44 x 44, der Chip bleibt 32 x 32', (
      tester,
    ) async {
      await _pump(tester, mitEintrag: true);

      expect(_trefferflaeche, findsOneWidget);
      final ziel = tester.getSize(_trefferflaeche);
      expect(
        ziel.width,
        greaterThanOrEqualTo(44.0),
        reason: '32 px sind kein Fingerziel',
      );
      expect(ziel.height, greaterThanOrEqualTo(44.0));

      // Looks unchanged: the drawn chip stays 32x32 with a 17 pt glyph, the
      // extra area is transparent and sits outside it.
      expect(_chip, findsOneWidget);
      expect(tester.getSize(_chip), const Size(32, 32));
      expect(tester.widget<Icon>(find.byIcon(Icons.add_rounded)).size, 17.0);
    });

    testWidgets('ein Tap auf den durchsichtigen Saum bucht in den Slot', (
      tester,
    ) async {
      final gebucht = <MealSlot>[];
      await _pump(tester, mitEintrag: true, onAddToSlot: gebucht.add);

      // 4 pt inside the target's top-left corner — 2 pt OUTSIDE the drawn
      // chip. Before the fix this point was not part of the button at all and
      // landed in the dead card header.
      final ziel = tester.getRect(_knopf);
      expect(
        tester.getRect(_chip).contains(ziel.topLeft + const Offset(4, 4)),
        isFalse,
        reason: 'der Testpunkt muss neben dem sichtbaren Chip liegen',
      );

      await tester.tapAt(ziel.topLeft + const Offset(4, 4));
      await tester.pump();

      // Exactly once: the seam must not fire on top of the chip's own tap.
      expect(gebucht, <MealSlot>[MealSlot.lunch]);
    });

    // Deliberately anchored on the ICON and the card, not on the button's own
    // box: written that way these assertions hold on the pre-fix build too, so
    // they prove that the 44 pt target moved nothing that is painted.
    for (final scale in const <double>[1.0, 1.3, 2.0]) {
      testWidgets(
        'bei Textskalierung $scale steht im Kartenkopf alles unveraendert',
        (tester) async {
          await _pump(tester, mitEintrag: true, textScale: scale);

          final karte = tester.getRect(find.byType(AppCard));
          final glyph = tester.getRect(find.byIcon(Icons.add_rounded));
          final avatar = tester.getRect(find.byType(MealAvatar));
          final spalte = tester.getRect(_spalte);

          // GOLDEN (pre-fix build, 390 pt, scale 1.0): card 20..370,
          // avatar 36..72, text column 84..314, chip 322..354 — the chip is
          // 32 wide, so its centre sits 16 + 16 from the card edge.
          expect(glyph.center.dx, karte.right - _kartenrand - 16);
          expect(spalte.right, glyph.center.dx - 16 - _spalt);
          expect(avatar.left, karte.left + _kartenrand);
          expect(spalte.left, avatar.right + 12);

          // Vertically centred like before — and the header's height still
          // comes from the text column, not from the button: the first history
          // row sits exactly 14 pt (bottom padding) below the column.
          expect(glyph.center.dy, spalte.center.dy);
          expect(avatar.center.dy, spalte.center.dy);
          expect(
            tester
                .getRect(find.byKey(const ValueKey('food-history-entry-0')))
                .top,
            spalte.bottom + 14,
            reason: 'der Kopf darf durch das groessere Tippziel nicht wachsen',
          );
        },
      );
    }

    testWidgets('ohne Eintraege steht der Chip ebenso, nur der Kopf zahlt '
        'den Saum', (tester) async {
      await _pump(tester, mitEintrag: false);

      final karte = tester.getRect(find.byType(AppCard));
      final glyph = tester.getRect(find.byIcon(Icons.add_rounded));
      final kopf = tester.getRect(
        find
            .descendant(of: find.byType(AppCard), matching: find.byType(Row))
            .first,
      );

      expect(glyph.center.dx, karte.right - _kartenrand - 16);

      // The one place the floor costs something: an EMPTY header row is only
      // 40 pt tall at text scale 1.0, so it grows to the 44 of the button
      // (the card gets 4 pt taller). From scale 1.3 on, and on every card
      // with entries, the text column is the taller child and nothing moves.
      expect(kopf.height, 44.0);
    });

    testWidgets('ohne Add-Callback bleibt der Kartenkopf bei 15 pt Rand', (
      tester,
    ) async {
      // The compensation is tied to the button: no button, no transparent
      // margin to give back — otherwise the header would be lopsided.
      await pumpLocalized(
        tester,
        DiaryMealCard(
          slot: MealSlot.lunch,
          entries: <DiaryEntry>[DiaryEntry(_mahlzeit('m1'), 0)],
        ),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
      );
      await tester.pump();

      expect(_knopf, findsNothing);
      final karte = tester.getRect(find.byType(AppCard));
      expect(tester.getRect(_spalte).right, karte.right - _kartenrand);
    });
  });

  group('Weitere Bedienelemente der Karte', () {
    testWidgets('Tagebuchzeile und Loeschaktion liegen ueber dem Boden', (
      tester,
    ) async {
      await _pump(tester, mitEintrag: true, onRemoveMeal: (_) {});

      final zeile = find.byKey(const ValueKey('food-history-entry-0'));
      expect(
        tester
            .getSize(find.descendant(of: zeile, matching: find.byType(InkWell)))
            .height,
        greaterThanOrEqualTo(44.0),
      );

      await tester.drag(zeile, const Offset(-300, 0));
      await tester.pumpAndSettle();

      final loeschen = tester.getSize(
        find.byKey(const ValueKey('food-history-delete-0')),
      );
      expect(loeschen.width, greaterThanOrEqualTo(44.0));
      expect(loeschen.height, greaterThanOrEqualTo(44.0));
    });
  });
}
