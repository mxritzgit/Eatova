// Visual evidence for the recipe import sheet redesign (2026-10-03): the
// three-step strip with the paste pill, the calm reading state, candidate
// cards with the source pill, and the preview with section cards, bullet
// ingredients and numbered steps.
//
// With --dart-define=DARK_REDESIGN_CAPTURE=true the PNGs land in
// build/dark-redesign/recipe-import-*.png; without it the suite still checks
// that every state renders without an exception or overflow, including at
// 320 px and 2x text.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/recipe_import_result.dart';
import 'package:eatova/src/screens/recipes/recipe_import_sheet.dart';
import 'package:eatova/src/services/recipe_import_service.dart';
import 'package:eatova/src/services/sync_error_messages.dart';

import '../support/design_capture.dart';
import '../support/harness.dart';

const _source = 'https://www.tiktok.com/@mealprepmia/video/7312';

const _bowl = RecipeImportCandidate(
  id: 'bowl',
  title: 'Chicken burrito bowl',
  ingredients: '120 g chicken breast\n80 g rice\n60 g black beans',
  preparation: 'Cook the rice.\nSear the chicken.\nLayer everything.',
  portion: '1 bowl',
);

const _tofu = RecipeImportCandidate(
  id: 'tofu',
  title: 'Tofu burrito bowl',
  variantLabel: 'Vegan',
  ingredients: '150 g smoked tofu\n80 g rice\n60 g black beans',
  preparation: 'Cook the rice.\nCrisp the tofu.\nLayer everything.',
  portion: '1 bowl',
);

const _preview = RecipeImportCandidate(
  id: 'preview',
  title: 'High-protein chicken burrito bowl',
  description: 'Meal-prep friendly and ready in 25 minutes.',
  portion: '1 bowl (about 450 g)',
  ingredients:
      '- 120 g chicken breast\n- 80 g basmati rice\n- 60 g black beans\n'
      '- 50 g corn\n- 1 tbsp lime juice\n- Fresh coriander',
  preparation:
      '1. Cook the rice and stir in the lime juice.\n'
      '2. Season the chicken and sear it for 6 minutes per side.\n'
      '3. Warm the beans and corn.\n'
      '4. Layer everything in a bowl and top with coriander.',
  caloriesKcal: 612,
  proteinG: 48,
  carbsG: 71,
  fatG: 12,
  nutritionBasisUnclear: true,
);

class _Service implements RecipeImportService {
  _Service(this.respond);
  final Future<RecipeImportResult> Function() respond;

  @override
  Future<RecipeImportResult> extract(String text, {required String locale}) =>
      respond();
}

Future<void> _openSheet(
  WidgetTester tester, {
  required Future<RecipeImportResult> Function() respond,
  Locale locale = const Locale('en'),
  Brightness brightness = Brightness.dark,
  double textScale = 1,
  String initialText = '',
}) async {
  await tester.pumpWidget(
    designCaptureBoundary(
      localizedApp(
        Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => showRecipeImportSheet(
                context: context,
                service: _Service(respond),
                onSave: (FitnessRecipe _) async => SyncDelivery.delivered,
                sessionIsCurrent: () => true,
                initialText: initialText,
              ),
              child: const Text('open'),
            ),
          ),
        ),
        locale: locale,
        brightness: brightness,
        textScale: textScale,
        safeArea: false,
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

Future<void> _analyze(WidgetTester tester) async {
  await tester.enterText(
    find.byKey(const ValueKey('recipe-import-input')),
    _source,
  );
  await tester.pumpAndSettle();
  final analyze = find.byKey(const ValueKey('recipe-import-analyze'));
  await tester.ensureVisible(analyze);
  await tester.pumpAndSettle();
  await tester.tap(analyze);
}

Future<RecipeImportResult> _two() async => const RecipeImportResult(
  status: RecipeImportStatus.ready,
  candidates: [_bowl, _tofu],
  sourceUrl: _source,
);

Future<RecipeImportResult> _one() async => const RecipeImportResult(
  status: RecipeImportStatus.ready,
  candidates: [_preview],
  sourceUrl: _source,
);

void main() {
  setUpAll(loadDesignFonts);

  for (final (locale, shot) in [
    (const Locale('en'), 'recipe-import-00-input-en'),
    (const Locale('de'), 'recipe-import-01-input-de'),
  ]) {
    testWidgets('input state (${locale.languageCode})', (tester) async {
      pinDesignViewport(tester);
      await _openSheet(tester, respond: _two, locale: locale);
      expect(find.byKey(const ValueKey('recipe-import-steps')), findsOneWidget);
      expect(find.byKey(const ValueKey('recipe-import-paste')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await captureDesignShot(tester, shot);
    });
  }

  testWidgets('reading state', (tester) async {
    pinDesignViewport(tester);
    final pending = Completer<RecipeImportResult>();
    await _openSheet(tester, respond: () => pending.future);
    await _analyze(tester);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('recipe-import-loading')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await captureDesignShot(tester, 'recipe-import-02-reading');
    pending.complete(await _two());
    await tester.pumpAndSettle();
  });

  testWidgets('choices state', (tester) async {
    pinDesignViewport(tester);
    await _openSheet(tester, respond: _two);
    await _analyze(tester);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('recipe-import-candidate-tofu')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await captureDesignShot(tester, 'recipe-import-03-choices');
  });

  Finder sheetScroll() => find.descendant(
    of: find.byKey(const ValueKey('recipe-import-sheet')),
    matching: find.byType(Scrollable),
  );

  testWidgets('preview state', (tester) async {
    pinDesignViewport(tester);
    await _openSheet(tester, respond: _one);
    await _analyze(tester);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('recipe-import-hero')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await captureDesignShot(tester, 'recipe-import-04-preview');
    await scrollDesignTabBy(tester, 620, scrollable: sheetScroll());
    expect(tester.takeException(), isNull);
    await captureDesignShot(tester, 'recipe-import-05-preview-scrolled');
    // Clamped to the end: edit pill, review hint and the save action.
    await scrollDesignTabBy(tester, 4000, scrollable: sheetScroll());
    expect(find.byKey(const ValueKey('recipe-import-save')), findsOneWidget);
    await captureDesignShot(tester, 'recipe-import-06-preview-end');
  });

  testWidgets('preview state in light mode', (tester) async {
    pinDesignViewport(tester);
    await _openSheet(tester, respond: _one, brightness: Brightness.light);
    await _analyze(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('recipe-import-source')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('recipe-import-source-details')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await captureDesignShot(tester, 'recipe-import-07-preview-light');
  });

  for (final locale in [const Locale('en'), const Locale('de')]) {
    testWidgets('every state fits 320 px at 2x text (${locale.languageCode})', (
      tester,
    ) async {
      tester.view
        ..devicePixelRatio = 1
        ..physicalSize = const Size(320, 720);
      addTearDown(tester.view.reset);
      final pending = Completer<RecipeImportResult>();
      await _openSheet(
        tester,
        respond: () => pending.future,
        locale: locale,
        textScale: 2,
      );
      expect(tester.takeException(), isNull);
      final narrow = 'recipe-import-08-narrow-${locale.languageCode}';
      await captureDesignShot(tester, '$narrow-input');
      await _analyze(tester);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      pending.complete(await _two());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final card = find.byKey(const ValueKey('recipe-import-candidate-tofu'));
      await tester.ensureVisible(card);
      await tester.pumpAndSettle();
      await captureDesignShot(tester, '$narrow-choices');
      await tester.ensureVisible(card);
      await tester.pumpAndSettle();
      await tester.tap(card);
      await tester.pumpAndSettle();
      final source = find.byKey(const ValueKey('recipe-import-source'));
      await tester.ensureVisible(source);
      await tester.pumpAndSettle();
      await tester.tap(source);
      await tester.pumpAndSettle();
      for (final key in ['recipe-import-edit', 'recipe-import-save']) {
        await tester.ensureVisible(find.byKey(ValueKey(key)));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: key);
      }
    });
  }
}
