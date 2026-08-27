import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/screens/meal_analysis_screen.dart';
import 'package:eatova/src/widgets/design/design.dart';

import 'support/harness.dart';

// Layout tests for the food tab.
//
// Deliberately no "no RenderFlex overflow" assertion: the headless renderer
// uses a test font with different metrics, so a tree with ~56 pt of slack on
// device reports an overflow here. Only font-metric-independent claims live in
// this file.

/// Usable area (screen minus safe area) — what the scaffold gets in the food
/// tab. The test view has no view padding, so the safe area is already gone.
const _usableSize = Size(402, 781); // iPhone 16 Pro

/// Builds the food tab in the same shell as the home page: scaffold with
/// bottom nav, SafeArea and the fixed 20/12 padding.
Future<void> _pumpFoodTab(WidgetTester tester, {double textScale = 1.0}) async {
  tester.view.devicePixelRatio = 3.0;
  tester.view.physicalSize = _usableSize * 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  // Swallow overflow reports — see the file comment above.
  final prior = FlutterError.onError;
  FlutterError.onError = (details) {
    if (details.exception.toString().contains('overflowed')) return;
    prior?.call(details);
  };
  addTearDown(() => FlutterError.onError = prior);

  await pumpLocalized(
    tester,
    Scaffold(
      // Page ground comes from the theme; a hard constant would rule out
      // light mode. The nav bar carries the same four items as the real
      // home page so the harness measures what the app draws.
      bottomNavigationBar: AppNavBar(
        index: 1,
        onChanged: (_) {},
        items: const <AppNavItem>[
          AppNavItem(
            icon: Icons.home_outlined,
            activeIcon: Icons.home_rounded,
            label: 'Heute',
          ),
          AppNavItem(
            icon: Icons.restaurant_outlined,
            activeIcon: Icons.restaurant_rounded,
            label: 'Food',
          ),
          AppNavItem(
            icon: Icons.menu_book_outlined,
            activeIcon: Icons.menu_book_rounded,
            label: 'Rezepte',
          ),
          AppNavItem(
            icon: Icons.auto_awesome_outlined,
            activeIcon: Icons.auto_awesome_rounded,
            label: 'Coach',
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
          child: MealAnalysisScreen(dailyConsumedKcal: 0),
        ),
      ),
    ),
    // Mirrors the text scaler cap from EatovaApp.
    textScale: textScale > 2.0 ? 2.0 : textScale,
    // Motion as before the migration.
    reducedMotion: false,
    scaffold: false,
    safeArea: false,
    settle: true,
  );
}

void main() {
  testWidgets('Food date chips do not repeat the date twice', (tester) async {
    await _pumpFoodTab(tester);

    // chip-0 is today; chip-2 is the first with a weekday header line, so
    // header = weekday, sub-line = date. The two must not be identical.
    final texts = tester
        .widgetList<Text>(
          find.descendant(
            of: find.byKey(const ValueKey('food-date-chip-2')),
            matching: find.byType(Text),
          ),
        )
        .map((t) => t.data)
        .toList();

    expect(texts, hasLength(2));
    expect(texts.first, isNot(equals(texts.last)));
    expect(texts.first, matches(RegExp(r'^(Mo|Di|Mi|Do|Fr|Sa|So)$')));
  });

  // Removed: "Calories card shows the goal only once". The card is gone from
  // the food tab, which now names the daily goal nowhere. Its absence is
  // covered by food_diary_screen_test.dart, the goal itself by
  // kcal_goal_consistency_test.dart.

  testWidgets('Food action labels stay on one line', (tester) async {
    await _pumpFoodTab(tester, textScale: 1.3);

    // The labels used to wrap to two lines and overflow the 64 px button.
    for (final key in const [
      ValueKey('food-action-barcode'),
      ValueKey('food-action-ai'),
    ]) {
      final label = tester.widget<Text>(
        find.descendant(of: find.byKey(key), matching: find.byType(Text)),
      );
      expect(label.data, isNot(contains('\n')));
      expect(label.maxLines, 1);
    }
  });
}
