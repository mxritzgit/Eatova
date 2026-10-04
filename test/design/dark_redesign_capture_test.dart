// Visual evidence for the dark redesign (plan 2026-09-28).
//
// Mounts the real home page at the design's reference geometry with a fixed
// clock (Mon 2026-09-28 19:00) and shoots every tab at the top
// (`shell-<tab>-00`), in English like the design's sample copy. The design-
// matching fixtures and the `<tab>-NN` shots live in each tab's own
// `<tab>_redesign_capture_test.dart`; the `shell-` prefix keeps these shots
// from overwriting them.
//
// With --dart-define=DARK_REDESIGN_CAPTURE=true the shots land in
// build/dark-redesign/ for comparison with the design's shots/. Without it
// the suite still checks that each tab renders on the dark page with the
// floating nav bar and its own item selected, and that scrolled content runs
// under the glass (`shell-recipes-01`).

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/eatova_home_page.dart';
import 'package:eatova/src/widgets/design/design.dart';

import '../flows/flow_test_helpers.dart' show storeOf;
import '../support/design_capture.dart';
import '../support/harness.dart';

final _now = DateTime(2026, 9, 28, 19);

/// Shot name and the (German, API) nav key of each tab, in bar order.
const _tabs = <(String, String)>[
  ('today', 'Heute'),
  ('food', 'Food'),
  ('recipes', 'Rezepte'),
  ('training', 'Training'),
  ('coach', 'Coach'),
];

Rect _glass(WidgetTester tester) =>
    tester.getRect(find.byKey(const ValueKey('nav-glass')));

Future<void> _pumpHome(WidgetTester tester) async {
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
}

void main() {
  setUpAll(loadDesignFonts);

  for (final (shot, navKey) in _tabs) {
    testWidgets('shell-$shot-00: dark page, glass nav, $navKey selected', (
      tester,
    ) async {
      await withClock(Clock.fixed(_now), () async {
        final semantics = tester.ensureSemantics();
        try {
          await _pumpHome(tester);
          final nav = find.byKey(ValueKey('nav-$navKey'));
          await tester.tap(nav);
          await tester.pumpAndSettle();

          expect(storeOf(tester).selectedTab, _tabs.indexOf((shot, navKey)));
          expect(tester.getSemantics(nav), isSemantics(isSelected: true));
          for (final (_, other) in _tabs.where((tab) => tab.$2 != navKey)) {
            expect(
              tester.getSemantics(find.byKey(ValueKey('nav-$other'))),
              isSemantics(isSelected: false),
            );
          }

          final scaffold = tester.widget<Scaffold>(
            find
                .descendant(
                  of: find.byType(EatovaHomePage),
                  matching: find.byType(Scaffold),
                )
                .first,
          );
          expect(scaffold.backgroundColor, designCaptureTokens.bg);
          expect(scaffold.extendBody, isTrue);

          // The glass bar floats 14 px from the sides and 22 px above the
          // screen edge; the 34 px home indicator sits in that gap.
          final glass = _glass(tester);
          expect(glass.left, AppNavBar.sideGap);
          expect(glass.right, kDesignViewport.width - AppNavBar.sideGap);
          expect(glass.bottom, kDesignViewport.height - AppNavBar.bottomGap);
          expect(glass.height, AppNavBar.barHeight);

          await precacheDesignImages(tester);
          await captureDesignShot(tester, 'shell-$shot-00');
          expect(tester.takeException(), isNull);
        } finally {
          semantics.dispose();
        }
      });
    });
  }

  testWidgets('pinned bottom elements sit on the bar\'s band, '
      '12 px above the glass', (tester) async {
    await withClock(Clock.fixed(_now), () async {
      await _pumpHome(tester);
      final band = AppNavBar.reservedHeightFor(kDesignSafeArea.bottom);
      final line = kDesignViewport.height - band;
      expect(line, _glass(tester).top - AppNavBar.clearance);

      // Today has no pinned action since its redesign (Task 2): the page
      // scrolls under the bar, see today_redesign_capture_test.dart.

      // Food: the search/scan dock.
      await tester.tap(find.byKey(const ValueKey('nav-Food')));
      await tester.pumpAndSettle();
      expect(tester.getRect(find.byKey(const ValueKey('food-entry-dock'))).bottom,
          line);

      // Coach: the composer capsule.
      await tester.tap(find.byKey(const ValueKey('nav-Coach')));
      await tester.pumpAndSettle();
      final capsule = find.ancestor(
        of: find.byKey(const ValueKey('coach-input')),
        matching: find.byType(FieldCapsule),
      );
      // On the band; the composer keeps a few px of its own spacing below.
      expect(
        tester.getRect(capsule).bottom,
        inInclusiveRange(line - 8, line),
      );
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('shell-recipes-01: scrolled content runs under the glass bar', (
    tester,
  ) async {
    await withClock(Clock.fixed(_now), () async {
      await _pumpHome(tester);
      await tester.tap(find.byKey(const ValueKey('nav-Rezepte')));
      await tester.pumpAndSettle();

      final list = find.byKey(const ValueKey('screen-recipes'));
      // The list reaches the screen edge (it scrolls under the bar) and pads
      // its end by the bar's band, so its last item can still clear the bar.
      expect(tester.getRect(list).bottom, kDesignViewport.height);
      final scrollable = find
          .descendant(of: list, matching: find.byType(Scrollable))
          .first;
      final offset = await scrollDesignTabBy(
        tester,
        383,
        scrollable: scrollable,
      );
      expect(offset, 383, reason: 'design shot recipes-01 sits at 383');

      final glass = _glass(tester);
      final underGlass = tester
          .renderObjectList<RenderBox>(
            find.descendant(of: list, matching: find.byType(RichText)),
          )
          .where(
            (box) => (box.localToGlobal(Offset.zero) & box.size).overlaps(
              glass,
            ),
          );
      expect(underGlass, isNotEmpty, reason: 'text scrolls under the glass');

      await precacheDesignImages(tester);
      await captureDesignShot(tester, 'shell-recipes-01');

      // Scrolled to the end, the last content ends above the bar's band.
      final position = tester.state<ScrollableState>(scrollable).position;
      position.jumpTo(position.maxScrollExtent);
      await tester.pumpAndSettle();
      final bottoms = tester
          .renderObjectList<RenderBox>(
            find.descendant(of: list, matching: find.byType(RichText)),
          )
          .map((box) => (box.localToGlobal(Offset.zero) & box.size).bottom);
      expect(
        bottoms.reduce((a, b) => a > b ? a : b),
        lessThanOrEqualTo(
          kDesignViewport.height -
              AppNavBar.reservedHeightFor(kDesignSafeArea.bottom),
        ),
      );
      expect(tester.takeException(), isNull);
    });
  });
}
