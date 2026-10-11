// The aggregation rules of the price estimate (docs/SHOPPING-PRICES.md) on
// in-memory rows shaped like Open Prices answers: the six-week window,
// every filter the server is supposed to apply, discounts, normalisation per
// kilogram, litre and piece, the sample rule, the outlier band, and the
// cost of a line. "Today" is 2026-10-11 throughout.

import 'dart:ui' show Locale;

import 'package:eatova/src/models/shopping_list.dart';
import 'package:eatova/src/models/shopping_price.dart';
import 'package:eatova/src/models/shopping_price_dictionary.dart';
import 'package:eatova/src/services/open_prices_api.dart';
import 'package:eatova/src/services/shopping_price_aggregation.dart';
import 'package:flutter_test/flutter_test.dart';

final _today = DateTime(2026, 10, 11);
const _region = PriceRegion.germany;

var _nextId = 1;

/// A product price row; [quantity] and [unit] describe the pack.
OpenPriceRow _product({
  required double price,
  String code = '4000000000001',
  int location = 1,
  String date = '2026-10-01',
  List<String> tags = const ['en:butters'],
  double? quantity = 250,
  String? unit = 'g',
  String? quantityText,
  String country = 'DE',
  String currency = 'EUR',
  String locationType = 'OSM',
  bool discounted = false,
  double? regular,
  int? duplicateOf,
}) => OpenPriceRow.tryParse({
  'id': _nextId++,
  'type': 'PRODUCT',
  'product_code': code,
  'category_tag': null,
  'price': price,
  'price_is_discounted': discounted,
  'price_without_discount': regular,
  'price_per': null,
  'currency': currency,
  'date': date,
  'location_id': location,
  'duplicate_of': duplicateOf,
  'product': {
    'code': code,
    'product_quantity': quantity,
    'product_quantity_unit': unit,
    'quantity': quantityText,
    'categories_tags': tags,
  },
  'location': {
    'id': location,
    'type': locationType,
    'osm_address_country_code': country,
  },
})!;

/// A loose-goods price per [per] (`KILOGRAM` or `UNIT`).
OpenPriceRow _category({
  required String tag,
  required double price,
  required String per,
  int location = 1,
  String date = '2026-10-01',
}) => OpenPriceRow.tryParse({
  'id': _nextId++,
  'type': 'CATEGORY',
  'product_code': null,
  'category_tag': tag,
  'price': price,
  'price_is_discounted': false,
  'price_without_discount': null,
  'price_per': per,
  'currency': 'EUR',
  'date': date,
  'location_id': location,
  'duplicate_of': null,
  'product': null,
  'location': {'id': location, 'type': 'OSM', 'osm_address_country_code': 'DE'},
})!;

PriceEntry _entry(String id) => kPriceEntries[id]!;

PriceAggregate? _aggregate(String id, List<OpenPriceRow> rows) =>
    aggregatePriceObservations(
      priceObservations(_entry(id), rows, region: _region, today: _today),
      basis: _entry(id).basis,
    );

/// Butter at [eurPerKg] in its own shop, as a 250 g pack.
OpenPriceRow _butter(
  double eurPerKg, {
  required int shop,
  String date = '2026-10-01',
}) => _product(price: eurPerKg / 4, location: shop, date: date);

void main() {
  test('only the last 42 days count: day 42 is in, day 43 and the future '
      'are out', () {
    expect(priceWindowStart(_today), '2026-08-30');
    final recent = [
      _butter(4.0, shop: 1),
      _butter(4.4, shop: 2),
      _butter(4.8, shop: 3),
      // Exactly 42 days back: still in.
      _butter(5.2, shop: 4, date: '2026-08-30'),
    ];
    final stale = [
      // 43 days back and a purchase "tomorrow": out, both far above.
      _butter(12, shop: 5, date: '2026-08-29'),
      _butter(12, shop: 6, date: '2026-07-01'),
      _butter(12, shop: 7, date: '2026-10-12'),
    ];
    final aggregate = _aggregate('butter', [...recent, ...stale])!;
    // With the stale rows the median would be (5.2 + 12) / 2 = 8.6.
    expect(aggregate.median, closeTo(4.6, 1e-9));
    expect(aggregate.samples, 4);
    expect(aggregate.newestDate, '2026-10-01');
    // Old prices alone never make an estimate.
    expect(_aggregate('butter', stale), isNull);
  });

  test('rows the server should have filtered are dropped on the client', () {
    final good = [
      _butter(4.0, shop: 1),
      _butter(4.4, shop: 2),
      _butter(4.8, shop: 3),
    ];
    final bad = [
      _product(price: 3, location: 4, country: 'FR'),
      _product(price: 3, location: 5, currency: 'USD'),
      _product(price: 3, location: 6, duplicateOf: 99),
      _product(price: 3, location: 7, locationType: 'ONLINE'),
      // Implausible amounts.
      _product(price: .05, location: 8),
      _product(price: 600, location: 9),
      // Another category, and an excluded one.
      _product(price: 3, location: 10, tags: const ['en:margarines']),
    ];
    final aggregate = _aggregate('butter', [...good, ...bad])!;
    expect(aggregate.median, closeTo(4.4, 1e-9));
    expect(aggregate.samples, 3);
    final cucumbers = [
      for (var shop = 1; shop <= 3; shop++)
        _product(
          price: .79,
          location: shop,
          quantity: null,
          unit: null,
          quantityText: '1 Stück',
          tags: const ['en:cucumbers'],
        ),
      _product(
        price: 3.99,
        location: 4,
        quantity: null,
        unit: null,
        quantityText: '1 Stück',
        tags: const ['en:cucumbers', 'en:pickled-cucumbers'],
      ),
    ];
    expect(_aggregate('cucumber', cucumbers)!.median, closeTo(.79, 1e-9));
  });

  test('a discount counts at its regular price, or not at all', () {
    final rows = [
      _butter(4.0, shop: 1),
      _butter(4.4, shop: 2),
      // 0.89 instead of 1.19: the regular 4.76 counts.
      _product(price: .89, location: 3, discounted: true, regular: 1.19),
      // Without the regular price, or with a "regular" price below it: out.
      _product(price: .2, location: 4, discounted: true),
      _product(price: .9, location: 5, discounted: true, regular: .8),
    ];
    final aggregate = _aggregate('butter', rows)!;
    expect(aggregate.samples, 3);
    expect(aggregate.median, closeTo(4.4, 1e-9));
    expect(
      priceObservations(
        _entry('butter'),
        [rows[2]],
        region: _region,
        today: _today,
      ).single.value,
      closeTo(4.76, 1e-9),
    );
  });

  test('normalisation per kilogram, litre and piece never mixes bases', () {
    // Milk per litre; a pack labelled in grams goes through the density.
    final milk = [
      _product(
        price: .99,
        location: 1,
        quantity: 1000,
        unit: 'ml',
        tags: const ['en:milks'],
      ),
      _product(
        price: 1.03,
        location: 2,
        quantity: 1030,
        unit: 'g',
        tags: const ['en:milks'],
      ),
      _product(
        price: 1.2,
        location: 3,
        quantity: 1000,
        unit: 'ml',
        tags: const ['en:milks'],
      ),
      // No pack size: cannot be normalised.
      _product(
        price: .5,
        location: 4,
        quantity: null,
        unit: null,
        tags: const ['en:milks'],
      ),
    ];
    final perLitre = _aggregate('milk', milk)!;
    expect(perLitre.basis, PriceBasis.volume);
    expect(perLitre.samples, 3);
    // 1030 g of milk are 1 l: 1.03 EUR per litre, the median of the three.
    expect(perLitre.median, closeTo(1.03, 1e-9));
    expect(
      priceObservations(
        _entry('milk'),
        milk,
        region: _region,
        today: _today,
      ).map((o) => o.value),
      [closeTo(.99, 1e-9), closeTo(1.03, 1e-9), closeTo(1.2, 1e-9)],
    );

    // Bananas per kilogram: category prices per piece do not count.
    final bananas = [
      _category(tag: 'en:bananas', price: 1.29, per: 'KILOGRAM', location: 1),
      _category(tag: 'en:bananas', price: 1.99, per: 'KILOGRAM', location: 2),
      _category(tag: 'en:bananas', price: 1.0, per: 'KILOGRAM', location: 3),
      _category(tag: 'en:bananas', price: .25, per: 'UNIT', location: 4),
    ];
    expect(_aggregate('banana', bananas)!.median, closeTo(1.29, 1e-9));
    expect(_aggregate('banana', bananas)!.samples, 3);

    // Cucumbers per piece: category prices per kilogram do not count.
    final cucumbers = [
      _category(tag: 'en:cucumbers', price: .79, per: 'UNIT', location: 1),
      _category(tag: 'en:cucumbers', price: .99, per: 'UNIT', location: 2),
      _category(tag: 'en:cucumbers', price: .69, per: 'UNIT', location: 3),
      _category(tag: 'en:cucumbers', price: 3.31, per: 'KILOGRAM', location: 4),
    ];
    final perPiece = _aggregate('cucumber', cucumbers)!;
    expect(perPiece.basis, PriceBasis.piece);
    expect(perPiece.median, closeTo(.79, 1e-9));

    // Eggs are counted from the printed pack size.
    final eggs = [
      _product(
        price: 2.99,
        location: 1,
        quantity: 0,
        unit: null,
        quantityText: '10',
        tags: const ['en:eggs'],
      ),
      _product(
        price: 1.89,
        location: 2,
        quantity: null,
        unit: null,
        quantityText: '6 Stück',
        tags: const ['en:eggs'],
      ),
      _product(
        price: 3.29,
        location: 3,
        quantity: null,
        unit: null,
        quantityText: 'M 10',
        tags: const ['en:eggs'],
      ),
    ];
    expect(_aggregate('egg', eggs)!.median, closeTo(.315, 1e-9));
  });

  test('piece counts are read from the printed pack size', () {
    const cases = {
      '10 Stück': 10,
      '10er': 10,
      '6 x 50 g': 6,
      '7x 70g': 7,
      '10 pcs': 10,
      '6pcs': 6,
      'M 10': 10,
      '10': 10,
      '500 g': null,
      '0': null,
      '1000': null,
      '': null,
    };
    for (final MapEntry(key: text, value: count) in cases.entries) {
      expect(parsePieceCount(text), count, reason: text);
    }
    expect(parsePieceCount(null), isNull);
  });

  test('three distinct product-and-shop prices are needed; the same pack '
      'in the same shop three times is one', () {
    // The capture's Gouda: one product, one shop, three dates.
    final gouda = [
      for (final date in ['2026-09-12', '2026-09-22', '2026-09-29'])
        _product(
          price: 2.45,
          quantity: 400,
          location: 6701,
          date: date,
          code: '4316268604895',
          tags: const ['en:gouda'],
        ),
    ];
    expect(_aggregate('gouda', gouda), isNull);
    expect(
      aggregatePriceObservations(
        priceObservations(
          _entry('gouda'),
          gouda,
          region: _region,
          today: _today,
        ),
        basis: PriceBasis.mass,
        minSamples: 1,
      )!.median,
      closeTo(6.125, 1e-9),
    );
    // One purchase reported twice is one price, not two.
    final twice = [
      _butter(4.0, shop: 1),
      _butter(4.0, shop: 1),
      _butter(4.4, shop: 2),
    ];
    expect(_aggregate('butter', twice), isNull);
  });

  test('the 3x band drops a premium outlier before the median', () {
    // The capture's 250 ml bottle at 59.96 EUR per litre.
    final oil = [
      _product(
        price: 9.74,
        quantity: 750,
        unit: 'ml',
        location: 1,
        tags: const ['en:olive-oils'],
      ),
      _product(
        price: 8.25,
        quantity: 750,
        unit: 'ml',
        location: 2,
        tags: const ['en:olive-oils'],
      ),
      _product(
        price: 10.5,
        quantity: 750,
        unit: 'ml',
        location: 3,
        tags: const ['en:olive-oils'],
      ),
      _product(
        price: 14.99,
        quantity: 250,
        unit: 'ml',
        location: 4,
        tags: const ['en:olive-oils'],
      ),
    ];
    final aggregate = _aggregate('oliveOil', oil)!;
    expect(aggregate.samples, 3);
    expect(aggregate.median, closeTo(12.986666, 1e-5));
  });

  test('an exact barcode needs one recent price of its own', () {
    final rows = [
      _product(
        price: 3.99,
        code: '4008400401621',
        quantity: 450,
        location: 7257,
        date: '2026-09-18',
        tags: const [],
      ),
      // The same product in France and a rival product: not counted.
      _product(
        price: 4.45,
        code: '4008400401621',
        quantity: 450,
        country: 'FR',
      ),
      _product(price: 4.45, code: '3017620422003', quantity: 400),
    ];
    final exact = exactProductAggregate(
      '4008400401621',
      rows,
      region: _region,
      today: _today,
    )!;
    expect(exact.exactProduct, isTrue);
    expect(exact.basis, PriceBasis.mass);
    expect(exact.median, closeTo(8.8667, 1e-4));
    expect(
      exactProductAggregate(
        '4000000000099',
        rows,
        region: _region,
        today: _today,
      ),
      isNull,
    );
  });

  group('the cost of a line', () {
    PriceAggregate agg(double median, [PriceBasis basis = PriceBasis.mass]) =>
        PriceAggregate(
          basis: basis,
          median: median,
          samples: 5,
          newestDate: '2026-10-01',
        );

    LinePrice cost(
      String label,
      PriceAggregate aggregate, {
      String? amount,
      double? grams,
      String? entry,
    }) {
      final line = PriceRequestLine(
        id: label,
        label: label,
        amount: amount,
        grams: grams,
      );
      final match = matchPriceEntry(label, quantity: lineQuantity(line));
      return priceLine(
        line,
        aggregate,
        entry: entry == null ? match.entry : kPriceEntries[entry],
        impliedUnit: match.impliedUnit,
      );
    }

    int cents(LinePrice price) => (price as LinePriceEstimate).cents;

    test('the share of the printed amount', () {
      expect(
        cents(cost('Milch', agg(1.145, PriceBasis.volume), amount: '500 ml')),
        57,
      );
      expect(cents(cost('Butter', agg(4.76), amount: '250 g')), 119);
      expect(cents(cost('Butter', agg(4.76), amount: '1 EL')), 7);
      expect(cents(cost('Weizenmehl', agg(.79), amount: '3 EL')), 2);
      expect(
        cents(cost('Olivenöl', agg(12.99, PriceBasis.volume), amount: '2 EL')),
        39,
      );
      expect(cents(cost('Bananen', agg(1.29), amount: '6')), 93);
      expect(cents(cost('Brot', agg(4.61), amount: '1')), 231);
      expect(cents(cost('Lachs', agg(39.9), amount: '2 x 150 g')), 1197);
      // "2 Knoblauchzehen" are two cloves of 4 g, not two bulbs.
      expect(cents(cost('Knoblauchzehen', agg(10.47), amount: '2')), 8);
      expect(cents(cost('Knoblauch', agg(10.47), amount: '1')), 52);
      // Passata by volume through its density.
      expect(cents(cost('Passierte Tomaten', agg(2.0), amount: '200 ml')), 42);
      // A weighed item: grams, also for a piece price (two 60 g eggs).
      expect(cents(cost('Eier', agg(.3, PriceBasis.piece), grams: 120)), 60);
      expect(
        cents(cost('Eier', agg(.3, PriceBasis.piece), amount: '1 Packung')),
        300,
      );
    });

    test('a priced line shows at least one cent', () {
      expect(cents(cost('Weizenmehl', agg(.79), amount: '1 g')), 1);
    });

    test('no amount: one pack or one piece, else no price', () {
      final pack = cost('Butter', agg(4.76)) as LinePriceEstimate;
      expect((pack.cents, pack.kind), (119, LinePriceKind.pack));
      final piece =
          cost('Gurke', agg(.89, PriceBasis.piece)) as LinePriceEstimate;
      expect((piece.cents, piece.kind), (89, LinePriceKind.piece));
      // Tomatoes have no pack size.
      expect(cost('Tomaten', agg(2.99)), isA<LinePriceNoData>());
    });

    test('an amount that cannot be converted has no price', () {
      expect(
        cost('Spinat', agg(5), amount: '1 Handvoll', entry: 'butter'),
        isA<LinePriceNoData>(),
      );
      // Butter comes in no can.
      expect(
        cost('Butter', agg(4.76), amount: '1 Dose'),
        isA<LinePriceNoData>(),
      );
      expect(
        cost('Gurke', agg(.89, PriceBasis.piece), amount: '1 EL'),
        isA<LinePriceNoData>(),
      );
    });

    test('no aggregate, no price', () {
      expect(
        priceLine(const PriceRequestLine(id: 'a', label: 'Butter'), null),
        isA<LinePriceNoData>(),
      );
    });

    test('an exact product prices its own grams', () {
      const exact = PriceAggregate(
        basis: PriceBasis.mass,
        median: 3.99 / 450 * 1000,
        samples: 1,
        newestDate: '2026-09-18',
        exactProduct: true,
      );
      expect(
        cents(
          priceLine(
            const PriceRequestLine(id: 'n', label: 'Nutella', grams: 30),
            exact,
          ),
        ),
        27,
      );
    });
  });

  test('the total is the sum of the shown values; a missing price makes it '
      'a subtotal', () {
    const estimate = LinePriceEstimate(
      cents: 57,
      aggregate: PriceAggregate(
        basis: PriceBasis.volume,
        median: 1.145,
        samples: 16,
        newestDate: '2026-10-10',
      ),
    );
    final all = shoppingPriceTotal([
      estimate,
      estimate,
      const LinePriceSkipped(),
    ]);
    expect((all.cents, all.priced, all.unpriced), (114, 2, 0));
    expect(all.complete, isTrue);
    final partial = shoppingPriceTotal([estimate, const LinePriceNoData()]);
    expect(
      (partial.unpriced, partial.complete, partial.failed),
      (1, false, false),
    );
    final loading = shoppingPriceTotal([estimate, const LinePriceLoading()]);
    expect((loading.pending, loading.complete), (1, false));
    final failed = shoppingPriceTotal([const LinePriceUnavailable()]);
    expect((failed.unpriced, failed.failed), (1, true));
  });

  test('prices are shown for a German device region only', () {
    const de = Locale('de');
    const en = Locale('en');
    expect(priceRegionFor(const [Locale('de', 'DE')], de), PriceRegion.germany);
    // Any device locale naming Germany counts: English app, German region.
    expect(
      priceRegionFor(const [Locale('en', 'US'), Locale('de', 'DE')], en),
      PriceRegion.germany,
    );
    expect(priceRegionFor(const [Locale('en', 'DE')], en), PriceRegion.germany);
    expect(priceRegionFor(const [Locale('en', 'US')], de), isNull);
    expect(priceRegionFor(const [Locale('de', 'AT')], de), isNull);
    // No country anywhere: the app language decides.
    expect(priceRegionFor(const [Locale('en')], de), PriceRegion.germany);
    expect(priceRegionFor(const [], de), PriceRegion.germany);
    expect(priceRegionFor(const [Locale('de')], en), isNull);
  });

  test('the receipt rows become price questions with their check ids', () {
    final lines = priceRequestLines(const [
      ShoppingItem(id: 'w', name: 'Nutella', grams: 30, productCode: '1'),
      ShoppingItem(
        id: 't',
        name: 'Pizza',
        lines: [
          ShoppingLine(id: 'h', label: 'Belag:', heading: true),
          ShoppingLine(id: 'l', label: 'Salami', amount: '80 g'),
        ],
      ),
    ]);
    expect(
      lines.map((l) => (l.id, l.label, l.amount, l.grams, l.productCode)),
      [('w', 'Nutella', null, 30.0, '1'), ('l', 'Salami', '80 g', null, null)],
    );
  });
}
