import 'dart:async';
import 'dart:io';

import '../models/meal_analysis_result.dart';
import 'crash_reporter.dart';
import 'open_food_facts_product_service.dart';

/// Tries [primary] (our own search index) first and falls back to
/// [fallback] (live OpenFoodFacts) on error or empty result. Keeps OFF as a
/// safety net for brand-new products (not yet in the weekly snapshot), for
/// any mirror downtime — and for barcode lookups, which the mirror
/// intentionally does not answer.
///
/// Zwei Dinge passieren hier zusaetzlich zum Umschalten, beide aus
/// docs/REVIEW-2026-08-08.md:
///
///  * **B7 — der Energie-Filter fuer den Mirror-Pfad.**
///    `MeilisearchProductService` filtert seine Hits nur auf einen nicht
///    leeren Titel; die 0-kcal- und die 900er-Pruefung stehen im
///    OFF-Service. Hier laufen beide Quellen zusammen, also steht die
///    Gegenpruefung hier — [isLoggableKcalPer100G] auf jedem Treffer, egal
///    woher er kommt.
///  * **G2 — Fehler werden klassifiziert statt pauschal geschluckt.** Das
///    frühere `catch (_) {}` verschluckte auch einen Parse-Fehler, und genau
///    das machte die Ein-Token-Abschaltung des Barcode-Scans unsichtbar.
class FallbackProductService implements ProductLookupService {
  const FallbackProductService(this.primary, this.fallback);

  final ProductLookupService primary;
  final ProductLookupService fallback;

  @override
  Future<List<ProductSearchResult>> searchProducts(String query) async {
    try {
      final results = _nurLoggbare(await primary.searchProducts(query));
      if (results.isNotEmpty) {
        return results;
      }
    } catch (error, stack) {
      _meldeWennUnerwartet(error, stack, 'product.search.primary');
      // fall through to OFF
    }
    return _nurLoggbare(await fallback.searchProducts(query));
  }

  @override
  Future<MealAnalysisResult> lookupBarcode(String barcode) async {
    try {
      final treffer = await primary.lookupBarcode(barcode);
      // Ein Treffer ohne verwertbare Energie ist kein Treffer: fuer denselben
      // Barcode kennt die OFF-Live-API oft Naehrwerte, die der Spiegel nicht
      // hat. Erst wenn auch die nichts liefert, wirft der OFF-Service seine
      // ProductWithoutNutritionException — und die traegt den Produktnamen,
      // damit die Oberflaeche "gefunden, aber ohne Naehrwerte" sagen kann
      // statt "nicht gefunden".
      if (isLoggableKcalPer100G(treffer.kcalPer100G)) {
        return treffer;
      }
    } catch (error, stack) {
      _meldeWennUnerwartet(error, stack, 'product.barcode.primary');
    }
    return fallback.lookupBarcode(barcode);
  }

  List<ProductSearchResult> _nurLoggbare(List<ProductSearchResult> treffer) {
    if (treffer.every((t) => isLoggableKcalPer100G(t.kcalPer100G))) {
      return treffer;
    }
    return treffer
        .where((t) => isLoggableKcalPer100G(t.kcalPer100G))
        .toList(growable: false);
  }
}

/// Fehler, die auf dem Weg zum Fallback **erwartet** sind und deshalb still
/// bleiben duerfen.
///
/// Die Trennlinie: Ein Netzfehler heisst "die Gegenstelle ist gerade nicht
/// da" — Alltag, der Fallback ist genau dafuer gebaut, und Melden wuerde bei
/// jedem U-Bahn-Tunnel Rauschen erzeugen. Ein **Parse**-Fehler heisst dagegen
/// "wir verstehen die API nicht mehr" — eine Formataenderung bei OFF, die
/// sonst niemandem auffiele, weil der Fallback sie zudeckt. Genau diese
/// Blindheit beschreibt G2.
///
/// [UnsupportedError] steht auf der Liste, weil
/// `MeilisearchProductService.lookupBarcode` ihn per Konstruktion bei JEDEM
/// Barcode-Scan wirft (der Mirror beantwortet keine Barcodes) — das ist der
/// Normalbetrieb, kein Vorfall.
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
  // capture() wirft nie und sanitisiert selbst (C1) — hier landet also
  // niemals ein roher Response-Body in einem Report.
  unawaited(CrashReporter.capture(error, stack, context: context));
}
