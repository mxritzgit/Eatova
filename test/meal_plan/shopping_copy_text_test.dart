// Review 2026-10-19, "Teilen und Support": the weekly receipt goes out as
// clean plain text, through the share sheet since 2026-10-22; where that
// cannot open, onto the clipboard with a confirmation toast.

import 'package:clock/clock.dart';
import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/planned_meal.dart';
import 'package:eatova/src/screens/recipes/meal_plan_screen.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/services/text_share.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_plus/share_plus.dart';

import '../outbox/outbox_test_helpers.dart' as h;
import '../support/harness.dart';

/// A Monday, so the shown week is Sep 7 to Sep 13 (ISO week 37).
final _today = DateTime(2026, 9, 7, 12);

HomeStore _store() {
  final store = HomeStore(
    sync: null,
    health: const NoopHealthService(),
    notificationService: const NoopNotificationService(),
    initialUserName: 'Fixture',
    emitSnack: h.SnackCapture().call,
  );
  addTearDown(store.dispose);
  return store;
}

/// Captures what the app writes to the clipboard.
List<String> _clipboard(WidgetTester tester) {
  final copied = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add((call.arguments as Map)['text'] as String);
      }
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
  return copied;
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('die Einkaufsliste geht als sauberer Text ins Teilen-Menü, '
      'sonst in die Zwischenablage', (tester) async {
    await withClock(Clock.fixed(_today), () async {
      final copied = _clipboard(tester);
      final shared = <ShareParams>[];
      final platformSheet = shareSheet;
      addTearDown(() => shareSheet = platformSheet);
      shareSheet = (params) async {
        shared.add(params);
        return const ShareResult('', ShareResultStatus.success);
      };
      final store = _store();
      await store.savePlannedMeal(
        PlannedMeal.create(
          recipe: recipeCatalogDe.firstWhere(
            (r) => r.slug == 'lachs_mit_sukartoffel_and_spargel',
          ),
          day: DateTime(2026, 9, 8),
          slot: MealSlot.dinner,
        ),
      );
      await pumpLocalized(
        tester,
        MealPlanScreen(store: store),
        surfaceSize: const Size(393, 852),
      );
      await _tap(tester, find.byKey(const ValueKey('meal-plan-tab-shopping')));
      // One row bought: it keeps its line, marked.
      await _tap(tester, find.textContaining('Lachsfilet').first);
      await _tap(tester, find.byKey(const ValueKey('shopping-share')));

      // The receipt's order and amounts, one line each, no layout spaces.
      const text =
          'Einkaufsliste · KW 37 · 1 Gericht\n'
          '\n'
          '- Dill oder Petersilie\n'
          '- 200 g Grüner Spargel\n'
          '✓ 180 g Lachsfilet\n'
          '- 300 g Süßkartoffel, in Spalten\n'
          '\n'
          'Gewürze & Vorrat\n'
          '- 1/2 TL Knoblauchpulver\n'
          '- 1 TL Körniger Senf optional\n'
          '- 10 g Olivenöl\n'
          '- Pfeffer\n'
          '- Salz\n'
          '- 1 TL Zitronensaft';
      expect(shared.single.text, text);
      expect(shared.single.subject, 'Einkaufsliste');
      expect(copied, isEmpty);
      expect(find.text('Einkaufsliste kopiert.'), findsNothing);

      // No share sheet on this device: the clipboard, with a toast.
      shareSheet = (params) async => throw MissingPluginException();
      await _tap(tester, find.byKey(const ValueKey('shopping-share')));
      expect(copied, [text]);
      expect(find.text('Einkaufsliste kopiert.'), findsOneWidget);
    });
  });
}
