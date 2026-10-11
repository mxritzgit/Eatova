// Visual evidence for the feedback-state pass in place (2026-10-11): the
// error notes, busy save buttons and spinners as they sit in their real
// screens, not only in the gallery of feedback_states_capture_test.dart:
//
//   feedback-player-save-failed     the list player after a failed save
//   feedback-player-retrying        ... while its retry runs (pill disabled)
//   feedback-plan-editor-saving     plan editor, save in flight
//   feedback-plan-editor-error      ... after the save failed
//   feedback-log-editor-saving      log editor, save in flight
//   feedback-log-editor-error       ... after the save failed
//   feedback-brief-error            Coach training brief, request refused
//   feedback-history-detail-error   workout detail, delete failed
//   feedback-recipe-create-error    "Your recipe", save failed
//   feedback-recipe-import-error    import edit, required fields missing
//   feedback-nutrition-basis-error  nutrition basis sheet, save failed
//   feedback-ingredient-searching   ingredient search running
//   feedback-ingredient-error       ingredient search failed
//   feedback-meal-plan-editor-error meal plan editor, save failed
//   feedback-export-loading         data export, still loading
//   feedback-recipe-history-restoring  recipe history, restore confirmed
//
// Each at 390 px and at 320 px with 2x text (suffix -320-x2). With
// --dart-define=DARK_REDESIGN_CAPTURE=true the PNGs land in
// build/dark-redesign/ (light: DESIGN_CAPTURE_BRIGHTNESS=light); without it
// the suite still checks that every state renders without an exception or
// overflow.

import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/coach_training_proposal.dart';
import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/planned_meal.dart';
import 'package:eatova/src/models/recipe_import_result.dart';
import 'package:eatova/src/models/training_history.dart';
import 'package:eatova/src/models/training_log.dart';
import 'package:eatova/src/models/training_plan.dart';
import 'package:eatova/src/screens/coach/coach_training_brief.dart';
import 'package:eatova/src/screens/recipes/meal_plan_screen.dart';
import 'package:eatova/src/screens/recipes/recipe_history_screen.dart';
import 'package:eatova/src/screens/recipes/recipe_import_sheet.dart';
import 'package:eatova/src/screens/recipes/recipes_screen.dart';
import 'package:eatova/src/screens/training/training_history_screen.dart';
import 'package:eatova/src/screens/training/training_log_editor.dart';
import 'package:eatova/src/screens/training/training_plan_editor.dart';
import 'package:eatova/src/screens/training/training_player_screen.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/services/open_food_facts_product_service.dart';
import 'package:eatova/src/services/recipe_import_service.dart';
import 'package:eatova/src/services/screen_awake.dart';
import 'package:eatova/src/services/sync_error_messages.dart';
import 'package:eatova/src/services/user_recipe_reads.dart';
import 'package:eatova/src/widgets/shared/data_export_sheet.dart';

import '../outbox/outbox_test_helpers.dart' as h;
import '../support/design_capture.dart';
import '../support/harness.dart';
import '../support/recipe_navigation.dart';

/// Saturday 2026-10-03, 18:30 local.
final _now = DateTime(2026, 10, 3, 18, 30);

/// Monday, so the meal plan's week starts today.
final _monday = DateTime(2026, 9, 28, 18, 30);

const _logId = '3f2b8c1e-4d5a-4b6c-8d7e-9f0a1b2c3d4e';

Finder _key(String key) => find.byKey(ValueKey(key));

/// The reference phone, optionally narrowed to [width].
void _viewport(WidgetTester tester, double width) {
  pinDesignViewport(tester);
  tester.view.physicalSize =
      Size(width, kDesignViewport.height) * kDesignPixelRatio;
}

/// Mounts [child] as the app's page at [width] and [textScale]; a tab body
/// passes [scaffold].
Future<void> _page(
  WidgetTester tester,
  Widget child, {
  required double width,
  required double textScale,
  bool scaffold = false,
}) async {
  _viewport(tester, width);
  await tester.pumpWidget(
    designCaptureBoundary(
      localizedApp(
        child,
        locale: const Locale('en'),
        textScale: textScale,
        safeArea: false,
        scaffold: scaffold,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Pumps a launcher at [width] and opens a sheet or page from it.
Future<void> _launch(
  WidgetTester tester,
  void Function(BuildContext context) open, {
  required double width,
  required double textScale,
  bool settle = true,
}) async {
  _viewport(tester, width);
  await tester.pumpWidget(
    designCaptureBoundary(
      localizedApp(
        Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => open(context),
              child: const Text('open'),
            ),
          ),
        ),
        locale: const Locale('en'),
        textScale: textScale,
        safeArea: false,
      ),
    ),
  );
  await tester.tap(find.text('open'));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await _frames(tester);
  }
}

/// A few frames for states that never settle (a running spinner).
Future<void> _frames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _reveal(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
}

Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  await _reveal(tester, finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _type(WidgetTester tester, String key, String text) async {
  await _reveal(tester, _key(key));
  await tester.enterText(_key(key), text);
  await tester.pumpAndSettle();
}

/// Drops the focus fill so a shot shows the resting fields.
Future<void> _unfocus(WidgetTester tester) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pumpAndSettle();
}

CoachTrainingProposal _proposal() => CoachTrainingProposal(
  title: 'Strength plan',
  description: 'Three sessions a week with dumbbells and a bench.',
  goal: 'Build strength',
  workouts: [
    TrainingWorkout(
      title: 'Upper Body Push',
      exercises: [
        TrainingExercise(
          name: 'Bench press',
          sets: 3,
          reps: 8,
          restSeconds: 120,
        ),
        TrainingExercise(
          name: 'Incline dumbbell press',
          sets: 3,
          reps: 10,
          restSeconds: 90,
        ),
        TrainingExercise(
          name: 'Plank',
          sets: 3,
          durationSeconds: 45,
          restSeconds: 45,
        ),
      ],
    ),
  ],
);

TrainingPlan _plan() => TrainingPlan(id: 'plan-a', proposal: _proposal());

/// Bench press two days ago, as a free log.
TrainingHistoryEntry _benchLog() => buildLoggedWorkout(
  historyId: '0b6f2a9e-1c3d-4e5f-8a7b-6c5d4e3f2a1b',
  draft: LoggedWorkoutDraft(
    title: 'Push',
    performedOn: DateTime(2026, 10, 1),
    durationMinutes: 48,
    exercises: const [
      LoggedExercise(
        name: 'Bench press',
        timed: false,
        sets: [
          LoggedSet(reps: 8, weightKg: 80),
          LoggedSet(reps: 8, weightKg: 80),
          LoggedSet(reps: 6, weightKg: 75),
        ],
      ),
    ],
  ),
  now: _now,
  fallbackTitle: 'Workout',
);

/// A product search the test answers by hand.
class _Products implements ProductLookupService {
  Completer<List<ProductSearchResult>>? pending;

  @override
  Future<List<ProductSearchResult>> searchProducts(String query) =>
      (pending = Completer<List<ProductSearchResult>>()).future;

  @override
  Future<MealAnalysisResult> lookupBarcode(String barcode) =>
      throw UnimplementedError();
}

class _ImportService implements RecipeImportService {
  @override
  Future<RecipeImportResult> extract(
    String text, {
    required String locale,
  }) async => const RecipeImportResult(
    status: RecipeImportStatus.ready,
    candidates: [
      RecipeImportCandidate(
        id: 'bowl',
        title: 'High-protein chicken burrito bowl',
        portion: '1 bowl (about 450 g)',
        ingredients: '120 g chicken breast\n80 g basmati rice\n60 g beans',
        preparation: '1. Cook the rice.\n2. Sear the chicken.\n3. Layer.',
        caloriesKcal: 612,
        proteinG: 48,
        carbsG: 71,
        fatG: 12,
      ),
    ],
    sourceUrl: 'https://www.tiktok.com/@mealprepmia/video/7312',
  );
}

/// An imported recipe whose caption values have an unclear basis, so
/// "Add" first asks for it.
FitnessRecipe _unclearPizza() {
  final imported = const RecipeImportCandidate(
    id: 'pizza',
    title: 'High-protein pizza',
    ingredients: '125 g low-fat quark\n75 g spelt flour\n20 g mozzarella',
    preparation: 'Bake at 200 °C.',
    caloriesKcal: 507,
    proteinG: 50,
    carbsG: 61,
    fatG: 6,
    nutritionBasisUnclear: true,
  ).toRecipe(slug: 'user_import_pizza', sourceLabel: 'Source');
  return imported.copyWith(
    serverRevision: 7,
    categories: {
      ...imported.categories,
      recipeNutritionPendingCategory,
    }.toList(),
  );
}

/// A store whose meal-plan writes fail.
class _OfflinePlans extends HomeStore {
  _OfflinePlans()
    : super(
        sync: null,
        health: const NoopHealthService(),
        notificationService: const NoopNotificationService(),
        initialUserName: 'Fixture',
        emitSnack: h.SnackCapture().call,
      );

  @override
  Future<SyncDelivery> savePlannedMeal(PlannedMeal plan) async =>
      throw StateError('offline');
}

final _restorable = FitnessRecipe.fromRow({
  'slug': 'user_bowl',
  'title': 'Green power bowl',
  'ingredients': '150 g rice\n180 g chicken breast\n1 handful spinach',
  'preparation':
      'Cook the rice. Sear the chicken, slice it and serve both '
      'over the spinach.',
  'estimated_g': 420,
  'calories_kcal': 610,
});

RecipeHistoryPage _history() => RecipeHistoryPage(
  versions: [
    RecipeVersion(
      recipe: _restorable,
      revision: 4,
      deleted: false,
      recordedAt: DateTime.utc(2026, 9, 27, 17, 12),
    ),
  ],
  currentRevision: 5,
  currentDeleted: false,
  nextBefore: null,
);

void main() {
  setUpAll(loadDesignFonts);

  const sizes = <(String, double, double)>[('', 390, 1), ('-320-x2', 320, 2)];

  for (final (suffix, width, scale) in sizes) {
    testWidgets('player: save failed, then retrying$suffix', (tester) async {
      var fail = false;
      Completer<void>? gate;
      await _page(
        tester,
        TrainingPlayerScreen(
          plan: _plan(),
          // A frozen clock: the rest bar holds still for the shot.
          monotonicNow: () => Duration.zero,
          screenAwake: const NoopScreenAwake(),
          onPersist: (_) async {
            await gate?.future;
            if (fail) throw StateError('offline');
            return true;
          },
          onComplete: (_) async {},
        ),
        width: width,
        textScale: scale,
      );
      fail = true;
      await tester.ensureVisible(_key('training-set-check-0-0'));
      await tester.pump();
      await tester.tap(_key('training-set-check-0-0'));
      await _frames(tester);
      expect(_key('training-timer-save-error'), findsOneWidget);
      expect(_key('training-timer-retry'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await captureDesignShot(tester, 'feedback-player-save-failed$suffix');

      // The retry runs: the note stays, its pill waits.
      fail = false;
      gate = Completer<void>();
      await tester.tap(_key('training-timer-retry'));
      await _frames(tester);
      expect(_key('training-timer-save-error'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await captureDesignShot(tester, 'feedback-player-retrying$suffix');
      gate.complete();
      await _frames(tester);
      expect(_key('training-timer-save-error'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('plan editor: saving, then failed$suffix', (tester) async {
      final pending = Completer<SyncDelivery>();
      await _launch(
        tester,
        (context) => showTrainingPlanEditor(
          context,
          initialDraft: _proposal(),
          onSave: (_) => pending.future,
        ),
        width: width,
        textScale: scale,
      );
      await tester.tap(_key('training-editor-save'));
      await _frames(tester);
      expect(find.text(enL10n.trainingPageSaving), findsOneWidget);
      expect(tester.takeException(), isNull);
      await captureDesignShot(tester, 'feedback-plan-editor-saving$suffix');

      pending.completeError(StateError('offline'));
      await tester.pumpAndSettle();
      expect(find.text(enL10n.trainingPageSaveError), findsOneWidget);
      expect(tester.takeException(), isNull);
      await captureDesignShot(tester, 'feedback-plan-editor-error$suffix');
    });

    testWidgets('log editor: saving, then failed$suffix', (tester) async {
      await withClock(Clock.fixed(_now), () async {
        final pending = Completer<TrainingLogSaveOutcome>();
        await _launch(
          tester,
          (context) => showTrainingLogEditor(
            context,
            request: const FreeLogRequest(historyId: _logId),
            history: [_benchLog()],
            onSave: (_) => pending.future,
          ),
          width: width,
          textScale: scale,
        );
        await _type(tester, 'training-log-exercise-0-name', 'Bench press');
        await _type(tester, 'training-log-exercise-0-set-0-reps', '8');
        await _unfocus(tester);
        await tester.tap(_key('training-log-save'));
        await _frames(tester);
        expect(find.text(enL10n.trainingPageSaving), findsOneWidget);
        expect(tester.takeException(), isNull);
        await captureDesignShot(tester, 'feedback-log-editor-saving$suffix');

        pending.complete(TrainingLogSaveOutcome.failed);
        await tester.pumpAndSettle();
        expect(find.text(enL10n.trainingLogSaveError), findsOneWidget);
        expect(tester.takeException(), isNull);
        await captureDesignShot(tester, 'feedback-log-editor-error$suffix');
      });
    });

    testWidgets('coach brief: request refused$suffix', (tester) async {
      final active = ValueNotifier<bool>(true);
      addTearDown(active.dispose);
      await _launch(
        tester,
        (context) => showCoachTrainingBrief(
          context,
          selectedPlan: _plan(),
          canSubmit: () => false,
          isActive: active,
        ),
        width: width,
        textScale: scale,
      );
      await tester.tap(_key('coach-brief-submit'));
      await tester.pumpAndSettle();
      expect(find.text(enL10n.coachBriefUnavailable), findsOneWidget);
      expect(tester.takeException(), isNull);
      await captureDesignShot(tester, 'feedback-brief-error$suffix');
    });

    testWidgets('workout detail: delete failed$suffix', (tester) async {
      await withClock(Clock.fixed(_now), () async {
        await _launch(
          tester,
          (context) => Navigator.push(
            context,
            MaterialPageRoute<void>(
              builder: (_) => TrainingHistoryDetail(
                entry: _benchLog(),
                onDelete: (_) async => throw StateError('offline'),
              ),
            ),
          ),
          width: width,
          textScale: scale,
        );
        final delete = _key('training-history-delete');
        await tester.scrollUntilVisible(delete, 250);
        await _tapVisible(tester, delete);
        await tester.tap(find.text(enL10n.trainingHistoryDeleteAction).last);
        await tester.pumpAndSettle();
        expect(find.text(enL10n.trainingHistoryDeleteError), findsOneWidget);
        await tester.scrollUntilVisible(delete, 250);
        await _reveal(tester, delete);
        expect(tester.takeException(), isNull);
        await captureDesignShot(tester, 'feedback-history-detail-error$suffix');
      });
    });

    // The create sheet and its ingredient editor share one launch.
    Future<_Products> openCreate(
      WidgetTester tester, {
      Future<SyncDelivery> Function(FitnessRecipe)? onCreate,
    }) async {
      final products = _Products();
      await _page(
        tester,
        RecipesScreen(
          onAddMeal: (_, _) {},
          onCreateRecipe: onCreate ?? (_) async => SyncDelivery.delivered,
          productService: products,
        ),
        width: width,
        textScale: scale,
        scaffold: true,
      );
      await openRecipeCreateSheet(tester);
      expect(_key('recipe-create-sheet'), findsOneWidget);
      return products;
    }

    testWidgets('recipe create: save failed$suffix', (tester) async {
      await withClock(Clock.fixed(_now), () async {
        await openCreate(
          tester,
          onCreate: (_) async => throw StateError('offline'),
        );
        await _type(tester, 'recipe-create-name', 'Overnight oats');
        await _type(tester, 'recipe-create-kcal', '420');
        await _unfocus(tester);
        await _tapVisible(tester, _key('recipe-create-save'));
        expect(_key('recipe-edit-save-error'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await captureDesignShot(tester, 'feedback-recipe-create-error$suffix');
      });
    });

    testWidgets('ingredient search: running, then failed$suffix', (
      tester,
    ) async {
      await withClock(Clock.fixed(_now), () async {
        final products = await openCreate(tester);
        await _type(tester, 'recipe-create-name', 'Overnight oats');
        await _unfocus(tester);
        await _tapVisible(tester, _key('recipe-create-structured'));
        await _tapVisible(tester, _key('ingredient-add'));
        await tester.enterText(_key('ingredient-query'), 'oats');
        await tester.pump();
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pump();
        await tester.ensureVisible(_key('ingredient-search-submit'));
        await tester.pump();
        await tester.tap(_key('ingredient-search-submit'));
        await _frames(tester);
        final spinner = find.byType(CircularProgressIndicator);
        expect(spinner, findsOneWidget);
        await tester.ensureVisible(spinner);
        await _frames(tester);
        expect(tester.takeException(), isNull);
        await captureDesignShot(tester, 'feedback-ingredient-searching$suffix');

        products.pending!.completeError(StateError('offline'));
        await tester.pumpAndSettle();
        final error = find.text(enL10n.ingredientSearchError);
        expect(error, findsOneWidget);
        await _reveal(tester, error);
        expect(tester.takeException(), isNull);
        await captureDesignShot(tester, 'feedback-ingredient-error$suffix');
      });
    });

    testWidgets('recipe import: required fields missing$suffix', (
      tester,
    ) async {
      await _launch(
        tester,
        (context) => showRecipeImportSheet(
          context: context,
          service: _ImportService(),
          onSave: (FitnessRecipe _) async => SyncDelivery.delivered,
          sessionIsCurrent: () => true,
        ),
        width: width,
        textScale: scale,
      );
      await _type(
        tester,
        'recipe-import-input',
        'https://www.tiktok.com/@mealprepmia/video/7312',
      );
      await _tapVisible(tester, _key('recipe-import-analyze'));
      await _tapVisible(tester, _key('recipe-import-edit'));
      await _type(tester, 'recipe-import-edit-title', '');
      await _unfocus(tester);
      await _tapVisible(tester, _key('recipe-import-finish-editing'));
      expect(find.text(enL10n.recipeImportRequiredFields), findsOneWidget);
      await _reveal(tester, _key('recipe-import-finish-editing'));
      expect(tester.takeException(), isNull);
      await captureDesignShot(tester, 'feedback-recipe-import-error$suffix');
    });

    testWidgets('nutrition basis: save failed$suffix', (tester) async {
      await _page(
        tester,
        RecipeDetailScreen(
          recipe: _unclearPizza(),
          onEdit: (_) async => throw StateError('offline'),
          onAddMeal: (_, _) {},
        ),
        width: width,
        textScale: scale,
      );
      await _tapVisible(tester, _key('recipe-add-button'));
      expect(_key('recipe-nutrition-basis-sheet'), findsOneWidget);
      await _tapVisible(tester, _key('recipe-nutrition-basis-confirm'));
      expect(find.text(enL10n.recipeEditSaveFailed), findsOneWidget);
      await _reveal(tester, _key('recipe-nutrition-basis-error'));
      expect(tester.takeException(), isNull);
      await captureDesignShot(tester, 'feedback-nutrition-basis-error$suffix');
    });

    testWidgets('meal plan editor: save failed$suffix', (tester) async {
      await withClock(Clock.fixed(_monday), () async {
        final store = _OfflinePlans();
        addTearDown(store.dispose);
        await _page(
          tester,
          MealPlanScreen(store: store),
          width: width,
          textScale: scale,
        );
        final add = _key('meal-plan-add-2026-09-28');
        await tester.scrollUntilVisible(
          add,
          200,
          scrollable: designMainScrollable(),
        );
        await _tapVisible(tester, add);
        await _tapVisible(
          tester,
          find.descendant(
            of: _key('meal-plan-editor-scroll'),
            matching: find.text(recipeCatalogEn.first.title),
          ),
        );
        await _tapVisible(tester, _key('meal-plan-save'));
        expect(find.text(enL10n.mealPlanSaveError), findsOneWidget);
        await _reveal(tester, _key('meal-plan-save'));
        await precacheDesignImages(tester);
        expect(tester.takeException(), isNull);
        await captureDesignShot(
          tester,
          'feedback-meal-plan-editor-error$suffix',
        );
      });
    });

    testWidgets('data export: loading$suffix', (tester) async {
      final pending = Completer<String>();
      await _launch(
        tester,
        (context) =>
            showDataExportSheet(context, snapshot: () => pending.future),
        width: width,
        textScale: scale,
        settle: false,
      );
      // At 2x text the spinner sits below the fold of the lazy list.
      final spinner = find.byType(CircularProgressIndicator);
      await tester.scrollUntilVisible(spinner, 120);
      await _frames(tester);
      expect(spinner, findsOneWidget);
      expect(tester.takeException(), isNull);
      await captureDesignShot(tester, 'feedback-export-loading$suffix');
      pending.completeError(StateError('offline'));
      await tester.pumpAndSettle();
    });

    testWidgets('recipe history: restore confirmed$suffix', (tester) async {
      final restore = Completer<SyncDelivery>();
      await _page(
        tester,
        RecipeHistoryScreen(
          loadHistory: ({slug, beforeRevision}) async => _history(),
          restoreVersion: (recipe, {required expectedRevision}) =>
              restore.future,
          isSessionCurrent: () => true,
        ),
        width: width,
        textScale: scale,
      );
      await _tapVisible(tester, _key('recipe-history-version-4'));
      final pill = _key('recipe-history-restore-4');
      await _tapVisible(tester, pill);
      await tester.tap(_key('recipe-history-confirm'));
      await _frames(tester);
      expect(_key('recipe-history-confirm'), findsNothing);
      await tester.ensureVisible(pill);
      await _frames(tester);
      expect(tester.takeException(), isNull);
      await captureDesignShot(
        tester,
        'feedback-recipe-history-restoring$suffix',
      );
      // The confirmed restore shows on the tapped pill, not as a spinner at
      // the end of the list.
      expect(
        find.descendant(of: pill, matching: find.text('Restoring…')),
        findsOneWidget,
      );
      expect(find.byType(CircularProgressIndicator), findsNothing);
      restore.complete(SyncDelivery.delivered);
      await tester.pumpAndSettle();
    });
  }
}
