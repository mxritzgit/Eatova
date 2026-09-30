// The real shell with motion on (polish 2026-10-01): a tap in the tab bar
// fades through to the new tab, the pill ends under the new item, the switch
// clicks once, and the tab that was left keeps its state.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/eatova_home_page.dart';
import 'package:eatova/src/app/home_tab_switcher.dart';
import 'package:eatova/src/screens/meal_analysis_screen.dart';
import 'package:eatova/src/screens/today/today_screen.dart';
import 'package:eatova/src/widgets/design/app_icon.dart';
import 'package:eatova/src/widgets/design/controls.dart';

import '../support/harness.dart';

Future<void> _pumpHome(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1179, 2556);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  // Headless font metrics produce overflows that never happen on a device
  // (same reasoning as test/flows/flow_test_helpers.dart).
  final prior = FlutterError.onError;
  FlutterError.onError = (details) {
    if (details.exception.toString().contains('overflowed')) return;
    prior?.call(details);
  };
  addTearDown(() => FlutterError.onError = prior);

  await pumpLocalized(
    tester,
    EatovaHomePage(),
    scaffold: false,
    safeArea: false,
    reducedMotion: false,
  );
  await _frames(tester, 40);
}

// Bounded frames instead of pumpAndSettle: some tabs animate forever.
Future<void> _frames(WidgetTester tester, int count) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

HomeTabSwitcherState _switcher(WidgetTester tester) =>
    tester.state<HomeTabSwitcherState>(
      find.byKey(const ValueKey<String>('home-tab-stack')),
    );

void main() {
  testWidgets('Tab-Tipp blendet zum Food-Tab durch, klickt einmal, und die '
      'Kapsel endet unter Food', (tester) async {
    final haptics = <Object?>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'HapticFeedback.vibrate') haptics.add(call.arguments);
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await _pumpHome(tester);
    final todayElement = tester.element(find.byType(TodayScreen));

    await tester.tap(find.byKey(const ValueKey<String>('nav-Food')));
    await tester.pump();
    await _frames(tester, 4);

    final s = _switcher(tester);
    expect(s.visibilityOf(0), inExclusiveRange(0, 1));
    expect(s.visibilityOf(1), inExclusiveRange(0, 1));
    // The incoming tab is live at once; the outgoing one is a fading picture.
    expect(find.byType(MealAnalysisScreen), findsOneWidget);
    expect(find.byType(TodayScreen), findsNothing);

    await _frames(tester, 20);
    expect(s.visibilityOf(0), 0);
    expect(s.visibilityOf(1), 1);
    expect(haptics, <Object?>['HapticFeedbackType.selectionClick']);
    expect(
      AppNavBar.debugPillRect(
        tester.renderObject(find.byKey(const ValueKey<String>('nav-pill'))),
      )!.center,
      offsetMoreOrLessEquals(
        tester.getCenter(
          find.byWidgetPredicate(
            (w) => w is AppIcon && w.symbol == AppSymbol.food,
          ),
        ),
      ),
    );

    // Re-tap: no second click, still on Food.
    await tester.tap(find.byKey(const ValueKey<String>('nav-Food')));
    await _frames(tester, 20);
    expect(haptics, hasLength(1));
    expect(s.visibilityOf(1), 1);

    await tester.tap(find.byKey(const ValueKey<String>('nav-Heute')));
    await _frames(tester, 24);
    expect(s.visibilityOf(0), 1);
    expect(identical(tester.element(find.byType(TodayScreen)), todayElement),
        isTrue,
        reason: 'der Heute-Tab bleibt gemountet (D6)');
  });
}
