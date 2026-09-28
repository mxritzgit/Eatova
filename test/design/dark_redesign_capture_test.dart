// Visual evidence for the dark redesign (plan 2026-09-28).
//
// Mounts the real home page at the design's reference geometry with a fixed
// clock (Mon 2026-09-28 19:00) and shoots every tab at the top (`<tab>-00`),
// in English like the design's sample copy. Later tasks add design-matching
// fixtures and scroll shots (`<tab>-01…`, see `scrollDesignTabBy`) per tab.
//
// With --dart-define=DARK_REDESIGN_CAPTURE=true the shots land in
// build/dark-redesign/ for comparison with the design's shots/. Without it
// the suite still checks that each tab renders on the dark page with the
// floating nav bar and its own item selected.

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/eatova_home_page.dart';
import 'package:eatova/src/theme/app_tokens.dart';
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
    testWidgets('$shot-00: dark page, floating nav, $navKey selected', (
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
          expect(scaffold.backgroundColor, AppTokens.dark.bg);
          expect(scaffold.extendBody, isTrue);

          // The glass bar floats 14 px from the sides and 22 px above the
          // 34 px home-indicator inset.
          final glass = tester.getRect(
            find.byKey(const ValueKey('nav-glass')),
          );
          expect(glass.left, AppNavBar.sideGap);
          expect(glass.right, kDesignViewport.width - AppNavBar.sideGap);
          expect(
            glass.bottom,
            kDesignViewport.height -
                kDesignSafeArea.bottom -
                AppNavBar.bottomGap,
          );
          expect(glass.height, AppNavBar.barHeight);

          await precacheDesignImages(tester);
          await captureDesignShot(tester, '$shot-00');
          expect(tester.takeException(), isNull);
        } finally {
          semantics.dispose();
        }
      });
    });
  }
}
