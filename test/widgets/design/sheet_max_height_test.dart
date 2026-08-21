import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/widgets/design/sheets.dart';

import 'design_harness.dart';

// Nutzer-Befund 2026-08-21 (iPhone): Tipp auf einen Slot im Food-Tab, das
// Add-Meal-Sheet oeffnet — und sein Kopf (Kamera/Galerie/Barcode) liegt unter
// der Dynamic Island. Ursache war der feste Deckel `size.height * 0.92` ueber
// einem `Padding(bottom: viewInsets.bottom)`: mit offener Tastatur stieg die
// Summe ueber die Bildschirmhoehe, die Route klemmte das Sheet bis an den
// oberen Rand.
//
// Diese Datei nagelt die Rechenregel [sheetMaxHeight] fest — und prueft am
// echten `showEatovaSheet`, dass sie AUCH im Builder einer Modal-Route
// greift, wo `MediaQuery.removePadding(removeTop: true)` das `viewPadding.top`
// bereits auf 0 gezogen hat (s. [sheetMaxHeightOf]). Die Geraete-Insets
// setzt [pinIphone14Pro] aus dem Harness.

const double _hoehe = 844;
const double _safeAreaOben = 59;
const double _tastatur = 336;

void main() {
  group('sheetMaxHeight (reine Funktion)', () {
    test('zieht Safe-Area, Tastatur und 12 pt Luft von der Hoehe ab', () {
      const mq = MediaQueryData(
        size: Size(390, _hoehe),
        viewPadding: EdgeInsets.only(top: _safeAreaOben, bottom: 34),
        viewInsets: EdgeInsets.only(bottom: _tastatur),
      );
      expect(
        sheetMaxHeight(mq),
        _hoehe - _safeAreaOben - _tastatur - kSheetTopGap,
      );
    });

    test('ohne Tastatur bleibt nur Safe-Area plus Luft abgezogen', () {
      const mq = MediaQueryData(
        size: Size(390, _hoehe),
        viewPadding: EdgeInsets.only(top: _safeAreaOben, bottom: 34),
      );
      expect(sheetMaxHeight(mq), _hoehe - _safeAreaOben - kSheetTopGap);
    });

    test('ohne Safe-Area und Tastatur ist es die Hoehe minus Luft', () {
      const mq = MediaQueryData(size: Size(800, 600));
      expect(sheetMaxHeight(mq), 600 - kSheetTopGap);
    });

    test('faellt nie unter kSheetMinHeight', () {
      // iPhone SE (1. Gen.) mit Tastatur: 568 - 20 - 260 - 12 = 276 < 320.
      const se = MediaQueryData(
        size: Size(320, 568),
        viewPadding: EdgeInsets.only(top: 20),
        viewInsets: EdgeInsets.only(bottom: 260),
      );
      expect(sheetMaxHeight(se), kSheetMinHeight);

      // Absurd klein — auch dann kein negativer oder kollabierter Deckel.
      const winzig = MediaQueryData(
        size: Size(100, 100),
        viewInsets: EdgeInsets.only(bottom: 400),
      );
      expect(sheetMaxHeight(winzig), kSheetMinHeight);
    });

    test('die Konstanten stehen so, wie die Formel es verspricht', () {
      expect(kSheetTopGap, 12);
      expect(kSheetMinHeight, 320);
    });
  });

  group('showEatovaSheet deckelt nach sheetMaxHeight', () {
    const inhalt = ValueKey('sheet-max-height-inhalt');

    /// Oeffnet ein Sheet, dessen Inhalt JEDEN Deckel reisst (3000 px). Der
    /// Key sitzt am Scroller (dem Viewport) — sein Kind misst in einem
    /// Scroller immer seine vollen 3000 px, egal wie hoch das Sheet ist.
    Future<void> oeffne(WidgetTester tester) async {
      await tester.pumpWidget(
        designHarness(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => showEatovaSheet<void>(
                context,
                const SingleChildScrollView(
                  key: inhalt,
                  child: SizedBox(height: 3000),
                ),
              ),
              child: const Text('oeffnen'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('oeffnen'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }

    testWidgets('mit Tastatur bleibt die Oberkante unter der Dynamic Island',
        (tester) async {
      pinIphone14Pro(tester, keyboard: true);
      await oeffne(tester);

      final sheet = tester.getRect(find.byType(BottomSheet));
      // Das Sheet beginnt fruehestens 12 pt unter der Safe-Area …
      expect(sheet.top, greaterThanOrEqualTo(_safeAreaOben + kSheetTopGap));
      // … und der Builder-Inhalt (unter dem 48 pt hohen Griff-Polster) ist
      // auf den Deckel minus Griff gestutzt statt auf 3000 px.
      const deckel = _hoehe - _safeAreaOben - _tastatur - kSheetTopGap;
      final inhaltRect = tester.getRect(find.byKey(inhalt));
      expect(
        inhaltRect.height,
        lessThanOrEqualTo(deckel - kMinInteractiveDimension),
      );
      expect(
        inhaltRect.top,
        greaterThanOrEqualTo(
          _safeAreaOben + kSheetTopGap + kMinInteractiveDimension,
        ),
      );
      // Es sitzt weiterhin ueber der Tastatur, nicht dahinter.
      expect(inhaltRect.bottom, lessThanOrEqualTo(_hoehe - _tastatur));
    });

    testWidgets('ohne Tastatur ebenso', (tester) async {
      pinIphone14Pro(tester);
      await oeffne(tester);

      final sheet = tester.getRect(find.byType(BottomSheet));
      expect(sheet.top, greaterThanOrEqualTo(_safeAreaOben + kSheetTopGap));
      expect(
        sheet.height,
        lessThanOrEqualTo(_hoehe - _safeAreaOben - kSheetTopGap),
      );
      expect(
        tester.getRect(find.byKey(inhalt)).height,
        lessThanOrEqualTo(
          _hoehe - _safeAreaOben - kSheetTopGap - kMinInteractiveDimension,
        ),
      );
    });

    testWidgets('ein kurzer Inhalt wird nicht aufgeblasen', (tester) async {
      pinIphone14Pro(tester);
      await tester.pumpWidget(
        designHarness(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => showEatovaSheet<void>(
                context,
                const SizedBox(key: inhalt, height: 120),
              ),
              child: const Text('oeffnen'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('oeffnen'));
      await tester.pumpAndSettle();

      // maxHeight ist ein Deckel, keine Vorgabe: 120 px bleiben 120 px.
      expect(tester.getSize(find.byKey(inhalt)).height, 120);
    });
  });

  group('sheetMaxHeightOf', () {
    testWidgets('kennt die Safe-Area auch hinter removePadding(removeTop)',
        (tester) async {
      pinIphone14Pro(tester, keyboard: true);
      double? ausDerModalRoute;
      MediaQueryData? mediaQueryImBuilder;
      // Bewusst NICHT am Knopf-Kontext gemessen: der haengt im Harness unter
      // Scaffold-Body (nimmt die Tastatur-Insets weg) und SafeArea (nimmt
      // das Padding weg) — dort ist 773 der richtige Wert, nicht 437.
      await tester.pumpWidget(
        designHarness(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => showEatovaSheet<void>(
                context,
                Builder(
                  builder: (sheetContext) {
                    mediaQueryImBuilder = MediaQuery.of(sheetContext);
                    ausDerModalRoute = sheetMaxHeightOf(sheetContext);
                    return const SizedBox(height: 40);
                  },
                ),
              ),
              child: const Text('oeffnen'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('oeffnen'));
      await tester.pumpAndSettle();

      // Genau hier lag die Falle: im Builder der Route meldet die MediaQuery
      // `viewPadding.top == 0` (removePadding), die Tastatur aber sehr wohl.
      expect(mediaQueryImBuilder!.viewPadding.top, 0);
      expect(mediaQueryImBuilder!.viewInsets.bottom, _tastatur);
      // Der Deckel muss die Safe-Area trotzdem kennen.
      expect(
        ausDerModalRoute,
        _hoehe - _safeAreaOben - _tastatur - kSheetTopGap,
      );
    });
  });
}
