import '../models/meal_analysis_result.dart';
import 'open_food_facts_product_service.dart';

/// Tries [primary] (our own search index) first and falls back to
/// [fallback] (live OpenFoodFacts) on error or empty result. Keeps OFF as a
/// safety net for brand-new products (not yet in the weekly snapshot), for
/// any mirror downtime — and for barcode lookups, which the mirror
/// intentionally does not answer.
class FallbackProductService implements ProductLookupService {
  const FallbackProductService(this.primary, this.fallback);

  final ProductLookupService primary;
  final ProductLookupService fallback;

  @override
  Future<List<ProductSearchResult>> searchProducts(String query) async {
    try {
      final results = await primary.searchProducts(query);
      if (results.isNotEmpty) {
        return results;
      }
    } catch (_) {
      // fall through to OFF
    }
    return fallback.searchProducts(query);
  }

  @override
  Future<MealAnalysisResult> lookupBarcode(String barcode) async {
    try {
      return await primary.lookupBarcode(barcode);
    } catch (_) {
      return fallback.lookupBarcode(barcode);
    }
  }
}
