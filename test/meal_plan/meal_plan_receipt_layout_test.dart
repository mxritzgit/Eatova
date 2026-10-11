// Where the receipt's small print breaks (2026-10-11), with the bundled
// fonts: the pantry line and a row's detail line wrap between words or after
// a separator, never inside a word, and no line starts with "·" or "+".

import 'package:clock/clock.dart';
import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/planned_meal.dart';
import 'package:eatova/src/screens/recipes/meal_plan_screen.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../outbox/outbox_test_helpers.dart' as h;
import '../support/design_capture.dart';
import '../support/harness.dart';

/// A Monday, so the shown week is Sep 7 to Sep 13.
final _today = DateTime(2026, 9, 7, 12);

Finder _key(String key) => find.byKey(ValueKey(key));

Future<HomeStore> _week(
  WidgetTester tester,
  Map<MealSlot, String> tuesday, {
  required Size size,
  required double textScale,
}) async {
  final store = HomeStore(
    sync: null,
    health: const NoopHealthService(),
    notificationService: const NoopNotificationService(),
    initialUserName: 'Fixture',
    emitSnack: h.SnackCapture().call,
  );
  addTearDown(store.dispose);
  for (final MapEntry(key: slot, value: ingredients) in tuesday.entries) {
    await store.savePlannedMeal(
      PlannedMeal.create(
        recipe: recipeCatalogDe.first.copyWith(
          slug: 'user_${slot.name}',
          title: slot.name,
          ingredients: ingredients,
          structuredIngredients: const [],
        ),
        day: DateTime(2026, 9, 8),
        slot: slot,
      ),
    );
  }
  await pumpLocalized(
    tester,
    MealPlanScreen(store: store),
    locale: const Locale('de'),
    surfaceSize: size,
    textScale: textScale,
    reducedMotion: true,
    settle: true,
  );
  await tester.tap(_key('meal-plan-tab-shopping'));
  await tester.pumpAndSettle();
  return store;
}

/// Every place [paragraph] wraps to a new line.
List<int> _breaks(RenderParagraph paragraph) {
  final text = paragraph.text.toPlainText();
  final breaks = <int>[];
  double? previous;
  for (var i = 0; i < text.length; i++) {
    final y = paragraph
        .getOffsetForCaret(TextPosition(offset: i), Rect.zero)
        .dy;
    if (previous != null && y > previous + 1) breaks.add(i);
    previous = y;
  }
  return breaks;
}

/// Each paragraph under [finder] wraps only after a space and never puts
/// "·" or "+" at the start of a line.
void _expectWordBreaks(WidgetTester tester, Finder finder, String reason) {
  final paragraphs = tester.renderObjectList<RenderParagraph>(
    find.descendant(of: finder, matching: find.byType(RichText)),
  );
  expect(paragraphs, isNotEmpty, reason: reason);
  for (final paragraph in paragraphs) {
    final text = paragraph.text.toPlainText();
    for (final at in _breaks(paragraph)) {
      final context =
          '$reason: "${text.substring(0, at)}|${text.substring(at)}"';
      expect(text[at - 1], anyOf(' ', '\n'), reason: context);
      expect(text[at], isNot(anyOf('·', '+')), reason: context);
    }
  }
}

void main() {
  setUpAll(loadDesignFonts);

  for (final width in [320.0, 360.0]) {
    testWidgets('Vorrat eingeklappt bei ${width.toInt()} px und 2x Text', (
      tester,
    ) async {
      await withClock(Clock.fixed(_today), () async {
        await _week(
          tester,
          {
            MealSlot.dinner:
                '2 EL Olivenöl zum Braten\n1 EL Rapsöl zum Anbraten\n'
                'Salz, Pfeffer',
          },
          size: Size(width, 900),
          textScale: 2,
        );
        final summary = _key('shopping-pantry-summary');
        await tester.ensureVisible(summary);
        await tester.pumpAndSettle();
        _expectWordBreaks(tester, summary, 'pantry at $width');
        expect(tester.takeException(), isNull);
      });
    });
  }

  for (final (width, scale, tuesday) in [
    // Two units on a day with two meals.
    (
      320.0,
      1.0,
      {
        MealSlot.breakfast: '100 g Spinat\n1 Handvoll Spinat',
        MealSlot.lunch: '200 g Spinat',
      },
    ),
    (
      360.0,
      1.15,
      {
        MealSlot.breakfast: '100 g Spinat\n1 Handvoll Spinat',
        MealSlot.lunch: '200 g Spinat',
      },
    ),
    // One amount, system text a size up, just below the stacked layout.
    (
      320.0,
      1.3,
      {
        MealSlot.breakfast: '1 1/2 Handvoll Spinat',
        MealSlot.lunch: '200 g Spinat',
      },
    ),
    (
      375.0,
      1.35,
      {
        MealSlot.breakfast: '1 1/2 Handvoll Spinat',
        MealSlot.lunch: '200 g Spinat',
      },
    ),
    (
      320.0,
      2.0,
      {
        MealSlot.breakfast: '1 1/2 Handvoll Spinat',
        MealSlot.lunch: '200 g Spinat\n1 Handvoll Spinat',
      },
    ),
  ]) {
    testWidgets('Detailzeile bei ${width.toInt()} px und ${scale}x Text', (
      tester,
    ) async {
      await withClock(Clock.fixed(_today), () async {
        await _week(tester, tuesday, size: Size(width, 900), textScale: scale);
        final row = find.ancestor(
          of: find.text('Spinat'),
          matching: find.byWidgetPredicate(
            (w) =>
                w.key is ValueKey<String> &&
                (w.key! as ValueKey<String>).value.startsWith('shopping-item-'),
          ),
        );
        await tester.ensureVisible(row);
        await tester.pumpAndSettle();
        _expectWordBreaks(tester, row, 'detail at $width × $scale');
        expect(tester.takeException(), isNull);
      });
    });
  }
}
