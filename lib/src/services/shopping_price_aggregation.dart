// Pure aggregation of Open Prices rows into one median per dictionary entry,
// and the cost of a receipt line from it. No IO; fixtures drive the tests.
// Contract: docs/SHOPPING-PRICES.md.

import '../models/shopping_price.dart';
import '../models/shopping_price_amount.dart';
import '../models/shopping_price_dictionary.dart';
import 'local_day.dart';
import 'open_prices_api.dart';

/// One normalised price: EUR per kilogram, litre or piece.
class PriceObservation {
  const PriceObservation({
    required this.value,
    required this.distinctKey,
    required this.dedupKey,
    required this.date,
  });

  final double value;

  /// Product or category tag plus shop: what counts as an independent price.
  final String distinctKey;

  /// [distinctKey] plus date and price: one purchase reported twice.
  final String dedupKey;
  final String date;
}

/// The regular price of [row] when it passes every client-side filter:
/// a shop in the region, its currency, the window up to [today], not a
/// duplicate, and a plausible amount. The server's filters are not trusted
/// alone, because it drops unknown parameters without an error.
double? _regularPrice(OpenPriceRow row, PriceRegion region, DateTime today) {
  if (row.locationType != 'OSM' || row.countryCode != region.countryCode) {
    return null;
  }
  if (row.currency != region.currency || row.duplicateOf != null) return null;
  final date = row.date;
  if (date == null ||
      date.compareTo(priceWindowStart(today)) < 0 ||
      date.compareTo(localDayKey(today)) > 0) {
    return null;
  }
  var price = row.price;
  if (row.isDiscounted) {
    // A discount says little about next week's price; without the regular
    // price the row is dropped.
    final regular = row.priceWithoutDiscount;
    if (regular == null || regular <= price) return null;
    price = regular;
  }
  if (!(price > 0.05 && price <= 500)) return null;
  return price;
}

/// The observations [entry] takes from [rows].
List<PriceObservation> priceObservations(
  PriceEntry entry,
  Iterable<OpenPriceRow> rows, {
  required PriceRegion region,
  required DateTime today,
}) {
  final observations = <PriceObservation>[];
  for (final row in rows) {
    final price = _regularPrice(row, region, today);
    if (price == null) continue;
    final double? value;
    final String key;
    switch (row.type) {
      case OpenPriceType.product:
        if (!_productMatches(entry, row.categoriesTags)) continue;
        value = _productValue(entry, row, price);
        key = 'code:${row.productCode ?? 'row-${row.id}'}';
      case OpenPriceType.category:
        if (!entry.categoryPrices ||
            !entry.categoryTags.contains(row.categoryTag)) {
          continue;
        }
        // Never mix bases: per kilogram for mass, per piece for pieces.
        value = switch (entry.basis) {
          PriceBasis.mass => row.pricePer == 'KILOGRAM' ? price : null,
          PriceBasis.piece => row.pricePer == 'UNIT' ? price : null,
          PriceBasis.volume => null,
        };
        key = 'tag:${row.categoryTag}';
    }
    if (value == null || !value.isFinite || value <= 0) continue;
    final distinct = '$key|${row.locationId}';
    observations.add(
      PriceObservation(
        value: value,
        distinctKey: distinct,
        dedupKey: '$distinct|${row.date}|$price',
        date: row.date!,
      ),
    );
  }
  return observations;
}

bool _productMatches(PriceEntry entry, List<String> tags) =>
    entry.productTags.any(tags.contains) &&
    entry.requireTags.every(tags.contains) &&
    !entry.excludeTags.any(tags.contains);

double? _productValue(PriceEntry entry, OpenPriceRow row, double price) {
  if (entry.basis == PriceBasis.piece) {
    final count = parsePieceCount(row.productQuantityText);
    return count == null ? null : price / count;
  }
  final quantity = row.productQuantity;
  if (quantity == null || quantity <= 0) return null;
  final amount = switch ((entry.basis, row.productQuantityUnit)) {
    (PriceBasis.mass, 'g') => quantity,
    (PriceBasis.mass, 'ml') => quantity * entry.density,
    (PriceBasis.volume, 'ml') => quantity,
    (PriceBasis.volume, 'g') => quantity / entry.density,
    _ => null,
  };
  return amount == null ? null : price / amount * 1000;
}

/// The piece count in a pack's printed size: "10 Stück", "10er", "6 x
/// 50 g", "10 pcs", "M 10" or a bare "10".
int? parsePieceCount(String? text) {
  if (text == null) return null;
  final value = text.trim().toLowerCase();
  final match =
      RegExp(
        r'(\d+)\s*(?:stück|stueck|stk|pcs|pc|pieces?|eier|er)\b',
        unicode: true,
      ).firstMatch(value) ??
      RegExp(r'(\d+)\s*[x×]').firstMatch(value) ??
      RegExp(r'^(?:xl|[sml])\s*(\d+)$').firstMatch(value) ??
      RegExp(r'^(\d+)$').firstMatch(value);
  final count = match == null ? null : int.tryParse(match[1]!);
  return count != null && count > 0 && count <= 100 ? count : null;
}

/// The median over independent prices: duplicates dropped, each (product
/// or tag, shop) counted once at its own median, then values outside a 3x
/// band around the first median dropped. Null with fewer than [minSamples]
/// such prices left.
PriceAggregate? aggregatePriceObservations(
  List<PriceObservation> observations, {
  required PriceBasis basis,
  int minSamples = kPriceMinSamples,
  bool exactProduct = false,
}) {
  final unique = <String, PriceObservation>{};
  for (final observation in observations) {
    unique.putIfAbsent(observation.dedupKey, () => observation);
  }
  if (unique.isEmpty) return null;
  // A shop reporting the same product again does not weigh twice.
  final bySource = <String, List<PriceObservation>>{};
  for (final observation in unique.values) {
    (bySource[observation.distinctKey] ??= []).add(observation);
  }
  final sources = [
    for (final reports in bySource.values)
      (
        value: _median(reports.map((o) => o.value)),
        date: reports.map((o) => o.date).reduce(_later),
      ),
  ];
  final first = _median(sources.map((s) => s.value));
  final kept = [
    for (final s in sources)
      if (s.value >= first / 3 && s.value <= first * 3) s,
  ];
  if (kept.length < minSamples) return null;
  return PriceAggregate(
    basis: basis,
    median: _median(kept.map((s) => s.value)),
    samples: kept.length,
    newestDate: kept.map((s) => s.date).reduce(_later),
    exactProduct: exactProduct,
  );
}

String _later(String a, String b) => a.compareTo(b) >= 0 ? a : b;

double _median(Iterable<double> values) {
  final sorted = values.toList()..sort();
  final middle = sorted.length ~/ 2;
  return sorted.length.isOdd
      ? sorted[middle]
      : (sorted[middle - 1] + sorted[middle]) / 2;
}

/// The aggregate for one exact barcode: its own prices per kilogram or
/// litre; one price is enough. Null without a usable pack size.
PriceAggregate? exactProductAggregate(
  String code,
  Iterable<OpenPriceRow> rows, {
  required PriceRegion region,
  required DateTime today,
}) {
  String? unit;
  final observations = <PriceObservation>[];
  for (final row in rows) {
    if (row.type != OpenPriceType.product || row.productCode != code) continue;
    final price = _regularPrice(row, region, today);
    final quantity = row.productQuantity;
    final rowUnit = row.productQuantityUnit;
    if (price == null || quantity == null || quantity <= 0) continue;
    if (rowUnit != 'g' && rowUnit != 'ml') continue;
    unit ??= rowUnit;
    if (rowUnit != unit) continue;
    final distinct = 'code:$code|${row.locationId}';
    observations.add(
      PriceObservation(
        value: price / quantity * 1000,
        distinctKey: distinct,
        dedupKey: '$distinct|${row.date}|$price',
        date: row.date!,
      ),
    );
  }
  if (unit == null) return null;
  return aggregatePriceObservations(
    observations,
    basis: unit == 'g' ? PriceBasis.mass : PriceBasis.volume,
    minSamples: 1,
    exactProduct: true,
  );
}

/// The line's quantity: grams for a weighed item, else its printed amount.
PriceQuantity? lineQuantity(PriceRequestLine line) {
  final grams = line.grams;
  if (grams != null) return MassQuantity(grams);
  return parsePriceQuantity(line.amount);
}

/// Whether [line] can be priced with [entry] once an aggregate exists, so a
/// line that never can is settled without a request.
bool linePriceable(
  PriceRequestLine line,
  PriceEntry entry, {
  PriceUnit? impliedUnit,
}) {
  final quantity = lineQuantity(line);
  if (quantity == null) {
    if (line.amount != null) return false;
    return entry.basis == PriceBasis.piece ||
        entry.units[PriceUnit.pack] != null;
  }
  return _measure(entry.basis, entry, impliedUnit, quantity) != null;
}

/// The price of [line] from [aggregate]: the share of its amount, or one
/// pack or piece when no amount is printed.
LinePrice priceLine(
  PriceRequestLine line,
  PriceAggregate? aggregate, {
  PriceEntry? entry,
  PriceUnit? impliedUnit,
}) {
  if (aggregate == null) return const LinePriceNoData();
  final quantity = lineQuantity(line);
  final double measure;
  final LinePriceKind kind;
  if (quantity == null) {
    if (line.amount != null) return const LinePriceNoData();
    if (aggregate.basis == PriceBasis.piece) {
      (measure, kind) = (1, LinePriceKind.piece);
    } else {
      final pack = entry?.units[PriceUnit.pack];
      if (pack == null) return const LinePriceNoData();
      (measure, kind) = (pack / 1000, LinePriceKind.pack);
    }
  } else {
    final value = _measure(aggregate.basis, entry, impliedUnit, quantity);
    if (value == null || !value.isFinite || value <= 0) {
      return const LinePriceNoData();
    }
    (measure, kind) = (value, LinePriceKind.amount);
  }
  final cents = (aggregate.median * measure * 100).round();
  return LinePriceEstimate(
    cents: cents < 1 ? 1 : cents,
    aggregate: aggregate,
    kind: kind,
  );
}

/// [quantity] in the basis: kilograms, litres or pieces.
double? _measure(
  PriceBasis basis,
  PriceEntry? entry,
  PriceUnit? impliedUnit,
  PriceQuantity quantity,
) {
  final density = entry?.density ?? 1.0;
  final units = entry?.units ?? const <PriceUnit, double>{};
  PriceUnit unitOf(PriceUnit unit) =>
      unit == PriceUnit.piece && impliedUnit != null ? impliedUnit : unit;
  switch (basis) {
    case PriceBasis.mass:
      final grams = switch (quantity) {
        MassQuantity(:final grams) => grams,
        VolumeQuantity(:final ml) => ml * density,
        CountQuantity(:final count, :final unit) => switch (units[unitOf(
          unit,
        )]) {
          final each? => count * each,
          null => null,
        },
        SpoonQuantity(:final count, :final tablespoon) =>
          count *
              (tablespoon
                  ? entry?.tbspGrams ?? 15 * density
                  : entry?.tspGrams ?? 5 * density),
        PinchQuantity() => null,
      };
      return grams == null ? null : grams / 1000;
    case PriceBasis.volume:
      final ml = switch (quantity) {
        VolumeQuantity(:final ml) => ml,
        MassQuantity(:final grams) => grams / density,
        CountQuantity(:final count, :final unit) => switch (units[unitOf(
          unit,
        )]) {
          final each? => count * each,
          null => null,
        },
        SpoonQuantity(:final count, :final tablespoon) =>
          count * (tablespoon ? 15 : 5),
        PinchQuantity() => null,
      };
      return ml == null ? null : ml / 1000;
    case PriceBasis.piece:
      final piece = units[PriceUnit.piece];
      return switch (quantity) {
        CountQuantity(:final count, :final unit)
            when unitOf(unit) == PriceUnit.piece =>
          count,
        CountQuantity(:final count, :final unit) => switch ((
          units[unitOf(unit)],
          piece,
        )) {
          (final each?, final per?) => count * each / per,
          _ => null,
        },
        MassQuantity(:final grams) => piece == null ? null : grams / piece,
        VolumeQuantity(:final ml) =>
          piece == null ? null : ml * density / piece,
        SpoonQuantity() || PinchQuantity() => null,
      };
  }
}
