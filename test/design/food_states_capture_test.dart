// Visual evidence for the Food states the design review found without a
// capture (2026-10-11): Today's and the Food diary's day loading, the
// "Choose day" calendar on another day and month, the scan preview with a
// picked suggestion, the analysis result's icon buttons, and the manual
// sheet's portion field focused and in error on its brand panel — each at
// the reference phone and at 320 px with 2x text.
//
// The suite only drives what the screens had before the polish too (texts,
// tooltips and existing keys), so it also renders the before shots. The
// calendar's keyboard state uses the month grid's day keys, which arrived
// with the polish; its before shot comes from the first polish round.
//
// With --dart-define=DARK_REDESIGN_CAPTURE=true the PNGs land in
// build/dark-redesign/food-states-*.png (light: DESIGN_CAPTURE_BRIGHTNESS=
// light); without it the suite checks that every state renders cleanly.

import 'dart:io';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_request.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/screens/meal_analysis_screen.dart';
import 'package:eatova/src/screens/today/today_screen.dart';
import 'package:eatova/src/widgets/kcal/food_date_picker.dart';
import 'package:eatova/src/widgets/kcal/manual_meal_sheet.dart';
import 'package:eatova/src/widgets/kcal/meal_analysis_sheet.dart';
import 'package:eatova/src/widgets/kcal/meal_scan_preview_sheet.dart';

import '../support/design_capture.dart';
import '../support/harness.dart';
import '../support/today_summary.dart';

final DateTime _now = DateTime(2026, 9, 28, 12);

const UserProfile _profile = UserProfile(
  dailyKcalGoal: 2200,
  proteinGoalG: 130,
  carbsGoalG: 240,
  fatGoalG: 70,
);

const MealAnalysisResult _bowl = MealAnalysisResult(
  mealName: 'Chicken rice bowl',
  caloriesKcal: 612,
  estimatedGrams: 430,
  kcalPer100G: 142,
  protein: '44 g',
  carbs: '68 g',
  fat: '16 g',
  confidence: 'medium',
  portionNotes: 'One bowl, rice and chicken visible.',
);

const List<(String, double, double)> _sizes = [
  ('', 390, 1),
  ('-320-x2', 320, 2),
];

/// The reference phone, narrowed to [width] logical pixels.
void _viewport(WidgetTester tester, double width) {
  pinDesignViewport(tester);
  tester.view.physicalSize =
      Size(width, kDesignViewport.height) * kDesignPixelRatio;
}

/// Pumps [child] at the reference geometry; a bounded settle, because the
/// old loading card spun forever.
Future<void> _mount(
  WidgetTester tester,
  Widget child, {
  required double width,
  required double textScale,
  bool scaffold = true,
}) async {
  _viewport(tester, width);
  await tester.pumpWidget(
    designCaptureBoundary(
      localizedApp(
        child,
        locale: const Locale('en'),
        safeArea: false,
        scaffold: scaffold,
        textScale: textScale,
      ),
    ),
  );
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Pumps a launcher button and taps it.
Future<void> _host(
  WidgetTester tester,
  void Function(BuildContext context) open, {
  required double width,
  required double textScale,
}) async {
  await _mount(
    tester,
    Builder(
      builder: (context) => Center(
        child: TextButton(
          onPressed: () => open(context),
          child: const Text('open'),
        ),
      ),
    ),
    width: width,
    textScale: textScale,
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadDesignFonts);

  for (final (suffix, width, scale) in _sizes) {
    testWidgets('Today: the day is loading$suffix', (tester) async {
      await withClock(Clock.fixed(_now), () async {
        await _mount(
          tester,
          // The shell supplies the Today tab's gutters.
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: TodayScreen(
              userName: 'Moritz',
              profile: _profile,
              summary: todaySummary(
                profile: _profile,
                consumedKcal: 0,
                burnedKcal: 0,
              ),
              meals: const [],
              selectedDate: DateTime(2026, 9, 20),
              streak: 4,
              dayLoading: true,
            ),
          ),
          width: width,
          textScale: scale,
        );
      });
      expect(
        find.byKey(const ValueKey('today-day-loading'), skipOffstage: false),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await captureDesignShot(tester, 'food-states-today-loading$suffix');
    });

    testWidgets('Food: the day is loading$suffix', (tester) async {
      await withClock(Clock.fixed(_now), () async {
        await _mount(
          tester,
          SizedBox.expand(
            child: MealAnalysisScreen(
              dailyConsumedKcal: 0,
              selectedDate: DateTime(2026, 9, 20),
              dayLoading: true,
            ),
          ),
          width: width,
          textScale: scale,
        );
      });
      expect(find.byKey(const ValueKey('food-day-loading')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await captureDesignShot(tester, 'food-states-food-loading$suffix');
    });

    testWidgets('Food: the day did not load$suffix', (tester) async {
      await withClock(Clock.fixed(_now), () async {
        await _mount(
          tester,
          SizedBox.expand(
            child: MealAnalysisScreen(
              dailyConsumedKcal: 0,
              selectedDate: DateTime(2026, 7, 20),
              dayLoadFailed: true,
              onRetryDayLoad: () {},
            ),
          ),
          width: width,
          textScale: scale,
        );
      });
      expect(find.byKey(const ValueKey('food-day-load-failed')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await captureDesignShot(tester, 'food-states-food-load-failed$suffix');
    });

    testWidgets('Choose day: another day, then the month before$suffix', (
      tester,
    ) async {
      await withClock(Clock.fixed(_now), () async {
        await _host(
          tester,
          (context) => showFoodDatePicker(
            context,
            initialDate: DateTime(2026, 9, 15),
            firstDate: DateTime(2024, 9, 28),
            today: DateTime(2026, 9, 28),
          ),
          width: width,
          textScale: scale,
        );
        expect(tester.takeException(), isNull);
        await captureDesignShot(tester, 'food-states-date-sheet$suffix');
        final previous = find.byTooltip('Previous month');
        await tester.ensureVisible(previous);
        await tester.pumpAndSettle();
        await tester.tap(previous);
        await tester.pumpAndSettle();
        expect(find.text('August 2026'), findsWidgets);
        expect(tester.takeException(), isNull);
        await captureDesignShot(tester, 'food-states-date-sheet-august$suffix');
      });
    });

    // Added with round 2 (keyboard paging): an arrow key past the month's
    // first day pages back and the focus ring lands on the 31st.
    testWidgets('Choose day: the keyboard pages past the 1st$suffix', (
      tester,
    ) async {
      await withClock(Clock.fixed(_now), () async {
        await _host(
          tester,
          (context) => showFoodDatePicker(
            context,
            initialDate: DateTime(2026, 9, 15),
            firstDate: DateTime(2024, 9, 28),
            today: DateTime(2026, 9, 28),
          ),
          width: width,
          textScale: scale,
        );
        final first = find.byKey(const ValueKey('food-date-day-2026-9-1'));
        Focus.of(
          tester.element(
            find.descendant(of: first, matching: find.byType(Text)),
          ),
        ).requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
        await tester.pumpAndSettle();
        final landed = find.byKey(const ValueKey('food-date-day-2026-8-31'));
        if (landed.evaluate().isNotEmpty) {
          await tester.ensureVisible(landed);
          await tester.pumpAndSettle();
        }
        expect(tester.takeException(), isNull);
        await captureDesignShot(
          tester,
          'food-states-date-sheet-keyboard$suffix',
        );
      });
    });

    testWidgets('scan preview with a picked suggestion$suffix', (tester) async {
      final photo = File('assets/recipes/lachs_poke_bowl.jpg').readAsBytesSync();
      await _host(
        tester,
        (context) => showMealScanPreviewSheet(
          context,
          request: MealAnalysisRequest(
            imageId: 'fixture-photo',
            imageBytes: photo,
          ),
          previewBytes: photo,
        ),
        width: width,
        textScale: scale,
      );
      final suggestion = find.text('without sauce');
      await tester.ensureVisible(suggestion);
      await tester.pumpAndSettle();
      await tester.tap(suggestion);
      await tester.pumpAndSettle();
      await precacheDesignImages(tester);
      expect(tester.takeException(), isNull);
      await captureDesignShot(tester, 'food-states-scan-picked$suffix');
    });

    testWidgets('analysis result with favourite and details$suffix', (
      tester,
    ) async {
      await _host(
        tester,
        (context) => showMealAnalysisSheet(
          context,
          slot: MealSlot.lunch,
          resultFuture: Future<MealAnalysisResult>.value(_bowl),
          previewImage: null,
          onAdd: (_, _) => 'id',
          onUpdateMeal: (_, _) {},
          failureMessage: 'failed',
          isFavorite: (_) => false,
          onToggleFavorite: (_) {},
        ),
        width: width,
        textScale: scale,
      );
      expect(tester.takeException(), isNull);
      await captureDesignShot(tester, 'food-states-analysis-actions$suffix');
    });

    testWidgets('manual sheet: the portion field focused, then in error'
        '$suffix', (tester) async {
      await _host(
        tester,
        (context) => showManualMealSheet(
          context,
          initialSlot: MealSlot.snack,
          contextLabel: 'Adds to Monday, Sep 28',
        ),
        width: width,
        textScale: scale,
      );
      final grams = find.byKey(const ValueKey('manual-meal-grams'));
      await tester.ensureVisible(grams);
      await tester.pumpAndSettle();
      await tester.tap(grams);
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('manual-portion-panel')),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await captureDesignShot(tester, 'food-states-manual-focus$suffix');
      await tester.enterText(grams, '0');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('manual-portion-panel')),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await captureDesignShot(tester, 'food-states-manual-error$suffix');
    });
  }
}
