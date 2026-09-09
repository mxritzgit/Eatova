import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_request.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/screens/meal_analysis_screen.dart';
import 'package:eatova/src/services/meal_analyzer.dart';
import 'package:eatova/src/services/meal_camera_launcher.dart';
import 'package:eatova/src/services/meal_photo_input.dart';
import 'package:eatova/src/services/meal_scan_identity.dart';
import 'package:eatova/src/services/open_food_facts_product_service.dart';
import 'package:eatova/src/services/recipe_image_store.dart';
import 'package:eatova/src/widgets/design/controls.dart';
import 'package:eatova/src/widgets/kcal/add_meal_sheet.dart';
import 'package:eatova/src/widgets/kcal/meal_scan_preview_sheet.dart';

import 'support/harness.dart';

class _Analyzer implements MealAnalyzer {
  final requests = <MealAnalysisRequest>[];
  final result = Completer<MealAnalysisResult>();

  @override
  Future<MealAnalysisResult> analyze(MealAnalysisRequest request) {
    requests.add(request);
    return result.future;
  }
}

class _PhotoInput implements MealPhotoInput {
  final sources = <ImageSource>[];

  @override
  Future<MealPhotoSelection?> pick(ImageSource source) async {
    sources.add(source);
    return const MealPhotoSelection(
      request: MealAnalysisRequest(imageId: 'local-photo'),
      previewBytes: null,
    );
  }
}

class _Products implements ProductLookupService {
  @override
  Future<MealAnalysisResult> lookupBarcode(String barcode) =>
      throw UnimplementedError();

  @override
  Future<List<ProductSearchResult>> searchProducts(String query) async => [];
}

class _Camera implements MealCameraLauncher {
  @override
  Future<MealCameraCapture?> launch(
    BuildContext context, {
    required MealSlot initialSlot,
  }) async => const MealCameraCapture(
    request: MealAnalysisRequest(imageId: 'local-photo'),
    previewBytes: null,
    slot: MealSlot.dinner,
  );
}

Finder _key(String key) => find.byKey(ValueKey(key));

Future<void> _tap(WidgetTester tester, String key) async {
  await tester.ensureVisible(_key(key));
  await tester.tap(_key(key));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  test('identity fences account changes before auth event delivery', () {
    String? user = 'a';
    final identity = MealScanIdentity(currentUserId: () => user);
    expect(identity.isCurrent, isTrue);
    user = 'b';
    expect(identity.isCurrent, isFalse);
    user = null;
    expect(identity.isCurrent, isFalse);
  });
  test('hint copies preserve photo, portion, language and cancellation', () {
    final bytes = Uint8List.fromList([1, 2, 3]);
    final cancel = MealAnalysisCancellation();
    final original = MealAnalysisRequest(
      imageId: 'photo',
      imageBytes: bytes,
      portionHint: MealPortionHint.large,
      cancellation: cancel,
    );
    final request = original
        .withHint(' Döner 🥙\n ohne Sauce ')
        .withLanguage('en');
    expect(request.imageBytes, same(bytes));
    expect(request.portionHint, MealPortionHint.large);
    expect(request.language, 'en');
    expect(request.cancellation, same(cancel));
    expect(request.freeTextHint, 'Döner 🥙 ohne Sauce');
    expect(original.freeTextHint, isNull);
    expect(
      buildAnalyzeMealBody(request)['freeTextHint'],
      'Döner 🥙 ohne Sauce',
    );
  });

  for (final hint in [null, '', ' \t\n\r ']) {
    test('empty or whitespace context is omitted from the wire: $hint', () {
      final body = buildAnalyzeMealBody(
        MealAnalysisRequest(imageId: 'photo', freeTextHint: hint),
      );
      expect(body.containsKey('freeTextHint'), isFalse);
    });
  }

  for (final hint in [
    'x' * 401,
    ' ' * 401,
    '${'x' * 399}🥙',
    'private\u0000note',
    'private\u007fnote',
    'private\u0085note',
    'private\u202enote',
  ]) {
    test('invalid context is rejected before creating a network client '
        '${hint.codeUnits.take(3)} / ${hint.length}', () async {
      var clients = 0;
      final analyzer = EdgeFunctionMealAnalyzer(
        tokenProvider: () => 'dummy',
        clientFactory: () {
          clients++;
          throw StateError('No network client expected');
        },
      );
      final request = MealAnalysisRequest(
        imageId: 'photo',
        imageBytes: Uint8List.fromList([1, 2, 3]),
        freeTextHint: hint,
      );
      final invalidHint = isA<MealAnalysisServerError>()
          .having((e) => e.code, 'code', 'invalid_hint')
          .having(
            (e) => e.toString(),
            'sanitized detail',
            isNot(contains('private')),
          );
      expect(() => buildAnalyzeMealBody(request), throwsA(invalidHint));
      await expectLater(analyzer.analyze(request), throwsA(invalidHint));
      expect(clients, 0);
    });
  }

  test('400 UTF-16 units preserves the complete final emoji', () {
    final hint = '${'x' * 398}🥙';
    expect(
      buildAnalyzeMealBody(
        MealAnalysisRequest(imageId: 'photo', freeTextHint: hint),
      )['freeTextHint'],
      hint,
    );
  });

  for (final source in ImageSource.values) {
    testWidgets('$source: no upload before start; cancel discards note; '
        'next scan is empty; loading close cancels', (tester) async {
      pinPhoneViewport(tester);
      final analyzer = _Analyzer();
      final photos = _PhotoInput();
      await pumpLocalized(
        tester,
        AddMealSheet(
          slot: MealSlot.lunch,
          analyzer: analyzer,
          productService: _Products(),
          photoInput: photos,
          favorites: const [],
          onAdd: (_, _) => throw StateError('Preview must not save a meal'),
          onUpdateMeal: (_, _) {},
          onRemoveFavorite: (_) {},
        ),
        locale: const Locale('en'),
        settle: true,
      );
      final entry = source == ImageSource.camera
          ? 'analyse-camera-button'
          : 'analyse-gallery-button';
      await _tap(tester, entry);
      expect(photos.sources, [source]);
      expect(analyzer.requests, isEmpty);
      expect(find.text('Note about the food (optional)'), findsOneWidget);
      await tester.enterText(_key('meal-scan-context'), 'Döner without sauce');
      await _tap(tester, 'meal-scan-cancel');
      expect(analyzer.requests, isEmpty);
      await _tap(tester, entry);
      expect(
        tester.widget<TextField>(_key('meal-scan-context')).controller!.text,
        isEmpty,
      );
      await tester.enterText(_key('meal-scan-context'), ' \n\t ');
      await _tap(tester, 'meal-scan-start');
      expect(analyzer.requests, hasLength(1));
      expect(analyzer.requests.single.freeTextHint, isNull);
      expect(analyzer.requests.single.language, 'en');
      await _tap(tester, 'analyse-sheet-close');
      expect(analyzer.requests.single.cancellation!.isCancelled, isTrue);
      await tester.pumpWidget(const SizedBox());
    });
  }

  for (final brightness in Brightness.values) {
    testWidgets('preview reflows at 320px, 2x text, keyboard: $brightness', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 740);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.view.viewInsets = const FakeViewPadding(bottom: 260);
      addTearDown(tester.view.resetViewInsets);
      await pumpLocalized(
        tester,
        const MealScanPreviewSheet(
          request: MealAnalysisRequest(imageId: 'photo'),
          previewBytes: null,
        ),
        brightness: brightness,
        textScale: 2,
      );
      await tester.enterText(_key('meal-scan-context'), '${'x' * 399}🥙');
      await tester.pump();
      expect(
        tester.widget<PrimaryActionButton>(_key('meal-scan-start')).onTap,
        isNull,
      );
      await tester.enterText(_key('meal-scan-context'), 'Döner ohne Sauce');
      await tester.pump();
      expect(
        tester.widget<PrimaryActionButton>(_key('meal-scan-start')).onTap,
        isNotNull,
      );
      await tester.ensureVisible(_key('meal-scan-start'));
      expect(
        tester.getRect(_key('meal-scan-start')).right,
        lessThanOrEqualTo(320),
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'long paste stays intact and uses the same Unicode counter as validation',
    (tester) async {
      pinPhoneViewport(tester);
      await pumpLocalized(
        tester,
        const MealScanPreviewSheet(
          request: MealAnalysisRequest(imageId: 'photo'),
          previewBytes: null,
        ),
      );
      final pasted = '${'x' * 398}🥙 without sauce';
      await tester.enterText(_key('meal-scan-context'), pasted);
      await tester.pump();
      expect(
        tester.widget<TextField>(_key('meal-scan-context')).controller!.text,
        pasted,
      );
      expect(find.text('${pasted.length}/400'), findsOneWidget);
      expect(
        tester.widget<PrimaryActionButton>(_key('meal-scan-start')).onTap,
        isNull,
      );
      await tester.enterText(_key('meal-scan-context'), '🥙' * 201);
      await tester.pump();
      expect(find.text('402/400'), findsOneWidget);
      expect(
        tester.widget<PrimaryActionButton>(_key('meal-scan-start')).onTap,
        isNull,
      );
    },
  );

  for (final camera in [true, false]) {
    testWidgets(
      'parent disposal during ${camera ? 'camera' : 'gallery'} preview never uploads',
      (tester) async {
        pinPhoneViewport(tester);
        final analyzer = _Analyzer();
        final alive = ValueNotifier(true);
        addTearDown(alive.dispose);
        await pumpLocalized(
          tester,
          ValueListenableBuilder(
            valueListenable: alive,
            builder: (_, value, _) => !value
                ? const SizedBox()
                : camera
                ? MealAnalysisScreen(
                    dailyConsumedKcal: 0,
                    analyzer: analyzer,
                    cameraLauncher: _Camera(),
                    productService: _Products(),
                  )
                : AddMealSheet(
                    slot: MealSlot.lunch,
                    analyzer: analyzer,
                    photoInput: _PhotoInput(),
                    productService: _Products(),
                    favorites: const [],
                    onAdd: (_, _) => '',
                    onUpdateMeal: (_, _) {},
                    onRemoveFavorite: (_) {},
                  ),
          ),
          settle: true,
        );
        await _tap(
          tester,
          camera ? 'food-action-ai' : 'analyse-gallery-button',
        );
        await tester.enterText(
          _key('meal-scan-context'),
          'private previous account note',
        );
        expect(analyzer.requests, isEmpty);
        alive.value = false;
        await tester.pump();
        await _tap(tester, 'meal-scan-start');
        expect(analyzer.requests, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final entry in [
    'food-action-ai',
    'analyse-camera-button',
    'analyse-gallery-button',
  ]) {
    for (final transition in ['switch', 'logout', 'return', 'refresh']) {
      testWidgets('$entry: $transition after Start before next frame', (
        tester,
      ) async {
        pinPhoneViewport(tester);
        final images = RecipeImageStore(
          baseDirectory: () async => throw StateError('No test filesystem'),
        );
        final previousImages = RecipeImageStore.instance;
        RecipeImageStore.instance = images;
        addTearDown(() => RecipeImageStore.instance = previousImages);
        await images.setActiveUser('a');
        final analyzer = _Analyzer();
        await pumpLocalized(
          tester,
          entry == 'food-action-ai'
              ? MealAnalysisScreen(
                  dailyConsumedKcal: 0,
                  analyzer: analyzer,
                  cameraLauncher: _Camera(),
                  productService: _Products(),
                )
              : AddMealSheet(
                  slot: MealSlot.lunch,
                  analyzer: analyzer,
                  photoInput: _PhotoInput(),
                  productService: _Products(),
                  favorites: const [],
                  onAdd: (_, _) => '',
                  onUpdateMeal: (_, _) {},
                  onRemoveFavorite: (_) {},
                ),
          settle: true,
        );
        await _tap(tester, entry);
        await tester.enterText(
          _key('meal-scan-context'),
          'Previous account photo context',
        );
        await tester.pump();
        // Do not await: the route is popped but its caller is still mounted.
        tester.widget<PrimaryActionButton>(_key('meal-scan-start')).onTap!();
        unawaited(
          images.setActiveUser(
            transition == 'logout'
                ? null
                : transition == 'refresh'
                ? 'a'
                : 'b',
          ),
        );
        if (transition == 'return') unawaited(images.setActiveUser('a'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(analyzer.requests, hasLength(transition == 'refresh' ? 1 : 0));
        await tester.pumpWidget(const SizedBox());
        expect(tester.takeException(), isNull);
      });
    }
    testWidgets(
      '$entry: retry does not send an old photo under a new account',
      (tester) async {
        pinPhoneViewport(tester);
        final images = RecipeImageStore(
          baseDirectory: () async => throw StateError('No test filesystem'),
        );
        final previousImages = RecipeImageStore.instance;
        RecipeImageStore.instance = images;
        addTearDown(() => RecipeImageStore.instance = previousImages);
        await images.setActiveUser('a');
        final analyzer = _Analyzer();
        await pumpLocalized(
          tester,
          entry == 'food-action-ai'
              ? MealAnalysisScreen(
                  dailyConsumedKcal: 0,
                  analyzer: analyzer,
                  cameraLauncher: _Camera(),
                  productService: _Products(),
                )
              : AddMealSheet(
                  slot: MealSlot.lunch,
                  analyzer: analyzer,
                  photoInput: _PhotoInput(),
                  productService: _Products(),
                  favorites: const [],
                  onAdd: (_, _) => '',
                  onUpdateMeal: (_, _) {},
                  onRemoveFavorite: (_) {},
                ),
          settle: true,
        );
        await _tap(tester, entry);
        await tester.enterText(
          _key('meal-scan-context'),
          'Previous account photo context',
        );
        await _tap(tester, 'meal-scan-start');
        analyzer.result.completeError(
          const MealAnalysisServerError(
            statusCode: 502,
            code: 'provider_error',
          ),
        );
        await tester.pumpAndSettle();
        expect(analyzer.requests, hasLength(1));
        unawaited(images.setActiveUser('b'));
        await _tap(tester, 'analyse-retry');
        expect(analyzer.requests, hasLength(1));
        await tester.pumpWidget(const SizedBox());
        expect(tester.takeException(), isNull);
      },
    );
  }
}
