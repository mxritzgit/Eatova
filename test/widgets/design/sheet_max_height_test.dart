import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/widgets/design/sheets.dart';

import 'design_harness.dart';

// Finding 2026-08-21: a sheet's header ended up under the Dynamic Island,
// because `size.height * 0.92` over a `Padding(bottom: viewInsets.bottom)`
// exceeded the screen height with the keyboard open.
//
// Pins [sheetMaxHeight] and checks against the real `showEatovaSheet` that it
// also holds inside a modal route's builder, where `removePadding(removeTop:
// true)` already zeroed `viewPadding.top` (see [sheetMaxHeightOf]).

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
      // iPhone SE (1st gen) with keyboard: 568 - 20 - 260 - 12 = 276 < 320.
      const se = MediaQueryData(
        size: Size(320, 568),
        viewPadding: EdgeInsets.only(top: 20),
        viewInsets: EdgeInsets.only(bottom: 260),
      );
      expect(sheetMaxHeight(se), kSheetMinHeight);

      // Absurdly small: still no negative or collapsed cap.
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

    /// Opens a sheet whose content breaks ANY cap (3000 px). The key sits on
    /// the scroller: inside one, the child always measures its full 3000 px.
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
      // The sheet starts at the earliest 12 pt below the safe area …
      expect(sheet.top, greaterThanOrEqualTo(_safeAreaOben + kSheetTopGap));
      // … and the builder content is trimmed to the cap minus the handle
      // padding instead of 3000 px.
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
      // It still sits above the keyboard, not behind it.
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

      // maxHeight is a cap, not a target: 120 px stay 120 px.
      expect(tester.getSize(find.byKey(inhalt)).height, 120);
    });
  });

  group('sheetMaxHeightOf', () {
    testWidgets('kennt die Safe-Area auch hinter removePadding(removeTop)',
        (tester) async {
      pinIphone14Pro(tester, keyboard: true);
      double? ausDerModalRoute;
      MediaQueryData? mediaQueryImBuilder;
      // Deliberately not measured at the button context: it hangs below the
      // scaffold body and a SafeArea, which strip the insets and padding.
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

      // The trap: inside the route builder the MediaQuery reports
      // `viewPadding.top == 0` (removePadding) but the keyboard just fine.
      expect(mediaQueryImBuilder!.viewPadding.top, 0);
      expect(mediaQueryImBuilder!.viewInsets.bottom, _tastatur);
      // The cap must know the safe area anyway.
      expect(
        ausDerModalRoute,
        _hoehe - _safeAreaOben - _tastatur - kSheetTopGap,
      );
    });
  });
}
