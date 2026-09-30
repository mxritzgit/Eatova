// Visual evidence for the Food tab of the dark redesign (Task 3).
//
// Mounts the real home page at the design's reference geometry with the
// design scenario (test/support/food_design_fixture.dart) and shoots the
// Food tab at the design's scroll positions: food-00 (top), food-01 (700)
// and food-02 (the end; the design's 746). With
// --dart-define=DARK_REDESIGN_CAPTURE=true the PNGs land in
// build/dark-redesign/ for comparison with design/shots/food-0N.png;
// without it the suite still checks the scenario's numbers and geometry.

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/eatova_home_page.dart';
import 'package:eatova/src/widgets/design/design.dart';

import '../flows/flow_test_helpers.dart' show storeOf;
import '../support/design_capture.dart';
import '../support/food_design_fixture.dart';
import '../support/harness.dart';

Future<void> _pumpFood(WidgetTester tester) async {
  pinDesignViewport(tester);
  await tester.pumpWidget(
    designCaptureBoundary(
      localizedApp(
        EatovaHomePage(),
        locale: const Locale('en'),
        safeArea: false,
        scaffold: false,
      ),
    ),
  );
  await tester.pumpAndSettle();
  storeOf(tester)
    ..profile = foodDesignProfile
    ..loggedMeals = foodDesignMeals();
  // The tab switch notifies the store, so the Food tab builds on the seed.
  await tester.tap(find.byKey(const ValueKey('nav-Food')));
  await tester.pumpAndSettle();
}

Finder _scroll() => find.descendant(
  of: find.byKey(const ValueKey('food-diary-scroll')),
  matching: find.byType(Scrollable),
);

void main() {
  setUpAll(loadDesignFonts);

  testWidgets('food-00..02: the design scenario on the Food tab', (
    tester,
  ) async {
    await withClock(Clock.fixed(foodDesignNow), () async {
      await _pumpFood(tester);

      // The scenario's numbers, from the store.
      expect(find.text('1,221'), findsOneWidget);
      expect(find.text('902'), findsOneWidget);
      expect(find.text('111 g'), findsOneWidget);
      expect(find.text('144 g'), findsOneWidget);
      expect(find.text('20 g'), findsOneWidget);
      expect(find.text('08:10 · 3 items'), findsOneWidget);
      expect(find.text('401'), findsOneWidget);
      expect(find.text('Suggested 550–700 kcal'), findsOneWidget);
      expect(find.text('FITS TONIGHT · 610 KCAL'), findsOneWidget);

      // The dock floats on the tab bar's band, 102 px above the edge.
      final band = AppNavBar.reservedHeightFor(kDesignSafeArea.bottom);
      expect(
        tester.getRect(find.byKey(const ValueKey('food-entry-dock'))).bottom,
        kDesignViewport.height - band,
      );
      expect(
        tester.getSize(find.byKey(const ValueKey('food-action-ai'))),
        const Size(54, 54),
      );

      await precacheDesignImages(tester);
      await captureDesignShot(tester, 'food-00');

      // The design's scrollTop counts from the screen top; since the tabs
      // run under the status bar (Task 8) the tab's offset is the same.
      final offset = await scrollDesignTabBy(
        tester,
        700,
        scrollable: _scroll(),
      );
      expect(offset, 700);
      await precacheDesignImages(tester);
      await captureDesignShot(tester, 'food-01');

      final position = tester.state<ScrollableState>(_scroll()).position;
      position.jumpTo(position.maxScrollExtent);
      await tester.pumpAndSettle();
      // Same content height as the design: its end (746) is ours too.
      expect(position.maxScrollExtent, closeTo(746, 12));
      await precacheDesignImages(tester);
      await captureDesignShot(tester, 'food-02');

      // At the end the last card clears the dock by the design's 44 px.
      final addSnacks = tester.getRect(
        find.byKey(const ValueKey('food-slot-add-snack')),
      );
      final dock = tester.getRect(
        find.byKey(const ValueKey('food-entry-dock')),
      );
      expect(dock.top - addSnacks.bottom, closeTo(44, 1));
      expect(tester.takeException(), isNull);
    });
  });
}
