import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/screens/meal_analysis_screen.dart';
import 'package:eatova/src/widgets/design/design.dart';

import 'support/harness.dart';

// Food owns its gutters; the capture dock sits above the app navigation.

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
      body: SafeArea(child: MealAnalysisScreen(dailyConsumedKcal: 0)),
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
  testWidgets('Food shows the selected date exactly once', (tester) async {
    await _pumpFoodTab(tester);
    final date = tester.widget<Text>(
      find.byKey(const ValueKey('food-date-selected-label')),
    );
    expect(find.text(date.data!), findsOneWidget);
    expect(
      find.byKey(const ValueKey('food-date-previous')).hitTestable(),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('food-date-calendar')).hitTestable(),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  // Removed: "Calories card shows the goal only once". The card is gone from
  // the food tab, which now names the daily goal nowhere. Its absence is
  // covered by food_diary_screen_test.dart, the goal itself by
  // kcal_goal_consistency_test.dart.

  testWidgets('Food action labels remain fully readable', (tester) async {
    await _pumpFoodTab(tester, textScale: 1.3);

    // The labels used to wrap to two lines and overflow the 64 px button.
    for (final key in const [
      ValueKey('food-action-barcode'),
      ValueKey('food-action-ai'),
      ValueKey('food-action-manual'),
    ]) {
      final label = tester.widget<Text>(
        find.descendant(of: find.byKey(key), matching: find.byType(Text)),
      );
      expect(label.data, isNot(contains('\n')));
      final paragraph = tester.renderObject<RenderParagraph>(
        find.descendant(of: find.byKey(key), matching: find.byType(Text)),
      );
      expect(paragraph.didExceedMaxLines, isFalse);
      expect(tester.getSize(find.byKey(key)).height, greaterThanOrEqualTo(44));
    }
  });
}
