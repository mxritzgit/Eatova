import 'package:flutter_test/flutter_test.dart';
import 'package:shiftfit/src/models/meal_analysis_result.dart';
import 'package:shiftfit/src/services/fallback_product_service.dart';
import 'package:shiftfit/src/services/open_food_facts_product_service.dart';

class _FakeService implements ProductLookupService {
  _FakeService({
    this.searchResults = const <ProductSearchResult>[],
    this.searchThrows = false,
    this.barcodeResult,
    this.barcodeThrows = false,
  });

  final List<ProductSearchResult> searchResults;
  final bool searchThrows;
  final MealAnalysisResult? barcodeResult;
  final bool barcodeThrows;
  int searchCalls = 0;
  int barcodeCalls = 0;

  @override
  Future<List<ProductSearchResult>> searchProducts(String query) async {
    searchCalls++;
    if (searchThrows) {
      throw Exception('boom');
    }
    return searchResults;
  }

  @override
  Future<MealAnalysisResult> lookupBarcode(String barcode) async {
    barcodeCalls++;
    if (barcodeThrows) {
      throw Exception('boom');
    }
    return barcodeResult!;
  }
}

MealAnalysisResult _meal(String name) => MealAnalysisResult(
      mealName: name,
      caloriesKcal: 100,
      estimatedGrams: 100,
      kcalPer100G: 100,
      protein: '1 g',
      carbs: '1 g',
      fat: '1 g',
      confidence: 'Datenbank',
      portionNotes: '',
    );

ProductSearchResult _hit(String title) => ProductSearchResult(
      code: '1',
      title: title,
      subtitle: '',
      kcalPer100G: 100,
      result: _meal(title),
    );

void main() {
  test('search: primary results are used, fallback not called', () async {
    final primary = _FakeService(searchResults: [_hit('Mirror')]);
    final fallback = _FakeService(searchResults: [_hit('OFF')]);
    final svc = FallbackProductService(primary, fallback);

    final r = await svc.searchProducts('milch');

    expect(r.single.title, 'Mirror');
    expect(fallback.searchCalls, 0);
  });

  test('search: primary throws -> fallback used', () async {
    final primary = _FakeService(searchThrows: true);
    final fallback = _FakeService(searchResults: [_hit('OFF')]);
    final svc = FallbackProductService(primary, fallback);

    final r = await svc.searchProducts('milch');

    expect(r.single.title, 'OFF');
    expect(fallback.searchCalls, 1);
  });

  test('search: primary empty -> fallback used', () async {
    final primary = _FakeService(searchResults: const <ProductSearchResult>[]);
    final fallback = _FakeService(searchResults: [_hit('OFF')]);
    final svc = FallbackProductService(primary, fallback);

    final r = await svc.searchProducts('milch');

    expect(r.single.title, 'OFF');
    expect(fallback.searchCalls, 1);
  });

  test('barcode: primary not found -> fallback used', () async {
    final primary = _FakeService(barcodeThrows: true);
    final fallback = _FakeService(barcodeResult: _meal('OFF product'));
    final svc = FallbackProductService(primary, fallback);

    final r = await svc.lookupBarcode('123');

    expect(r.mealName, 'OFF product');
    expect(fallback.barcodeCalls, 1);
  });

  test('barcode: primary success -> fallback not called', () async {
    final primary = _FakeService(barcodeResult: _meal('Mirror product'));
    final fallback = _FakeService(barcodeResult: _meal('OFF product'));
    final svc = FallbackProductService(primary, fallback);

    final r = await svc.lookupBarcode('123');

    expect(r.mealName, 'Mirror product');
    expect(fallback.barcodeCalls, 0);
  });
}
