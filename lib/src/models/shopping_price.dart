// Value types of the shopping list's price estimate: the region, the lines
// asked about, the aggregates and each line's outcome.
// Contract: docs/SHOPPING-PRICES.md.

import 'dart:ui' show Locale;

import '../services/local_day.dart';
import 'shopping_list.dart';

/// Prices are only used from the last six weeks; the footnote derives its
/// week count from this constant.
const int kPriceWindowDays = 42;

/// Distinct (product or category, shop) prices a category estimate needs.
const int kPriceMinSamples = 3;

/// The attribution link under the receipt (ODbL asks to name the source).
const String kOpenPricesUrl = 'https://prices.openfoodfacts.org';

/// A market with community prices. Only Germany for now: prices are never
/// borrowed from another market or converted between currencies.
enum PriceRegion { germany }

extension PriceRegionConfig on PriceRegion {
  /// ISO country code the rows' shop location must carry.
  String get countryCode => switch (this) {
    PriceRegion.germany => 'DE',
  };

  String get currency => switch (this) {
    PriceRegion.germany => 'EUR',
  };

  /// Centre and radius of the server-side geo filter; the country is
  /// checked again on each row, since the circle reaches into France.
  double get lat => switch (this) {
    PriceRegion.germany => 51.1657,
  };

  double get lon => switch (this) {
    PriceRegion.germany => 10.4515,
  };

  int get radiusKm => switch (this) {
    PriceRegion.germany => 470,
  };
}

/// The price region from the device's locales: Germany when any of them
/// names DE; when none names a country, Germany for a German app language.
/// No location permission is involved.
PriceRegion? priceRegionFor(List<Locale> deviceLocales, Locale appLocale) {
  final countries = [
    for (final locale in deviceLocales)
      if (locale.countryCode case final code? when code.isNotEmpty)
        code.toUpperCase(),
  ];
  if (countries.contains('DE')) return PriceRegion.germany;
  if (countries.isEmpty && appLocale.languageCode == 'de') {
    return PriceRegion.germany;
  }
  return null;
}

/// The first day of the window that ends on [today], as `YYYY-MM-DD`:
/// 2026-10-11 gives 2026-08-30.
String priceWindowStart(DateTime today) => localDayKey(
  DateTime(today.year, today.month, today.day - kPriceWindowDays),
);

/// What a median price is per: a kilogram, a litre or a piece.
enum PriceBasis { mass, volume, piece }

/// Countable units of a recipe amount.
enum PriceUnit {
  piece,
  clove,
  slice,
  can,
  pack,

  /// A tub ("Becher"), not a measuring cup.
  tub,
  jar,
  bunch,
}

/// An amount read from a shopping line, before it meets a dictionary entry.
sealed class PriceQuantity {
  const PriceQuantity();
}

final class MassQuantity extends PriceQuantity {
  const MassQuantity(this.grams);
  final double grams;

  @override
  bool operator ==(Object other) =>
      other is MassQuantity && other.grams == grams;

  @override
  int get hashCode => grams.hashCode;

  @override
  String toString() => 'MassQuantity($grams g)';
}

final class VolumeQuantity extends PriceQuantity {
  const VolumeQuantity(this.ml);
  final double ml;

  @override
  bool operator ==(Object other) => other is VolumeQuantity && other.ml == ml;

  @override
  int get hashCode => ml.hashCode;

  @override
  String toString() => 'VolumeQuantity($ml ml)';
}

final class CountQuantity extends PriceQuantity {
  const CountQuantity(this.count, this.unit);
  final double count;
  final PriceUnit unit;

  @override
  bool operator ==(Object other) =>
      other is CountQuantity && other.count == count && other.unit == unit;

  @override
  int get hashCode => Object.hash(count, unit);

  @override
  String toString() => 'CountQuantity($count ${unit.name})';
}

final class SpoonQuantity extends PriceQuantity {
  const SpoonQuantity(this.count, {required this.tablespoon});
  final double count;
  final bool tablespoon;

  @override
  bool operator ==(Object other) =>
      other is SpoonQuantity &&
      other.count == count &&
      other.tablespoon == tablespoon;

  @override
  int get hashCode => Object.hash(count, tablespoon);

  @override
  String toString() => 'SpoonQuantity($count ${tablespoon ? 'tbsp' : 'tsp'})';
}

/// A pinch or a knife tip: never priced.
final class PinchQuantity extends PriceQuantity {
  const PinchQuantity();

  @override
  bool operator ==(Object other) => other is PinchQuantity;

  @override
  int get hashCode => 0;

  @override
  String toString() => 'PinchQuantity';
}

/// One priceable receipt row. [id] is the row's existing check id, read
/// only; a weighed item carries [grams], a free-text line its [amount].
class PriceRequestLine {
  const PriceRequestLine({
    required this.id,
    required this.label,
    this.amount,
    this.grams,
    this.productCode,
  });

  final String id, label;
  final String? amount, productCode;
  final double? grams;

  /// Everything the estimate depends on; equal keys price the same.
  String get fingerprint =>
      '$id|$label|${amount ?? ''}|${grams ?? ''}|${productCode ?? ''}';
}

/// The receipt's checkable rows as price questions: weighed items with their
/// grams and barcode, free-text lines with their amount; headings skipped.
List<PriceRequestLine> priceRequestLines(List<ShoppingItem> items) => [
  for (final item in items)
    if (item.grams != null)
      PriceRequestLine(
        id: item.id,
        label: item.name,
        grams: item.grams,
        productCode: item.productCode,
      )
    else
      for (final line in item.lines)
        if (!line.heading)
          PriceRequestLine(id: line.id, label: line.label, amount: line.amount),
];

/// A median community price.
class PriceAggregate {
  const PriceAggregate({
    required this.basis,
    required this.median,
    required this.samples,
    required this.newestDate,
    this.exactProduct = false,
  });

  final PriceBasis basis;

  /// EUR per kilogram, litre or piece.
  final double median;

  /// Independent (product or category, shop) prices behind the median,
  /// after deduplication and the outlier band.
  final int samples;

  /// Purchase date of the newest price, `YYYY-MM-DD`.
  final String newestDate;

  /// True when the prices are for the line's own barcode.
  final bool exactProduct;

  @override
  bool operator ==(Object other) =>
      other is PriceAggregate &&
      other.basis == basis &&
      other.median == median &&
      other.samples == samples &&
      other.newestDate == newestDate &&
      other.exactProduct == exactProduct;

  @override
  int get hashCode =>
      Object.hash(basis, median, samples, newestDate, exactProduct);

  @override
  String toString() =>
      'PriceAggregate(${basis.name} $median, n=$samples, $newestDate'
      '${exactProduct ? ', exact' : ''})';
}

/// How an estimate relates to the printed line.
enum LinePriceKind {
  /// The share of the printed amount.
  amount,

  /// No amount printed: one pack.
  pack,

  /// No amount printed: one piece.
  piece,
}

/// A receipt row's price outcome.
sealed class LinePrice {
  const LinePrice();
}

final class LinePriceLoading extends LinePrice {
  const LinePriceLoading();

  @override
  bool operator ==(Object other) => other is LinePriceLoading;

  @override
  int get hashCode => (LinePriceLoading).hashCode;

  @override
  String toString() => 'LinePriceLoading';
}

final class LinePriceEstimate extends LinePrice {
  const LinePriceEstimate({
    required this.cents,
    required this.aggregate,
    this.kind = LinePriceKind.amount,
  });

  /// The shown value; at least one cent.
  final int cents;
  final PriceAggregate aggregate;
  final LinePriceKind kind;

  @override
  bool operator ==(Object other) =>
      other is LinePriceEstimate &&
      other.cents == cents &&
      other.aggregate == aggregate &&
      other.kind == kind;

  @override
  int get hashCode => Object.hash(cents, aggregate, kind);

  @override
  String toString() => 'LinePriceEstimate($cents ct, ${kind.name}, $aggregate)';
}

/// No dictionary match, too few recent prices, or an amount that cannot be
/// converted.
final class LinePriceNoData extends LinePrice {
  const LinePriceNoData();

  @override
  bool operator ==(Object other) => other is LinePriceNoData;

  @override
  int get hashCode => (LinePriceNoData).hashCode;

  @override
  String toString() => 'LinePriceNoData';
}

/// The lookup failed (network, budget, unexpected answer); retried later.
final class LinePriceUnavailable extends LinePrice {
  const LinePriceUnavailable();

  @override
  bool operator ==(Object other) => other is LinePriceUnavailable;

  @override
  int get hashCode => (LinePriceUnavailable).hashCode;

  @override
  String toString() => 'LinePriceUnavailable';
}

/// Salt, pepper, water, a pinch: deliberately not estimated.
final class LinePriceSkipped extends LinePrice {
  const LinePriceSkipped();

  @override
  bool operator ==(Object other) => other is LinePriceSkipped;

  @override
  int get hashCode => (LinePriceSkipped).hashCode;

  @override
  String toString() => 'LinePriceSkipped';
}

/// The receipt's sum over its shown values.
class ShoppingPriceTotal {
  const ShoppingPriceTotal({
    required this.cents,
    required this.priced,
    required this.unpriced,
    required this.pending,
    required this.failed,
    this.skipped = 0,
  });

  final int cents, priced, unpriced, pending;
  final bool failed;

  /// Seasoning, deliberately without a price.
  final int skipped;

  /// Every line that should carry a price does.
  bool get complete => unpriced == 0 && pending == 0;

  /// Every line is seasoning: nothing to add up.
  bool get nothingToPrice =>
      priced == 0 && unpriced == 0 && pending == 0 && skipped > 0;

  /// The receipt's price lines.
  int get lines => priced + unpriced + pending + skipped;
}

/// Sums the displayed cents, so the total always equals the shown values.
/// Skipped lines are neither priced nor missing.
ShoppingPriceTotal shoppingPriceTotal(Iterable<LinePrice> prices) {
  var cents = 0, priced = 0, unpriced = 0, pending = 0, skipped = 0;
  var failed = false;
  for (final price in prices) {
    switch (price) {
      case LinePriceEstimate(cents: final value):
        cents += value;
        priced++;
      case LinePriceLoading():
        pending++;
      case LinePriceUnavailable():
        unpriced++;
        failed = true;
      case LinePriceNoData():
        unpriced++;
      case LinePriceSkipped():
        skipped++;
    }
  }
  return ShoppingPriceTotal(
    cents: cents,
    priced: priced,
    unpriced: unpriced,
    pending: pending,
    failed: failed,
    skipped: skipped,
  );
}
