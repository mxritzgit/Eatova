import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/recipe_catalog_de.dart';
import 'package:eatova/src/models/recipe_catalog_en.dart';
import 'package:eatova/src/screens/recipes/meal_plan_screen.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/widgets/design/design.dart';

import '../outbox/outbox_test_helpers.dart' as h;
import '../support/harness.dart';
import 'number_input_cases.dart';

// Planned servings are decimals. `parseRecipeServings` swapped ',' for '.', so
// "1.000" servings were planned as one serving.

final _heute = DateTime(2026, 9, 10, 12);

void main() {
  for (final locale in eingabeSprachen) {
    final l10n = l10nFuer(locale);
    final code = locale.languageCode;

    testWidgets('Essensplan [$code]: Portionen mit Komma, Punkt, ohne Raten',
        (tester) async {
      final store = HomeStore(
        sync: null,
        health: const NoopHealthService(),
        notificationService: const NoopNotificationService(),
        initialUserName: 'Fixture',
        emitSnack: h.SnackCapture().call,
      );
      addTearDown(store.dispose);
      await withClock(Clock.fixed(_heute), () async {
        await pumpLocalized(
          tester,
          MealPlanScreen(store: store),
          locale: locale,
          surfaceSize: const Size(390, 850),
        );
        await tester.tap(find.text(l10n.mealPlanAdd).first);
        await tester.pumpAndSettle();
        final rezept = code == 'de'
            ? recipeCatalogDe.first.title
            : recipeCatalogEn.first.title;
        await tester.tap(find.text(rezept));
        await tester.pumpAndSettle();

        final feld = find.byKey(const ValueKey('meal-plan-servings'));
        final speichern = find.byKey(const ValueKey('meal-plan-save'));
        await tester.ensureVisible(feld);
        expect(
          tester.widget<TextField>(feld).controller!.text,
          '1',
          reason: 'Vorbelegung',
        );
        bool aktiv() =>
            tester.widget<PrimaryActionButton>(speichern).onTap != null;

        for (final eingabe in const <String>['3,5', '3.5']) {
          await tester.enterText(feld, eingabe);
          await tester.pumpAndSettle();
          expect(aktiv(), isTrue, reason: eingabe);
          expect(find.text(l10n.mealPlanServingsError), findsNothing);
        }

        await tester.enterText(feld, '1.000');
        await tester.pumpAndSettle();
        expect(aktiv(), isFalse, reason: 'frueher still 1 Portion');
        expect(find.text(mehrdeutigHinweis(l10n)), findsOneWidget);

        await tester.enterText(feld, '1.000,5');
        await tester.pumpAndSettle();
        expect(aktiv(), isFalse);
        expect(find.text(l10n.mealPlanServingsError), findsOneWidget);

        await tester.enterText(feld, '2,5');
        await tester.pumpAndSettle();
        await tester.ensureVisible(speichern);
        await tester.tap(speichern);
        await tester.pumpAndSettle();
        expect(store.plannedMeals.single.servings, 2.5);
      });
    });
  }
}
