import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_request.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/services/meal_analyzer.dart';
import 'package:eatova/src/services/meal_photo_input.dart';
import 'package:eatova/src/services/open_food_facts_product_service.dart';
import 'package:eatova/src/widgets/kcal/add_meal_sheet.dart';

import 'support/harness.dart';

class _Analyzer implements MealAnalyzer {
  @override
  Future<MealAnalysisResult> analyze(MealAnalysisRequest request) async =>
      throw UnimplementedError();
}

class _PhotoInput implements MealPhotoInput {
  @override
  Future<MealPhotoSelection?> pick(ImageSource source) async => null;
}

class _Search implements ProductLookupService {
  final pending = Completer<List<ProductSearchResult>>();

  @override
  Future<MealAnalysisResult> lookupBarcode(String barcode) async =>
      throw UnimplementedError();

  @override
  Future<List<ProductSearchResult>> searchProducts(String query) async {
    if (query == 'Apfel') {
      return [
        ProductSearchResult.fromOpenFoodFacts(const {
          'code': '4000000000001',
          'product_name': 'Apfel',
          'nutriments': {'energy-kcal_100g': 52},
        }),
      ];
    }
    return pending.future;
  }
}

final _input = find.byKey(const ValueKey('kcal-product-search-input'));
final _hit = find.byKey(const ValueKey('kcal-product-suggestion-0'));

Future<void> _firstSearch(WidgetTester tester, _Search service) async {
  pinPhoneViewport(tester);
  await pumpLocalized(
    tester,
    AddMealSheet(
      slot: MealSlot.snack,
      analyzer: _Analyzer(),
      productService: service,
      photoInput: _PhotoInput(),
      favorites: const [],
      onAdd: (_, __) => 'logged-meal',
      onUpdateMeal: (_, __) {},
      onRemoveFavorite: (_) {},
    ),
    reducedMotion: false,
    safeArea: false,
    settle: true,
  );
  await tester.enterText(_input, 'Apfel');
  await tester.pump(const Duration(milliseconds: 1100));
  await tester.pumpAndSettle();
  expect(_hit, findsOneWidget);
}

void main() {
  testWidgets('new query immediately removes unrelated actionable hits', (
    tester,
  ) async {
    final service = _Search();
    await _firstSearch(tester, service);
    await tester.enterText(_input, 'Brot');
    await tester.pump();

    expect(_hit, findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('second search keeps slow help and timeout recovery visible', (
    tester,
  ) async {
    final service = _Search();
    await _firstSearch(tester, service);
    await tester.enterText(_input, 'Brot');
    await tester.pump(const Duration(milliseconds: 1100));
    await tester.pump(const Duration(seconds: 7));

    expect(find.byKey(const ValueKey('product-search-cancel')), findsOneWidget);
    expect(_hit, findsNothing);
    await tester.pump(const Duration(seconds: 12));
    expect(find.text(deL10n.foodSearchTimeoutHint), findsOneWidget);
    expect(find.byKey(const ValueKey('manual-entry-cta')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('second search rate limit cannot hide behind previous hits', (
    tester,
  ) async {
    final service = _Search();
    await _firstSearch(tester, service);
    await tester.enterText(_input, 'Brot');
    await tester.pump(const Duration(milliseconds: 1100));
    service.pending.completeError(const HttpException('HTTP 429'));
    await tester.pumpAndSettle();

    expect(find.text(deL10n.searchRateLimited), findsOneWidget);
    expect(_hit, findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
