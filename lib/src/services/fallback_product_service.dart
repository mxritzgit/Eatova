import 'dart:async';
import 'dart:io';

import '../models/meal_analysis_result.dart';
import 'crash_reporter.dart';
import 'eatova_http.dart';
import 'open_food_facts_product_service.dart';

/// Tries [primary] (our own search index) first, falling back to live
/// OpenFoodFacts on error or empty result. OFF stays the safety net for
/// brand-new products, mirror downtime, and barcodes, which the mirror does
/// not answer.
///
/// Beyond switching (Review 2026-08-08): the energy filter (B7) runs here
/// because this is where both sources meet, and errors are classified rather
/// than swallowed (G2), so an OFF format change cannot hide behind the
/// fallback.
class FallbackProductService implements ProductLookupService {
  const FallbackProductService(
    this.primary,
    this.fallback, {
    this.searchChainBudget = defaultSearchChainBudget,
  });

  /// Ceiling over BOTH legs (review P10-02). Mirror (12 s) and OpenFoodFacts
  /// (24 s) each cap themselves, but they run one after the other, so their
  /// sum — 36 s — is what a caller would wait. 30 s is the ceiling on one
  /// full attempt; the caller's own retry cycle caps the attempts.
  static const Duration defaultSearchChainBudget = Duration(seconds: 30);

  final ProductLookupService primary;
  final ProductLookupService fallback;

  /// Test seam plus tuning knob for [defaultSearchChainBudget].
  final Duration searchChainBudget;

  @override
  Future<List<ProductSearchResult>> searchProducts(String query) {
    // One ceiling over primary + fallback. No client of its own to close, so
    // this only stops the WAIT; each leg cuts its own socket on its own
    // budget.
    final deadline = ChainDeadline(
      searchChainBudget,
      operation: 'product.search.chain',
    );
    return deadline
        .guard(_searchProducts(query))
        .whenComplete(deadline.dispose);
  }

  Future<List<ProductSearchResult>> _searchProducts(String query) async {
    try {
      final results = _nurLoggbare(await primary.searchProducts(query));
      if (results.isNotEmpty) {
        return results;
      }
    } catch (error, stack) {
      _meldeWennUnerwartet(error, stack, 'product.search.primary');
      // fall through to OFF
    }
    try {
      return _nurLoggbare(await fallback.searchProducts(query));
    } catch (error, stack) {
      _meldeWennUnerwartet(error, stack, 'product.search.fallback');
      // No leg left: the caller has to see the error.
      rethrow;
    }
  }

  @override
  Future<MealAnalysisResult> lookupBarcode(String barcode) async {
    try {
      final treffer = await primary.lookupBarcode(barcode);
      // A hit without usable energy is no hit: live OFF often knows
      // nutrition the mirror lacks, and only if it does not does it throw
      // ProductWithoutNutritionException, which carries the product name.
      if (isLoggableKcalPer100G(treffer.kcalPer100G) ||
          treffer.explicitZeroKcal) {
        return treffer;
      }
    } catch (error, stack) {
      _meldeWennUnerwartet(error, stack, 'product.barcode.primary');
    }
    try {
      return await fallback.lookupBarcode(barcode);
    } catch (error, stack) {
      // Not-found and no-nutrition are the normal case here, hence expected.
      _meldeWennUnerwartet(error, stack, 'product.barcode.fallback');
      rethrow;
    }
  }

  /// Loggable = usable energy OR a measured 0 (water, zero drinks), which
  /// only the raw OFF fields report; mirror hits never set that marker.
  List<ProductSearchResult> _nurLoggbare(List<ProductSearchResult> treffer) {
    bool loggbar(ProductSearchResult t) =>
        isLoggableKcalPer100G(t.kcalPer100G) || t.result.explicitZeroKcal;
    if (treffer.every(loggbar)) {
      return treffer;
    }
    return treffer.where(loggbar).toList(growable: false);
  }
}

/// Errors expected on the way to the fallback, which may stay silent: a
/// network error is noise, while a parse error means "the API changed under
/// us", which the fallback would otherwise hide (G2). [UnsupportedError] is
/// listed because the mirror throws it on every barcode scan.
bool _istErwartet(Object error) =>
    error is IOException || // SocketException, HttpException, TLS, …
    error is TimeoutException ||
    error is UnsupportedError ||
    error is ProductNotFoundException ||
    error is ProductWithoutNutritionException;

void _meldeWennUnerwartet(Object error, StackTrace stack, String context) {
  if (_istErwartet(error)) {
    return;
  }
  // capture() never throws and sanitizes itself (C1).
  unawaited(CrashReporter.capture(error, stack, context: context));
}
