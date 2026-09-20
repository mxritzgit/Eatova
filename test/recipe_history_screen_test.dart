import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/screens/recipes/recipe_history_screen.dart';
import 'package:eatova/src/screens/recipes/recipes_screen.dart';
import 'package:eatova/src/services/sync_error_messages.dart';
import 'package:eatova/src/services/user_recipe_reads.dart';

import 'support/harness.dart';

final _old = FitnessRecipe.fromRow({
  'slug': 'user_recipe',
  'title': 'Earlier bowl',
  'ingredients': 'Rice',
  'preparation': 'Cook carefully',
  'estimated_g': 300,
  'calories_kcal': 500,
});
RecipeVersion _version(int revision, {bool deleted = false}) => RecipeVersion(
  recipe: _old,
  revision: revision,
  deleted: deleted,
  recordedAt: DateTime.utc(2026, 9, 20, 12),
);
RecipeHistoryPage _page({int revision = 3, int? next, int? head}) =>
    RecipeHistoryPage(
      versions: [_version(revision, deleted: true)],
      currentRevision: head,
      currentDeleted: head == null ? null : true,
      nextBefore: next,
    );

Future<void> _openVersion(WidgetTester tester, int revision) async {
  await tester.tap(find.byKey(ValueKey('recipe-history-version-$revision')));
  await tester.pumpAndSettle();
  await tester.ensureVisible(
    find.byKey(ValueKey('recipe-history-restore-$revision')),
  );
  await tester.tap(find.byKey(ValueKey('recipe-history-restore-$revision')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets('restore needs confirmation and uses the freshly observed head', (
    tester,
  ) async {
    pinPhoneViewport(tester);
    final restored = <int>[];
    await tester.pumpWidget(
      localizedApp(
        RecipeHistoryScreen(
          loadHistory: ({slug, beforeRevision}) async =>
              _page(head: slug == null ? null : 19),
          restoreVersion: (recipe, {required expectedRevision}) async {
            expect(recipe.title, 'Earlier bowl');
            restored.add(expectedRevision);
            return SyncDelivery.delivered;
          },
          isSessionCurrent: () => true,
        ),
        locale: const Locale('en'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Deleted'), findsOneWidget);
    await _openVersion(tester, 3);
    expect(restored, isEmpty);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(restored, isEmpty);
    await tester.tap(find.byKey(const ValueKey('recipe-history-restore-3')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(const ValueKey('recipe-history-confirm')));
    await tester.pumpAndSettle();
    expect(restored, [
      19,
    ], reason: 'The historical revision 3 must not be the CAS base');
  });

  testWidgets('failed restore stays visible and shows no success', (
    tester,
  ) async {
    pinPhoneViewport(tester);
    await tester.pumpWidget(
      localizedApp(
        RecipeHistoryScreen(
          loadHistory: ({slug, beforeRevision}) async =>
              _page(head: slug == null ? null : 19),
          restoreVersion: (recipe, {required expectedRevision}) async =>
              throw StateError('private fixture'),
          isSessionCurrent: () => true,
        ),
        locale: const Locale('en'),
      ),
    );
    await tester.pumpAndSettle();
    await _openVersion(tester, 3);
    await tester.tap(find.byKey(const ValueKey('recipe-history-confirm')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('recipe-history-list')), findsOneWidget);
    expect(find.textContaining('private fixture'), findsNothing);
    expect(find.textContaining('Please try again'), findsOneWidget);
    expect(find.text('Recipe version saved.'), findsNothing);
  });

  testWidgets(
    'history page failure retries the same cursor and retains earlier events',
    (tester) async {
      pinPhoneViewport(tester);
      final cursors = <int?>[];
      await tester.pumpWidget(
        localizedApp(
          RecipeHistoryScreen(
            loadHistory: ({slug, beforeRevision}) async {
              cursors.add(beforeRevision);
              if (cursors.length == 2) throw StateError('fixture');
              return beforeRevision == null
                  ? _page(next: 3)
                  : _page(revision: 2);
            },
            restoreVersion: (recipe, {required expectedRevision}) async =>
                SyncDelivery.delivered,
            isSessionCurrent: () => true,
          ),
          locale: const Locale('en'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Load earlier versions'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('recipe-history-version-3')),
        findsOneWidget,
      );
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(cursors, [null, 3, 3]);
      expect(
        find.byKey(const ValueKey('recipe-history-version-2')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('recipe-history-version-3')),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'account switch during head read cannot open confirmation or restore',
    (tester) async {
      pinPhoneViewport(tester);
      var current = true;
      var saves = 0;
      final head = Completer<RecipeHistoryPage>();
      await tester.pumpWidget(
        localizedApp(
          RecipeHistoryScreen(
            loadHistory: ({slug, beforeRevision}) =>
                slug == null ? Future.value(_page()) : head.future,
            restoreVersion: (recipe, {required expectedRevision}) async {
              saves++;
              return SyncDelivery.delivered;
            },
            isSessionCurrent: () => current,
          ),
          locale: const Locale('en'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('recipe-history-version-3')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('recipe-history-restore-3')),
      );
      await tester.tap(find.byKey(const ValueKey('recipe-history-restore-3')));
      await tester.pump();
      current = false;
      head.complete(_page(head: 19));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('recipe-history-confirm')),
        findsNothing,
      );
      expect(saves, 0);
    },
  );

  testWidgets('large text layout is usable in both languages', (tester) async {
    pinPhoneViewport(tester);
    for (final locale in ['de', 'en']) {
      await tester.pumpWidget(
        localizedApp(
          RecipeHistoryScreen(
            key: ValueKey(locale),
            loadHistory: ({slug, beforeRevision}) async => _page(),
            restoreVersion: (recipe, {required expectedRevision}) async =>
                SyncDelivery.delivered,
            isSessionCurrent: () => true,
          ),
          locale: Locale(locale),
          textScale: 2,
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
  });
  testWidgets(
    'logging awaits commit, blocks duplicate taps, and retains portions on failure',
    (tester) async {
      pinPhoneViewport(tester);
      final pending = Completer<void>();
      final calories = <int>[];
      await tester.pumpWidget(
        localizedApp(
          RecipeDetailScreen(
            recipe: _old,
            onAddMeal: (result, _) {
              calories.add(result.caloriesKcal);
              return calories.length == 1
                  ? pending.future
                  : Future<void>.value();
            },
          ),
          locale: const Locale('en'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('recipe-add-button')),
      );
      await tester.tap(find.byKey(const ValueKey('recipe-add-button')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('recipe-portion-field')),
        '2',
      );
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      final slot = find.byKey(const ValueKey('recipe-meal-picker-lunch'));
      await tester.ensureVisible(slot);
      await tester.tap(slot);
      await tester.pump();
      await tester.tap(slot);
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(calories, [1000]);
      expect(
        find.byKey(const ValueKey('recipe-meal-picker-sheet')),
        findsOneWidget,
      );
      expect(find.textContaining('Added 1000 kcal'), findsNothing);
      pending.completeError(StateError('private fixture'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('recipe-meal-picker-sheet')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('recipe-portion-field')),
            )
            .controller!
            .text,
        '2',
      );
      expect(find.textContaining('private fixture'), findsNothing);
      await tester.tap(slot);
      await tester.pumpAndSettle();
      expect(calories, [1000, 1000]);
      expect(
        find.byKey(const ValueKey('recipe-meal-picker-sheet')),
        findsNothing,
      );
      expect(find.textContaining('Added 1000 kcal'), findsOneWidget);
    },
  );
}
