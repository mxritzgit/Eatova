// Review 2026-10-11 (w2-food round 2): the fade under the add sheet's pinned
// search capsule was a bg gradient laid OVER the scroll view. The capsule's
// soft shadow reaches into that band, so in light mode the overlay cut it
// off in a straight line (233 -> 244 at the scroll view's top edge) on every
// resting add sheet. The fade now masks only the scroll content, and only
// once it has scrolled: at rest the shadow runs on unbroken and nothing is
// painted over it.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

import 'package:eatova/src/models/favorite_meal.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_request.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/services/meal_analyzer.dart';
import 'package:eatova/src/services/meal_photo_input.dart';
import 'package:eatova/src/services/open_food_facts_product_service.dart';
import 'package:eatova/src/widgets/kcal/add_meal_sheet.dart';

import 'support/harness.dart';

class _StummerAnalyzer implements MealAnalyzer {
  @override
  Future<MealAnalysisResult> analyze(MealAnalysisRequest request) async =>
      throw UnimplementedError();
}

class _StummerProduktdienst implements ProductLookupService {
  @override
  Future<MealAnalysisResult> lookupBarcode(String barcode) async =>
      throw UnimplementedError();

  @override
  Future<List<ProductSearchResult>> searchProducts(String query) async =>
      const <ProductSearchResult>[];
}

class _StummeFotoquelle implements MealPhotoInput {
  @override
  Future<MealPhotoSelection?> pick(ImageSource source) async => null;
}

FavoriteMeal _favorit(String name, int tag) {
  final result = MealAnalysisResult(
    mealName: name,
    caloriesKcal: 250,
    estimatedGrams: 100,
    kcalPer100G: 250,
    protein: '-',
    carbs: '-',
    fat: '-',
    confidence: 'Datenbank',
    portionNotes: '',
  );
  return FavoriteMeal(
    id: FavoriteMeal.idFor(result),
    result: result,
    addedAt: DateTime(2026, 8, tag),
    pinned: true,
  );
}

final _boundary = GlobalKey();
const double _dpr = 3;

Finder get _scroll => find.byKey(const ValueKey('add-meal-sheet-scroll'));
Finder get _fade => find.byKey(const ValueKey('add-meal-sheet-scroll-fade'));

Future<void> _pumpSheet(WidgetTester tester) async {
  // A short phone, so the favorites below the entry card scroll.
  tester.view.devicePixelRatio = _dpr;
  tester.view.physicalSize = const Size(390 * _dpr, 640 * _dpr);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    RepaintBoundary(
      key: _boundary,
      child: localizedApp(
        AddMealSheet(
          slot: MealSlot.breakfast,
          analyzer: _StummerAnalyzer(),
          productService: _StummerProduktdienst(),
          photoInput: _StummeFotoquelle(),
          favorites: [
            _favorit('Haferbrei', 3),
            _favorit('Skyr', 20),
            _favorit('Banane', 1),
          ],
          onAdd: (_, __) => 'id-1',
          onUpdateMeal: (_, __) {},
          onRemoveFavorite: (_) {},
        ),
        // The light shadow is the one the old overlay visibly cut.
        brightness: Brightness.light,
        // Motion stays on: with duration 0 the sheet's AnimatedSize
        // re-dirties itself inside its own performLayout.
        reducedMotion: false,
        safeArea: false,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void _repaintSubtree(RenderObject root) {
  root.markNeedsPaint();
  root.visitChildren(_repaintSubtree);
}

/// The RGBA rows of the whole app at [_dpr], painted with real (blurred)
/// shadows: flutter_test otherwise draws every shadow as a solid block.
Future<(ByteData, int)> _snapshot(WidgetTester tester) async {
  final boundary =
      _boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  late ByteData bytes;
  late int width;
  debugDisableShadows = false;
  try {
    _repaintSubtree(boundary);
    await tester.pump();
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: _dpr);
      width = image.width;
      bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      image.dispose();
    });
  } finally {
    debugDisableShadows = true;
    _repaintSubtree(boundary);
    await tester.pump();
  }
  return (bytes, width);
}

/// The largest step in brightness between neighbouring pixel rows across
/// the scroll view's top edge, under the middle of the search capsule.
Future<int> _stepAtScrollTop(WidgetTester tester) async {
  final top = tester.getTopLeft(_scroll).dy * _dpr;
  final x = (tester.getCenter(_scroll).dx * _dpr).round();
  final (bytes, width) = await _snapshot(tester);
  int grey(int y) {
    final i = (y * width + x) * 4;
    return (bytes.getUint8(i) +
            bytes.getUint8(i + 1) +
            bytes.getUint8(i + 2)) ~/
        3;
  }

  final edge = top.round();
  var step = 0;
  for (var y = edge - 3; y < edge + 3; y++) {
    step = math.max(step, (grey(y + 1) - grey(y)).abs());
  }
  return step;
}

ScrollPosition _position(WidgetTester tester) => tester
    .state<ScrollableState>(
      find.descendant(of: _scroll, matching: find.byType(Scrollable)),
    )
    .position;

void main() {
  testWidgets('at rest the capsule shadow runs on and nothing is masked', (
    tester,
  ) async {
    await _pumpSheet(tester);
    expect(_position(tester).pixels, 0);

    // No layer at rest: the resting sheet paints exactly as without a fade.
    expect(tester.renderObject(_fade).debugLayer, isNull);

    // The overlay replaced the shadow with the bare ground at this edge: a
    // step of 11 grey levels where the shadow otherwise eases by 1 or 2.
    expect(
      await _stepAtScrollTop(tester),
      lessThanOrEqualTo(3),
      reason: 'the search capsule shadow is cut at the scroll view',
    );
  });

  testWidgets('scrolled, only the scroll content fades under the capsule', (
    tester,
  ) async {
    await _pumpSheet(tester);
    final position = _position(tester);
    expect(position.maxScrollExtent, greaterThan(60));

    position.jumpTo(60);
    await tester.pumpAndSettle();
    final layer = tester.renderObject(_fade).debugLayer;
    expect(layer, isA<ShaderMaskLayer>());
    expect((layer! as ShaderMaskLayer).blendMode, BlendMode.dstIn);
    // Content at the very top edge is fully faded, so the shadow above
    // still meets the masked band without a seam.
    expect(await _stepAtScrollTop(tester), lessThanOrEqualTo(3));

    // Back at the top the mask (and its layer) goes away again.
    position.jumpTo(0);
    await tester.pumpAndSettle();
    expect(tester.renderObject(_fade).debugLayer, isNull);
  });
}
