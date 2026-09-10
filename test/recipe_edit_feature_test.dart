import 'dart:async';

import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/screens/recipes/recipes_screen.dart';
import 'package:eatova/src/services/sync_error_messages.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

const original = FitnessRecipe(
  slug: 'user_coach_saved-message',
  title: 'Saved bowl',
  description: 'A warm bowl',
  portion: 'One plate',
  ingredients: 'Rice\nBeans',
  preparation: 'Boil rice.\nAdd beans.',
  professionalHint: 'Keep the lid on.',
  imageAsset: 'local:preserved.jpg',
  caloriesKcal: 480,
  proteinG: 21,
  carbsG: 60,
  fatG: 12,
  estimatedGrams: 340,
  categories: ['Eigene', 'Vegan'],
  userCreated: true,
);

Finder field(String name) => find.byKey(ValueKey('recipe-create-$name'));

Future<void> openEditor(
  WidgetTester tester, {
  Future<SyncDelivery> Function(FitnessRecipe)? save,
  bool Function()? session,
  double textScale = 1,
  Brightness brightness = Brightness.dark,
}) async {
  await pumpLocalized(
    tester,
    RecipeDetailScreen(
      recipe: original,
      onAddMeal: (_, _) {},
      onEdit: save ?? (_) async => SyncDelivery.delivered,
      isSessionCurrent: session,
    ),
    locale: const Locale('en'),
    textScale: textScale,
    brightness: brightness,
    safeArea: false,
  );
  await tester.ensureVisible(find.byKey(const ValueKey('recipe-detail-edit')));
  await tester.tap(find.byKey(const ValueKey('recipe-detail-edit')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'editing Coach recipe prefills values and preserves identity and history',
    (tester) async {
      pinPhoneViewport(tester);
      final previousDiarySnapshot = original.toMealResult();
      final saved = <FitnessRecipe>[];
      await openEditor(
        tester,
        save: (recipe) async {
          saved.add(recipe);
          return SyncDelivery.queuedOffline;
        },
      );
      for (final pair in {
        'name': original.title,
        'description': original.description,
        'portion': original.portion,
        'grams': '340',
        'kcal': '480',
        'protein': '21',
        'carbs': '60',
        'fat': '12',
        'ingredients': original.ingredients,
        'preparation': original.preparation,
      }.entries) {
        expect(
          tester.widget<TextField>(field(pair.key)).controller!.text,
          pair.value,
        );
      }
      await tester.enterText(field('name'), 'Changed bowl');
      await tester.enterText(field('kcal'), '520');
      await tester.enterText(
        field('preparation'),
        'Steam rice.\nStir in beans.',
      );
      await tester.tap(field('save'));
      await tester.pumpAndSettle();
      expect(saved, hasLength(1));
      expect(saved.single.slug, original.slug);
      expect(saved.single.imageAsset, original.imageAsset);
      expect(saved.single.categories, original.categories);
      expect(saved.single.description, original.description);
      expect(saved.single.professionalHint, original.professionalHint);
      expect(saved.single.preparation, 'Steam rice.\nStir in beans.');
      expect(saved.single.caloriesKcal, 520);
      expect(previousDiarySnapshot.caloriesKcal, 480);
      expect(previousDiarySnapshot.mealName, 'Saved bowl');
      expect(find.text('Changed bowl'), findsOneWidget);
      expect(field('save'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'nondurable save retains draft and retries without reporting success',
    (tester) async {
      pinPhoneViewport(tester);
      var attempts = 0;
      await openEditor(
        tester,
        save: (_) async {
          if (++attempts == 1) throw StateError('private backend detail');
          return SyncDelivery.delivered;
        },
      );
      await tester.enterText(field('name'), 'Retry bowl');
      await tester.tap(field('save'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('recipe-edit-save-error')),
        findsOneWidget,
      );
      expect(find.textContaining('private backend detail'), findsNothing);
      expect(
        tester.widget<TextField>(field('name')).controller!.text,
        'Retry bowl',
      );
      await tester.tap(field('save'));
      await tester.pumpAndSettle();
      expect(attempts, 2);
      expect(field('save'), findsNothing);
      expect(find.text('Retry bowl'), findsOneWidget);
    },
  );

  testWidgets('save waits for acknowledgement and back cannot dismiss draft', (
    tester,
  ) async {
    pinPhoneViewport(tester);
    final completion = Completer<SyncDelivery>();
    await openEditor(tester, save: (_) => completion.future);
    await tester.enterText(field('name'), 'Pending bowl');
    await tester.tap(field('save'));
    await tester.pump();
    await tester.binding.handlePopRoute();
    await tester.pump(const Duration(milliseconds: 100));
    expect(field('save'), findsOneWidget);
    expect(tester.widget<FilledButton>(field('save')).onPressed, isNull);
    expect(find.byKey(const ValueKey('discard-changes-dialog')), findsNothing);
    completion.complete(SyncDelivery.queuedRetry);
    await tester.pumpAndSettle();
    expect(field('save'), findsNothing);
  });

  testWidgets('account switch blocks save before persistence callback', (
    tester,
  ) async {
    pinPhoneViewport(tester);
    var current = true;
    var writes = 0;
    await openEditor(
      tester,
      session: () => current,
      save: (_) async {
        writes++;
        return SyncDelivery.delivered;
      },
    );
    await tester.enterText(field('name'), 'Private draft');
    current = false;
    await tester.tap(field('save'));
    await tester.pumpAndSettle();
    expect(writes, 0);
    expect(
      find.byKey(const ValueKey('recipe-edit-save-error')),
      findsOneWidget,
    );
    expect(field('save'), findsOneWidget);
  });

  testWidgets('preparation participates in discard guard', (tester) async {
    pinPhoneViewport(tester);
    await openEditor(tester);
    await tester.enterText(field('preparation'), 'Unsaved preparation');
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('discard-changes-dialog')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('discard-changes-cancel')));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(field('preparation')).controller!.text,
      'Unsaved preparation',
    );
  });

  for (final brightness in Brightness.values) {
    testWidgets('editor reflows at 320px with doubled text $brightness', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await openEditor(tester, textScale: 2, brightness: brightness);
      await tester.ensureVisible(field('preparation'));
      await tester.enterText(field('preparation'), 'Readable preparation');
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      expect(field('save'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
