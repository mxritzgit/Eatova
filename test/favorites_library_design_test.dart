import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eatova/src/models/favorite_meal.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/widgets/kcal/favorites_sheet.dart';
import 'package:eatova/src/widgets/kcal/saved_meal_presentation.dart';
import 'support/harness.dart';

const _meal = MealAnalysisResult(
  mealName: 'Skyr',
  caloriesKcal: 420,
  estimatedGrams: 300,
  kcalPer100G: 78,
  protein: '30 g',
  carbs: '40 g',
  fat: '12 g',
  confidence: '',
  portionNotes: '',
);
Finder _key(String key) => find.byKey(ValueKey(key));

Future<void> _open(
  WidgetTester tester, {
  double scale = 1,
  double width = 393,
  bool keyboard = false,
  Locale locale = const Locale('de'),
  Brightness brightness = Brightness.light,
  MealAnalysisResult meal = _meal,
  String Function(MealAnalysisResult, MealSlot)? onAdd,
}) async {
  tester.view.physicalSize = Size(width, 852);
  tester.view.devicePixelRatio = 1;
  tester.view.viewPadding = const FakeViewPadding(top: 44, bottom: 24);
  tester.view.viewInsets = FakeViewPadding(bottom: keyboard ? 300 : 0);
  tester.view.padding = FakeViewPadding(top: 44, bottom: keyboard ? 0 : 24);
  addTearDown(tester.view.reset);
  await pumpLocalized(
    tester,
    Builder(
      builder: (context) => TextButton(
        onPressed: () => showFavoritesSheet(
          context,
          favorites: [
            FavoriteMeal(
              id: 'saved',
              result: meal,
              addedAt: DateTime(2026, 9, 11),
              pinned: true,
            ),
          ],
          slot: MealSlot.dinner,
          onAdd: onAdd ?? (_, __) => 'id',
          onUnpin: (_) {},
        ),
        child: const Text('open'),
      ),
    ),
    locale: locale,
    brightness: brightness,
    textScale: scale,
    safeArea: false,
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'saved portion calories match the edited amount actually logged',
    (tester) async {
      final logged = <(MealAnalysisResult, MealSlot)>[];
      await _open(
        tester,
        onAdd: (result, slot) {
          logged.add((result, slot));
          return 'id';
        },
      );
      expect(find.text('420 kcal'), findsOneWidget);
      expect(find.text('78 kcal / 100 g'), findsNothing);
      expect(find.text('Gespeicherte Portion · 300 g'), findsOneWidget);
      await tester.tap(find.text('Skyr'));
      await tester.pumpAndSettle();
      final grams = find.descendant(
        of: _key('favorites-sheet-item-0'),
        matching: find.byType(TextField),
      );
      await tester.enterText(grams, '150');
      await tester.pumpAndSettle();
      expect(find.text('210 kcal'), findsOneWidget);
      expect(find.byType(SavedMealNutrients), findsOneWidget);
      await tester.enterText(grams, '12000');
      await tester.pumpAndSettle();
      final add = _key('favorites-sheet-add-0');
      expect(tester.widget<FilledButton>(add).onPressed, isNull);
      expect(logged, isEmpty);
      await tester.enterText(grams, '600');
      await tester.pumpAndSettle();
      expect(find.text('840 kcal'), findsOneWidget);
      await tester.ensureVisible(add);
      await tester.pumpAndSettle();
      await tester.tap(add);
      await tester.pumpAndSettle();
      expect(logged.single.$1.caloriesKcal, 840);
      expect(logged.single.$1.estimatedGrams, 600);
      expect(logged.single.$2, MealSlot.dinner);
      expect(_key('favorites-sheet'), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(
        tester.getRect(find.byType(SnackBar)).bottom,
        lessThanOrEqualTo(852 - 24),
      );
      await tester.pump(const Duration(seconds: 4));
    },
  );

  for (final brightness in Brightness.values) {
    for (final locale in [const Locale('de'), const Locale('en')]) {
      testWidgets(
        'library controls remain reachable with 2x text and keyboard: $brightness $locale',
        (tester) async {
          await _open(
            tester,
            width: 320,
            scale: 2,
            keyboard: true,
            brightness: brightness,
            locale: locale,
          );
          expect(_key('favorites-sheet-close').hitTestable(), findsOneWidget);
          final search = _key('favorites-sheet-search');
          expect(search.hitTestable(), findsOneWidget);
          final title = find.text('Skyr');
          await tester.ensureVisible(title);
          await tester.pumpAndSettle();
          await tester.tap(title);
          await tester.pumpAndSettle();
          final add = _key('favorites-sheet-add-0');
          await tester.ensureVisible(add);
          await tester.pumpAndSettle();
          expect(add.hitTestable(), findsOneWidget);
          await tester.tap(add);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(
            tester.getRect(find.byType(SnackBar)).bottom,
            lessThanOrEqualTo(852 - 300),
          );
          await tester.pump(const Duration(seconds: 4));
          await tester.pumpAndSettle();
          final unpin = _key('favorites-sheet-fav-0');
          await tester.ensureVisible(unpin);
          await tester.pumpAndSettle();
          expect(unpin.hitTestable(), findsOneWidget);
          expect(tester.getSize(unpin).height, greaterThanOrEqualTo(44));
          await tester.enterText(search, 'nothing');
          await tester.pumpAndSettle();
          final noMatch = _key('favorites-sheet-no-match');
          final reset = find.descendant(
            of: noMatch,
            matching: find.byType(TextButton),
          );
          await tester.ensureVisible(reset);
          await tester.pumpAndSettle();
          await tester.tap(reset);
          await tester.pumpAndSettle();
          expect(tester.widget<TextField>(search).controller!.text, isEmpty);
          expect(find.text('Skyr'), findsOneWidget);
          await tester.tap(_key('favorites-sheet-close'));
          await tester.pumpAndSettle();
          expect(_key('favorites-sheet'), findsNothing);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
