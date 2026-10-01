import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
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
            icon: AppSymbol.today,
            label: 'Heute',
          ),
          AppNavItem(
            icon: AppSymbol.food,
            label: 'Food',
          ),
          AppNavItem(
            icon: AppSymbol.recipes,
            label: 'Rezepte',
          ),
          AppNavItem(
            icon: AppSymbol.coach,
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
  // the food tab, which now names the daily goal nowhere. The history's place
  // above the fold is pinned in food_diary_screen_test.dart, the goal itself
  // in kcal_goal_consistency_test.dart.

  testWidgets('Food dock controls keep their targets and full labels', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await _pumpFoodTab(tester, textScale: 1.3);

    // The round buttons are icon-only; their names live in semantics, and
    // the capsule's placeholder never wraps out of the 54 px dock.
    for (final (key, label) in [
      ('food-action-barcode', deL10n.foodScanBarcodeTooltip),
      ('food-action-ai', deL10n.foodDockCameraLabel),
      ('food-search', deL10n.foodDockSearchLabel),
    ]) {
      final size = tester.getSize(find.byKey(ValueKey(key)));
      expect(size.height, greaterThanOrEqualTo(44), reason: key);
      expect(size.width, greaterThanOrEqualTo(44), reason: key);
      expect(find.bySemanticsLabel(label), findsOneWidget, reason: key);
    }
    final placeholder = tester.renderObject<RenderParagraph>(
      find.descendant(
        of: find.byKey(const ValueKey('food-search')),
        matching: find.byType(RichText),
      ),
    );
    expect(placeholder.maxLines, 1);
    expect(
      tester.getSize(find.byKey(const ValueKey('food-entry-dock'))).height,
      54,
    );
    semantics.dispose();
  });
}
