// The AI consent gate at the food and import entry points (review
// 2026-10-19, P1): the photo scan from the Food tab and from the add sheet
// (camera and gallery), describing a meal and the recipe import ask before
// anything is picked or sent, and "Not now" sends nothing.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

import 'package:eatova/src/app/ai_trust.dart';
import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_request.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/recipe_import_result.dart';
import 'package:eatova/src/screens/meal_analysis_screen.dart';
import 'package:eatova/src/screens/recipes/recipe_import_sheet.dart';
import 'package:eatova/src/services/meal_analyzer.dart';
import 'package:eatova/src/services/meal_camera_launcher.dart';
import 'package:eatova/src/services/meal_photo_input.dart';
import 'package:eatova/src/services/open_food_facts_product_service.dart';
import 'package:eatova/src/services/recipe_import_service.dart';
import 'package:eatova/src/services/sync_error_messages.dart';
import 'package:eatova/src/widgets/kcal/add_meal_sheet.dart';

import '../describe/ui/describe_harness.dart';
import '../support/ai_trust_fakes.dart';
import '../support/harness.dart';

final Finder _consentSheet = find.byKey(const ValueKey('ai-consent-sheet'));

Future<void> _notNow(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('ai-consent-not-now')));
  await tester.pumpAndSettle();
}

Future<void> _agree(WidgetTester tester) async {
  final check = find.byKey(const ValueKey('ai-consent-health-check'));
  await tester.ensureVisible(check);
  await tester.tap(check);
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('ai-consent-accept')));
  await tester.pumpAndSettle();
}

class _CountingPhotos implements MealPhotoInput {
  final List<ImageSource> picks = <ImageSource>[];

  @override
  Future<MealPhotoSelection?> pick(ImageSource source) async {
    picks.add(source);
    return null;
  }
}

class _CountingAnalyzer implements MealAnalyzer {
  int calls = 0;

  @override
  Future<MealAnalysisResult> analyze(MealAnalysisRequest request) {
    calls++;
    throw StateError('must not run without consent');
  }
}

class _CountingCamera implements MealCameraLauncher {
  int launches = 0;

  @override
  Future<MealCameraCapture?> launch(
    BuildContext context, {
    required MealSlot initialSlot,
  }) async {
    launches++;
    return null;
  }
}

class _NoProducts implements ProductLookupService {
  @override
  Future<MealAnalysisResult> lookupBarcode(String barcode) =>
      throw StateError('no barcode in these tests');

  @override
  Future<List<ProductSearchResult>> searchProducts(String query) async =>
      const <ProductSearchResult>[];
}

class _ImportService implements RecipeImportService {
  final List<String> inputs = <String>[];

  @override
  Future<RecipeImportResult> extract(String text, {required String locale}) {
    inputs.add(text);
    return Future<RecipeImportResult>.value(
      const RecipeImportResult(
        status: RecipeImportStatus.noRecipe,
        candidates: <RecipeImportCandidate>[],
      ),
    );
  }
}

typedef _AddSheet = ({
  _CountingPhotos photos,
  _CountingCamera camera,
  DescribeHost describe,
});

Future<_AddSheet> _openAddSheet(
  WidgetTester tester,
  AiTrustController controller,
) async {
  final photos = _CountingPhotos();
  final camera = _CountingCamera();
  final h = DescribeHost();
  phoneViewport(tester);
  await tester.pumpWidget(
    withAiTrust(
      controller,
      localizedApp(
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showAddMealSheet(
              context,
              slot: MealSlot.lunch,
              analyzer: _CountingAnalyzer(),
              productService: _NoProducts(),
              photoInput: photos,
              cameraLauncher: camera,
              favorites: const [],
              onAdd: h.onAdd,
              onUpdateMeal: (_, _) {},
              onRemoveFavorite: (_) {},
              describer: h.describer,
              describeMatcher: h.matcher,
              speechInput: h.speech,
              screenAwake: h.awake,
              dictationLanguageStore: h.languages,
            ),
            child: const Text('open'),
          ),
        ),
        safeArea: false,
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return (photos: photos, camera: camera, describe: h);
}

Future<void> _tapEntry(WidgetTester tester, String key) async {
  final entry = find.byKey(ValueKey(key));
  await tester.ensureVisible(entry);
  await tester.pumpAndSettle();
  await tester.tap(entry);
  await tester.pumpAndSettle();
}

void main() {
  group('Add-Sheet', () {
    for (final (key, opens) in <(String, int Function(_AddSheet))>[
      ('analyse-camera-button', (sheet) => sheet.camera.launches),
      ('analyse-gallery-button', (sheet) => sheet.photos.picks.length),
    ]) {
      testWidgets('$key fragt vor der Auswahl; "Nicht jetzt" oeffnet nichts', (
        tester,
      ) async {
        final log = FakeAiTrustLog();
        final controller = await aiTrustController(log: log);
        final opened = await _openAddSheet(tester, controller);

        await _tapEntry(tester, key);
        expect(_consentSheet, findsOneWidget);
        expect(opens(opened), 0);

        await _notNow(tester);
        expect(opens(opened), 0);
        expect(log.rows, isEmpty);

        await _tapEntry(tester, key);
        await _agree(tester);
        expect(opens(opened), 1);
        expect(log.rows.single.granted, isTrue);
      });
    }

    testWidgets('Beschreiben fragt, bevor das Blatt aufgeht', (tester) async {
      final controller = await aiTrustController();
      await _openAddSheet(tester, controller);

      await _tapEntry(tester, 'describe-entry-button');
      expect(_consentSheet, findsOneWidget);
      await _notNow(tester);
      expect(find.byKey(const ValueKey('meal-describe-sheet')), findsNothing);

      await _tapEntry(tester, 'describe-entry-button');
      await _agree(tester);
      expect(find.byKey(const ValueKey('meal-describe-sheet')), findsOneWidget);
    });
  });

  testWidgets('Food-Tab: der KI-Scan fragt vor der Kamera', (tester) async {
    final camera = _CountingCamera();
    final analyzer = _CountingAnalyzer();
    final controller = await aiTrustController();
    await tester.pumpWidget(
      withAiTrust(
        controller,
        localizedApp(
          MealAnalysisScreen(
            dailyConsumedKcal: 0,
            analyzer: analyzer,
            cameraLauncher: camera,
          ),
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('food-action-ai')));
    await tester.pumpAndSettle();
    expect(_consentSheet, findsOneWidget);
    await _notNow(tester);

    expect(camera.launches, 0);
    expect(analyzer.calls, 0);

    await tester.tap(find.byKey(const ValueKey('food-action-ai')));
    await tester.pumpAndSettle();
    await _agree(tester);
    expect(camera.launches, 1);
  });

  testWidgets('App-Kurzbefehle Foto und Beschreiben fragen wie das Dock', (
    tester,
  ) async {
    final describeSheet = find.byKey(const ValueKey('meal-describe-sheet'));
    for (final capture in [FoodCapture.photo, FoodCapture.describe]) {
      final camera = _CountingCamera();
      bool opened() => capture == FoodCapture.photo
          ? camera.launches > 0
          : describeSheet.evaluate().isNotEmpty;
      final request = ValueNotifier<FoodCapture?>(null);
      addTearDown(request.dispose);
      phoneViewport(tester);
      await tester.pumpWidget(
        withAiTrust(
          await aiTrustController(),
          localizedApp(
            MealAnalysisScreen(
              dailyConsumedKcal: 0,
              analyzer: _CountingAnalyzer(),
              productService: _NoProducts(),
              cameraLauncher: camera,
              captureRequest: request,
            ),
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
          ),
        ),
      );
      await tester.pumpAndSettle();

      request.value = capture;
      await tester.pumpAndSettle();
      expect(_consentSheet, findsOneWidget, reason: '$capture');
      await _notNow(tester);
      expect(opened(), isFalse, reason: '$capture');

      request.value = capture;
      await tester.pumpAndSettle();
      await _agree(tester);
      expect(opened(), isTrue, reason: '$capture');
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets('Rezept-Import: der geteilte Text geht erst nach der '
      'Einwilligung raus und bleibt bei "Nicht jetzt" stehen', (tester) async {
    final service = _ImportService();
    final controller = await aiTrustController();
    phoneViewport(tester);
    await tester.pumpWidget(
      withAiTrust(
        controller,
        localizedApp(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => showRecipeImportSheet(
                context: context,
                service: service,
                onSave: (FitnessRecipe recipe) async => SyncDelivery.delivered,
                sessionIsCurrent: () => true,
                initialText: 'https://www.tiktok.com/@cook/video/1',
              ),
              child: const Text('open'),
            ),
          ),
          safeArea: false,
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // The shared link starts an import by itself; the consent comes first.
    expect(_consentSheet, findsOneWidget);
    await _notNow(tester);
    expect(service.inputs, isEmpty);
    expect(find.byKey(const ValueKey('recipe-import-sheet')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('recipe-import-analyze')));
    await tester.pumpAndSettle();
    await _agree(tester);
    expect(service.inputs, <String>['https://www.tiktok.com/@cook/video/1']);
  });
}
