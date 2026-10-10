// Visual evidence for "describe a meal by text or voice": the add sheet's
// new entry, the input step (empty, typed, listening on iOS, a no-food hint),
// the working step, the draft and the line editor, in dark and light, plus
// 320 px with 2x text.
//
// With --dart-define=DARK_REDESIGN_CAPTURE=true the PNGs land in
// build/dark-redesign/describe-*.png; without it every state still checks
// that it rendered without an exception or overflow.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_request.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/services/meal_analyzer.dart';
import 'package:eatova/src/services/meal_photo_input.dart';
import 'package:eatova/src/services/open_food_facts_product_service.dart';
import 'package:eatova/src/widgets/kcal/add_meal_sheet.dart';
import 'package:eatova/src/widgets/kcal/meal_describe_sheet.dart';

import '../describe/ui/describe_fakes.dart';
import '../support/design_capture.dart';
import '../support/harness.dart';

class _NoPhotos implements MealPhotoInput {
  @override
  Future<MealPhotoSelection?> pick(ImageSource source) async => null;
}

class _NoAnalyzer implements MealAnalyzer {
  @override
  Future<MealAnalysisResult> analyze(MealAnalysisRequest request) =>
      Completer<MealAnalysisResult>().future;
}

class _NoProducts implements ProductLookupService {
  @override
  Future<MealAnalysisResult> lookupBarcode(String barcode) =>
      Completer<MealAnalysisResult>().future;

  @override
  Future<List<ProductSearchResult>> searchProducts(String query) async =>
      const <ProductSearchResult>[];
}

Finder _key(String value) => find.byKey(ValueKey(value));

class _Rig {
  final FakeSpeech speech = FakeSpeech();
  final FakeDescriber describer = FakeDescriber();
  final FakeMatcher matcher = FakeMatcher();
}

Future<_Rig> _open(
  WidgetTester tester, {
  required Brightness brightness,
  Locale locale = const Locale('en'),
  double width = 390,
  double textScale = 1,
  bool addSheet = false,
}) async {
  final rig = _Rig();
  pinDesignViewport(tester);
  tester.view.physicalSize =
      Size(width, kDesignViewport.height) * kDesignPixelRatio;
  await tester.pumpWidget(
    designCaptureBoundary(
      localizedApp(
        Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => addSheet
                  ? showAddMealSheet(
                      context,
                      slot: MealSlot.breakfast,
                      analyzer: _NoAnalyzer(),
                      productService: _NoProducts(),
                      photoInput: _NoPhotos(),
                      favorites: const [],
                      onAdd: (_, _) => 'id',
                      onUpdateMeal: (_, _) {},
                      onRemoveFavorite: (_) {},
                      describer: rig.describer,
                      describeMatcher: rig.matcher,
                      speechInput: rig.speech,
                      screenAwake: FakeAwake(),
                      dictationLanguageStore: MemoryLanguageStore(),
                    )
                  : showMealDescribeSheet(
                      context,
                      initialSlot: MealSlot.breakfast,
                      describer: rig.describer,
                      matcher: rig.matcher,
                      onAdd: (_, _) => 'id',
                      onUpdateMeal: (_, _) {},
                      speechInput: rig.speech,
                      screenAwake: FakeAwake(),
                      dictationLanguageStore: MemoryLanguageStore(),
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
  return rig;
}

Future<void> _shot(WidgetTester tester, String name) async {
  expect(tester.takeException(), isNull);
  await captureDesignShot(tester, name);
}

Future<void> _type(WidgetTester tester, String text) async {
  await tester.enterText(_key('meal-describe-input'), text);
  await tester.pump();
  // The keyboard is not part of the shot.
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pumpAndSettle();
}

Future<void> _toDraft(WidgetTester tester) async {
  await _type(tester, 'Nutella on a slice of toast from Lidl');
  await tester.ensureVisible(_key('meal-describe-submit'));
  await tester.pumpAndSettle();
  await tester.tap(_key('meal-describe-submit'));
  await tester.pumpAndSettle();
  expect(_key('meal-describe-line-0'), findsOneWidget);
}

Future<void> _scrollToEnd(WidgetTester tester) async {
  final position = tester
      .state<ScrollableState>(
        find
            .descendant(
              of: _key('meal-describe-scroll'),
              matching: find.byType(Scrollable),
            )
            .first,
      )
      .position;
  position.jumpTo(position.maxScrollExtent);
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadDesignFonts);

  for (final brightness in Brightness.values) {
    final tone = brightness.name;
    group(tone, () {
      testWidgets('add sheet with the describe entry', (tester) async {
        await _open(tester, brightness: brightness, addSheet: true);
        expect(_key('describe-entry-button').hitTestable(), findsOneWidget);
        await _shot(tester, 'describe-entry-$tone');
      });

      testWidgets('input: empty, iOS', (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        try {
          await _open(tester, brightness: brightness);
          await _shot(tester, 'describe-input-$tone');
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      });

      testWidgets('input: typed', (tester) async {
        await _open(tester, brightness: brightness);
        await _type(tester, 'Nutella on a slice of toast from Lidl');
        await _shot(tester, 'describe-typed-$tone');
      });

      testWidgets('input: listening, iOS partials', (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        try {
          final rig = await _open(tester, brightness: brightness);
          await tester.tap(_key('meal-describe-mic'));
          await tester.pump();
          rig.speech.partial('Two scrambled eggs with a slice of rye');
          await tester.pumpAndSettle();
          await _shot(tester, 'describe-listening-$tone');
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      });

      testWidgets('input: no food found', (tester) async {
        final rig = await _open(tester, brightness: brightness);
        rig.describer.error = const MealAnalysisServerError(
          statusCode: 422,
          code: 'no_food_in_text',
        );
        await _type(tester, 'What a lovely day');
        await tester.tap(_key('meal-describe-submit'));
        await tester.pumpAndSettle();
        await _shot(tester, 'describe-no-food-$tone');
      });

      testWidgets('working', (tester) async {
        final rig = await _open(tester, brightness: brightness);
        rig.describer.pending = Completer();
        await _type(tester, 'Nutella on a slice of toast from Lidl');
        await tester.tap(_key('meal-describe-submit'));
        await tester.pump();
        await tester.pump(const Duration(seconds: 3));
        await _shot(tester, 'describe-working-$tone');
        await tester.tap(_key('meal-describe-cancel'));
        await tester.pumpAndSettle();
      });

      testWidgets('draft', (tester) async {
        await _open(tester, brightness: brightness);
        await _toDraft(tester);
        await _shot(tester, 'describe-draft-$tone');
      });

      testWidgets('line editor', (tester) async {
        await _open(tester, brightness: brightness);
        await _toDraft(tester);
        await tester.tap(_key('meal-describe-line-1'));
        await tester.pumpAndSettle();
        await _shot(tester, 'describe-line-$tone');
      });
    });
  }

  testWidgets('German draft', (tester) async {
    await _open(
      tester,
      brightness: Brightness.dark,
      locale: const Locale('de'),
    );
    await _toDraft(tester);
    await _shot(tester, 'describe-draft-de');
  });

  testWidgets('320 px, 2x text: input and draft', (tester) async {
    await _open(
      tester,
      brightness: Brightness.dark,
      locale: const Locale('de'),
      width: 320,
      textScale: 2,
    );
    await _shot(tester, 'describe-input-320-x2');
    await _scrollToEnd(tester);
    await _shot(tester, 'describe-input-320-x2-end');
    await _toDraft(tester);
    await _shot(tester, 'describe-draft-320-x2');
    await _scrollToEnd(tester);
    await _shot(tester, 'describe-draft-320-x2-end');
    await tester.tap(_key('meal-describe-line-1'));
    await tester.pumpAndSettle();
    await _shot(tester, 'describe-line-320-x2');
  });
}
