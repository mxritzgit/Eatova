import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/recipe_import_result.dart';
import 'package:eatova/src/screens/recipes/recipe_import_sheet.dart';
import 'package:eatova/src/screens/recipes/recipes_screen.dart';
import 'package:eatova/src/services/recipe_import_service.dart';
import 'package:eatova/src/services/recipe_save_result.dart';
import 'package:eatova/src/services/sync_error_messages.dart';

import 'support/harness.dart';

const _source = 'https://www.tiktok.com/@cook/video/123';
const _bowl = RecipeImportCandidate(
  id: 'bowl',
  title: 'Chicken bowl',
  ingredients: '100 g rice\n200 g chicken',
  preparation: 'Cook rice. Fry chicken. Serve together.',
  portion: '1 bowl',
);
const _vegan = RecipeImportCandidate(
  id: 'vegan',
  title: 'Tofu bowl',
  variantLabel: 'Vegan',
  ingredients: '100 g rice\n200 g tofu',
  preparation: 'Cook rice. Fry tofu. Serve together.',
  portion: '1 bowl',
);
const _pasta = RecipeImportCandidate(
  id: 'pasta',
  title: 'Tomato pasta',
  ingredients: '100 g pasta\n100 g tomatoes',
  preparation: 'Boil pasta. Cook sauce. Combine.',
);
const _ready = RecipeImportResult(
  status: RecipeImportStatus.ready,
  candidates: [_bowl],
  sourceUrl: _source,
);
const _multiple = RecipeImportResult(
  status: RecipeImportStatus.ready,
  candidates: [_bowl, _vegan, _pasta],
  sourceUrl: _source,
);

class _Service implements RecipeImportService {
  _Service(this.respond);
  final Future<RecipeImportResult> Function(String) respond;
  final List<String> inputs = [];
  final List<String> locales = [];

  @override
  Future<RecipeImportResult> extract(String text, {required String locale}) {
    inputs.add(text);
    locales.add(locale);
    return respond(text);
  }
}

Future<void> _open(
  WidgetTester tester, {
  required RecipeImportService service,
  required Future<SyncDelivery> Function(FitnessRecipe) save,
  String initialText = _source,
  bool Function()? sessionIsCurrent,
  bool Function(String)? isSaved,
  Locale locale = const Locale('en'),
  Brightness brightness = Brightness.dark,
  double textScale = 1,
  Size size = const Size(390, 844),
  bool settle = true,
}) async {
  await pumpLocalized(
    tester,
    Builder(
      builder: (context) => TextButton(
        onPressed: () => showRecipeImportSheet(
          context: context,
          service: service,
          onSave: save,
          initialText: initialText,
          sessionIsCurrent: sessionIsCurrent ?? () => true,
          isSaved: isSaved,
        ),
        child: const Text('Open import'),
      ),
    ),
    surfaceSize: size,
    locale: locale,
    brightness: brightness,
    textScale: textScale,
  );
  await tester.tap(find.text('Open import'));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }
}

Future<void> _tap(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey(key));
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _enter(WidgetTester tester, String key, String text) async {
  final finder = find.byKey(ValueKey(key));
  await tester.ensureVisible(finder);
  await tester.enterText(finder, text);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('preview and saved edit retain each known macro independently', (
    tester,
  ) async {
    const partial = RecipeImportCandidate(
      id: 'partial',
      title: 'Hot Pockets',
      ingredients: '500 g quark',
      preparation: 'Mix and bake.',
      caloriesKcal: 358,
      proteinG: 32,
      fatG: 0,
    );
    final saved = <FitnessRecipe>[];
    await _open(
      tester,
      service: _Service(
        (_) async => const RecipeImportResult(
          status: RecipeImportStatus.ready,
          candidates: [partial],
        ),
      ),
      save: (recipe) async {
        saved.add(recipe);
        return SyncDelivery.delivered;
      },
    );
    expect(find.text('358'), findsOneWidget);
    expect(find.text('32 g'), findsOneWidget);
    expect(find.text('0 g'), findsOneWidget);
    expect(find.text('—'), findsOneWidget);
    await _tap(tester, 'recipe-import-save');
    expect(saved.single.displayNutrition.proteinG, 32);
    expect(saved.single.canLogServings(1), isFalse);
    await pumpLocalized(
      tester,
      RecipeDetailScreen(
        recipe: saved.single,
        onAddMeal: (_, __) {},
        onEdit: (recipe) async {
          saved.add(recipe);
          return RecipeSaveResult.detached(recipe, SyncDelivery.delivered);
        },
      ),
      locale: const Locale('en'),
      surfaceSize: const Size(390, 844),
    );
    await _tap(tester, 'recipe-detail-edit');
    expect(
      tester
          .widget<TextField>(
            find.byKey(const ValueKey('recipe-create-protein')),
          )
          .controller!
          .text,
      '32',
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('recipe-create-carbs')))
          .controller!
          .text,
      isEmpty,
    );
    await _enter(tester, 'recipe-create-name', 'Saved pocket');
    await _tap(tester, 'recipe-create-save');
    expect(saved.last.displayNutrition.proteinG, 32);
    expect(saved.last.displayNutrition.carbsG, isNull);
  });

  testWidgets(
    'unstated nutrition basis requires deliberate confirmation before diary use',
    (tester) async {
      const unknownBasis = RecipeImportCandidate(
        id: 'basis',
        title: 'Bowl',
        ingredients: '250 g quark',
        preparation: '',
        caloriesKcal: 350,
        proteinG: 30,
        carbsG: 40,
        fatG: 10,
        nutritionBasisUnclear: true,
      );
      final saved = <FitnessRecipe>[];
      final recipe = unknownBasis.toRecipe(
        slug: 'basis',
        sourceLabel: 'Source',
      );
      await pumpLocalized(
        tester,
        RecipeDetailScreen(
          recipe: recipe,
          onAddMeal: (_, __) {},
          onEdit: (updated) async {
            saved.add(updated);
            return RecipeSaveResult.detached(updated, SyncDelivery.delivered);
          },
        ),
        locale: const Locale('en'),
        surfaceSize: const Size(390, 844),
      );
      expect(recipe.canLogServings(1), isFalse);
      await _tap(tester, 'recipe-detail-edit');
      await _tap(tester, 'recipe-edit-confirm-nutrition-basis');
      await _tap(tester, 'recipe-create-save');
      expect(saved.single.hasUnclearNutritionBasis, isFalse);
      expect(saved.single.canLogServings(1), isTrue);
      expect(saved.single.displayNutrition.proteinG, 30);
    },
  );

  testWidgets(
    'multiple recipes can be confirmed individually without another extraction',
    (tester) async {
      final saved = <FitnessRecipe>[];
      final service = _Service((_) async => _multiple);
      await _open(
        tester,
        service: service,
        save: (recipe) async {
          saved.add(recipe);
          return SyncDelivery.delivered;
        },
      );
      await _tap(tester, 'recipe-import-candidate-vegan');
      await _tap(tester, 'recipe-import-save');
      expect(saved.map((recipe) => recipe.title), ['Tofu bowl']);
      expect(find.byKey(const ValueKey('recipe-import-sheet')), findsOneWidget);
      final added = tester.widget<ListTile>(
        find.byKey(const ValueKey('recipe-import-candidate-vegan')),
      );
      expect(added.enabled, isFalse);
      expect(added.onTap, isNull);
      await _tap(tester, 'recipe-import-candidate-pasta');
      final scroll = tester.widget<SingleChildScrollView>(
        find.byKey(const ValueKey('recipe-import-sheet')),
      );
      expect(scroll.controller!.offset, 0);
      expect(saved, hasLength(1));
      await _tap(tester, 'recipe-import-save');
      expect(saved.map((recipe) => recipe.title), [
        'Tofu bowl',
        'Tomato pasta',
      ]);
      expect(
        tester
            .widget<ListTile>(
              find.byKey(const ValueKey('recipe-import-candidate-bowl')),
            )
            .enabled,
        isTrue,
      );
      expect(service.inputs, [_source]);
      await _tap(tester, 'recipe-import-done');
      expect(saved, hasLength(2));
      expect(find.byKey(const ValueKey('recipe-import-sheet')), findsNothing);
    },
  );

  testWidgets('single recipe is only persisted on explicit confirmation', (
    tester,
  ) async {
    final saved = <FitnessRecipe>[];
    final service = _Service((_) async => _ready);
    await _open(
      tester,
      service: service,
      save: (recipe) async {
        saved.add(recipe);
        return SyncDelivery.delivered;
      },
    );
    expect(saved, isEmpty);
    expect(find.text('Chicken bowl'), findsOneWidget);
    expect(service.locales, ['en']);
    await _tap(tester, 'recipe-import-save');
    expect(saved, hasLength(1));
    expect(saved.single.title, 'Chicken bowl');
    expect(saved.single.description, contains(_source));
    expect(saved.single.hasPendingNutrition, isTrue);
    expect(saved.single.canLogServings(1), isFalse);
    expect(find.byKey(const ValueKey('recipe-import-sheet')), findsNothing);
  });

  testWidgets(
    'three recipes and vegan alternative require an explicit choice',
    (tester) async {
      final saved = <FitnessRecipe>[];
      await _open(
        tester,
        service: _Service((_) async => _multiple),
        save: (recipe) async {
          saved.add(recipe);
          return SyncDelivery.delivered;
        },
      );
      expect(find.byKey(const ValueKey('recipe-import-save')), findsNothing);
      expect(
        find.byKey(const ValueKey('recipe-import-candidate-bowl')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('recipe-import-candidate-vegan')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('recipe-import-candidate-pasta')),
        findsOneWidget,
      );
      expect(saved, isEmpty);
      await _tap(tester, 'recipe-import-candidate-vegan');
      expect(find.text('Tofu bowl'), findsOneWidget);
      expect(saved, isEmpty);
      await _tap(tester, 'recipe-import-save');
      expect(saved.single.title, 'Tofu bowl');
      expect(saved.single.ingredients, contains('tofu'));
      expect(saved.single.ingredients, isNot(contains('chicken')));
    },
  );

  testWidgets('closing preview does not save a recipe', (tester) async {
    var saves = 0;
    await _open(
      tester,
      service: _Service((_) async => _ready),
      save: (_) async {
        saves++;
        return SyncDelivery.delivered;
      },
    );
    await _tap(tester, 'recipe-import-close');
    expect(saves, 0);
    expect(find.byKey(const ValueKey('recipe-import-sheet')), findsNothing);
  });

  testWidgets(
    'missing caption preserves link and accepts pasted fallback text',
    (tester) async {
      final service = _Service(
        (text) async => text == _source
            ? const RecipeImportResult(
                status: RecipeImportStatus.needsText,
                sourceUrl: _source,
              )
            : _ready,
      );
      await _open(
        tester,
        service: service,
        save: (_) async => SyncDelivery.delivered,
      );
      expect(find.textContaining('usable ingredient list'), findsOneWidget);
      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('recipe-import-input')),
      );
      expect(field.controller!.text, _source);
      await _enter(
        tester,
        'recipe-import-input',
        '$_source\n100 g rice. Cook and serve.',
      );
      await _tap(tester, 'recipe-import-analyze');
      expect(service.inputs, [
        _source,
        '$_source\n100 g rice. Cook and serve.',
      ]);
      expect(find.text('Chicken bowl'), findsOneWidget);
    },
  );

  testWidgets(
    'unavailable import can retry without exposing exception details',
    (tester) async {
      var attempts = 0;
      final service = _Service((_) async {
        if (attempts++ == 0) {
          throw const RecipeImportException(RecipeImportFailure.unavailable);
        }
        return _ready;
      });
      await _open(
        tester,
        service: service,
        save: (_) async => SyncDelivery.delivered,
      );
      expect(find.textContaining('currently unavailable'), findsOneWidget);
      expect(find.textContaining('RecipeImportException'), findsNothing);
      await _tap(tester, 'recipe-import-analyze');
      expect(service.inputs, [_source, _source]);
      expect(find.text('Chicken bowl'), findsOneWidget);
    },
  );

  testWidgets(
    'session change during extraction cannot expose or save its result',
    (tester) async {
      final completion = Completer<RecipeImportResult>();
      var current = true;
      var saves = 0;
      await _open(
        tester,
        service: _Service((_) => completion.future),
        sessionIsCurrent: () => current,
        settle: false,
        save: (_) async {
          saves++;
          return SyncDelivery.delivered;
        },
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      current = false;
      completion.complete(_ready);
      await tester.pumpAndSettle();
      expect(find.textContaining('sign-in changed'), findsOneWidget);
      expect(find.text('Chicken bowl'), findsNothing);
      expect(find.byKey(const ValueKey('recipe-import-save')), findsNothing);
      expect(saves, 0);
    },
  );

  testWidgets('session change before confirmation blocks the save callback', (
    tester,
  ) async {
    var current = true;
    var saves = 0;
    await _open(
      tester,
      service: _Service((_) async => _ready),
      sessionIsCurrent: () => current,
      save: (_) async {
        saves++;
        return SyncDelivery.delivered;
      },
    );
    current = false;
    await _tap(tester, 'recipe-import-save');
    expect(saves, 0);
    expect(find.textContaining('sign-in changed'), findsOneWidget);
  });

  testWidgets('save failure keeps draft and retries with the same identity', (
    tester,
  ) async {
    final attempts = <FitnessRecipe>[];
    await _open(
      tester,
      service: _Service((_) async => _ready),
      save: (recipe) async {
        attempts.add(recipe);
        if (attempts.length == 1) throw StateError('private backend details');
        return SyncDelivery.queuedOffline;
      },
    );
    await _tap(tester, 'recipe-import-save');
    expect(find.byKey(const ValueKey('recipe-import-sheet')), findsOneWidget);
    expect(find.textContaining('private backend details'), findsNothing);
    await _tap(tester, 'recipe-import-save');
    expect(attempts, hasLength(2));
    expect(attempts[0].slug, attempts[1].slug);
  });

  testWidgets('editing ingredients clears now stale nutrition before saving', (
    tester,
  ) async {
    const known = RecipeImportCandidate(
      id: 'bowl',
      title: 'Chicken bowl',
      ingredients: '200 g chicken',
      preparation: 'Fry chicken.',
      portion: '1 plate',
      caloriesKcal: 330,
      proteinG: 50,
      carbsG: 0,
      fatG: 10,
      estimatedGrams: 200,
    );
    final saved = <FitnessRecipe>[];
    await _open(
      tester,
      service: _Service(
        (_) async => const RecipeImportResult(
          status: RecipeImportStatus.ready,
          candidates: [known],
          sourceUrl: _source,
        ),
      ),
      save: (recipe) async {
        saved.add(recipe);
        return SyncDelivery.delivered;
      },
    );
    await _tap(tester, 'recipe-import-edit');
    await _enter(tester, 'recipe-import-edit-ingredients', '200 g tofu');
    expect(saved, isEmpty);
    await _tap(tester, 'recipe-import-save');
    expect(saved.single.ingredients, '200 g tofu');
    expect(saved.single.hasPendingNutrition, isTrue);
    expect(saved.single.canLogServings(1), isFalse);
    expect(saved.single.description, contains(_source));
  });

  testWidgets('duplicate shared recipe cannot overwrite an existing recipe', (
    tester,
  ) async {
    var saves = 0;
    await _open(
      tester,
      service: _Service((_) async => _ready),
      isSaved: (slug) => slug == _bowl.stableSlug(_source),
      save: (_) async {
        saves++;
        return SyncDelivery.delivered;
      },
    );
    await _tap(tester, 'recipe-import-save');
    expect(
      find.text('This recipe is already saved in your recipes.'),
      findsOneWidget,
    );
    expect(saves, 0);
  });

  testWidgets('save remains single flight and cannot dismiss while writing', (
    tester,
  ) async {
    final completion = Completer<SyncDelivery>();
    var saves = 0;
    await _open(
      tester,
      service: _Service((_) async => _ready),
      save: (_) {
        saves++;
        return completion.future;
      },
    );
    final button = find.byKey(const ValueKey('recipe-import-save'));
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pump();
    await tester.tap(button);
    await tester.pump();
    expect(saves, 1);
    final close = tester.widget<IconButton>(
      find.byKey(const ValueKey('recipe-import-close')),
    );
    expect(close.onPressed, isNull);
    await tester.binding.handlePopRoute();
    expect(find.byKey(const ValueKey('recipe-import-sheet')), findsOneWidget);
    completion.complete(SyncDelivery.delivered);
    await tester.pumpAndSettle();
  });

  testWidgets('manual pasted draft asks before discarding', (tester) async {
    await _open(
      tester,
      service: _Service((_) async => _ready),
      initialText: '',
      save: (_) async => SyncDelivery.delivered,
    );
    await _enter(tester, 'recipe-import-input', 'A recipe draft');
    await _tap(tester, 'recipe-import-close');
    expect(find.byKey(const ValueKey('recipe-import-discard')), findsOneWidget);
    await _tap(tester, 'recipe-import-discard');
    expect(find.byKey(const ValueKey('recipe-import-sheet')), findsNothing);
  });

  for (final brightness in Brightness.values) {
    testWidgets('selection and preview fit large text in ${brightness.name}', (
      tester,
    ) async {
      await _open(
        tester,
        service: _Service((_) async => _multiple),
        save: (_) async => SyncDelivery.delivered,
        brightness: brightness,
        textScale: 2,
        size: const Size(320, 720),
      );
      expect(tester.takeException(), isNull);
      await _tap(tester, 'recipe-import-candidate-vegan');
      await tester.ensureVisible(
        find.byKey(const ValueKey('recipe-import-save')),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'imported unknown nutrition stays blank and blocks partial correction',
    (tester) async {
      final longSource = '$_source?ref=${'a' * 1100}';
      final recipe = _bowl
          .copyWith(description: 'd' * 1200)
          .toRecipe(
            slug: _bowl.stableSlug(_source),
            sourceUrl: longSource,
            sourceLabel: 'Source',
          );
      final saved = <FitnessRecipe>[];
      await pumpLocalized(
        tester,
        RecipeDetailScreen(
          recipe: recipe,
          onAddMeal: (_, __) {},
          onEdit: (updated) async {
            saved.add(updated);
            return RecipeSaveResult.detached(updated, SyncDelivery.delivered);
          },
        ),
        locale: const Locale('en'),
        surfaceSize: const Size(390, 844),
      );
      await _tap(tester, 'recipe-detail-edit');
      for (final field in ['kcal', 'grams', 'protein', 'carbs', 'fat']) {
        expect(
          tester
              .widget<TextField>(find.byKey(ValueKey('recipe-create-$field')))
              .controller!
              .text,
          isEmpty,
        );
      }
      await _enter(tester, 'recipe-create-name', 'My imported bowl');
      await _tap(tester, 'recipe-create-save');
      expect(saved.single.hasPendingNutrition, isTrue);
      expect(saved.single.description.length, greaterThan(2000));
      expect(saved.single.description, contains(longSource));
      await _tap(tester, 'recipe-detail-edit');
      await _enter(tester, 'recipe-create-kcal', '450');
      await _enter(tester, 'recipe-create-grams', '300');
      final save = tester.widget<FilledButton>(
        find.byKey(const ValueKey('recipe-create-save')),
      );
      expect(save.onPressed, isNull);
      await _enter(tester, 'recipe-create-protein', '30');
      await _enter(tester, 'recipe-create-carbs', '45');
      await _enter(tester, 'recipe-create-fat', '12');
      await _tap(tester, 'recipe-create-save');
      expect(saved.last.hasPendingNutrition, isFalse);
      expect(saved.last.canLogServings(1), isTrue);
      expect(saved.last.caloriesKcal, 450);
    },
  );
}
