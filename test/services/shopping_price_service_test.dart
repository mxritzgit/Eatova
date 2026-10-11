// The estimate's orchestration (docs/SHOPPING-PRICES.md) over a scripted
// Open Prices connection: concurrency, budgets, the session cache and its
// expiry, failures that are never cached, cancellation, and diagnostics.
// Answers come from the recorded fixtures; no network.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/shopping_price.dart';
import 'package:eatova/src/services/crash_reporter.dart';
import 'package:eatova/src/services/open_prices_api.dart';
import 'package:eatova/src/services/shopping_price_service.dart';

OpenPricesPage _page(String name) => OpenPricesPage.fromJson(
  jsonDecode(
    File('test/services/open_prices_fixtures/$name').readAsStringSync(),
  ),
);

final _category = _page('category_page.json');
final _barcodes = _page('barcodes.json');
final _tags = [_page('tags_page1.json'), _page('tags_page2.json')];
const _yogurt = [
  'en:dairies',
  'en:fermented-dairy-desserts',
  'en:yogurts',
  'en:fruit-yogurts',
];

/// The recorded answer for [query].
OpenPricesPage _answer(Map<String, String> query) {
  if (query['type'] == 'CATEGORY') return _category;
  if (query.containsKey('product_code__in')) return _barcodes;
  return _tags[int.parse(query['page']!) - 1];
}

class _FakeSource implements OpenPricesSource {
  _FakeSource({this.prices, this.product, this.delay});

  Future<OpenPricesPage> Function(Map<String, String> query)? prices;
  Future<List<String>?> Function(String code)? product;

  /// Every answer waits this long, so requests overlap.
  Duration? delay;

  final List<_FakeConnection> connections = [];
  final List<Map<String, String>> queries = [];
  final List<String> products = [];
  int _inFlight = 0;
  int peak = 0;

  int get requests => queries.length + products.length;

  @override
  OpenPricesConnection connect() {
    final connection = _FakeConnection(this);
    connections.add(connection);
    return connection;
  }

  Future<T> _track<T>(Future<T> Function() answer) async {
    _inFlight++;
    peak = math.max(peak, _inFlight);
    try {
      if (delay case final wait?) await Future<void>.delayed(wait);
      return await answer();
    } finally {
      _inFlight--;
    }
  }
}

class _FakeConnection implements OpenPricesConnection {
  _FakeConnection(this._source);

  final _FakeSource _source;
  bool closed = false;

  @override
  Future<OpenPricesPage> prices(Map<String, String> query) {
    _source.queries.add(query);
    return _source._track(
      () => _source.prices?.call(query) ?? Future.value(_answer(query)),
    );
  }

  @override
  Future<List<String>?> productCategories(String code) {
    _source.products.add(code);
    return _source._track(
      () => _source.product?.call(code) ?? Future.value(_yogurt),
    );
  }

  @override
  void close() => closed = true;
}

const _list = [
  PriceRequestLine(
    id: 'nutella',
    label: 'Nutella',
    grams: 30,
    productCode: '4008400401621',
  ),
  PriceRequestLine(
    id: 'almighurt',
    label: 'Almighurt Kirsche',
    grams: 150,
    productCode: '4002971840209',
  ),
  PriceRequestLine(id: 'milch', label: 'Milch', amount: '500 ml'),
  PriceRequestLine(id: 'bananen', label: 'Bananen', amount: '6'),
  PriceRequestLine(id: 'salami', label: 'Salami', amount: '200 g'),
  PriceRequestLine(id: 'salz', label: 'Salz', amount: '1 Prise'),
];

var _now = DateTime(2026, 10, 11, 8);

Future<T> _at<T>(Future<T> Function() body) =>
    withClock(Clock(() => _now), body);

Future<Map<String, LinePrice>> _run(
  ShoppingPriceService service, [
  List<PriceRequestLine> lines = _list,
]) => _at(() => service.estimate(lines, region: PriceRegion.germany).result);

/// A page of [rows] that says it is complete unless [pages] says otherwise.
OpenPricesPage _pageOf(List<OpenPriceRow> rows, {int pages = 1}) =>
    OpenPricesPage(items: rows, page: 1, pages: pages, total: rows.length);

/// A loose-goods price of [tag] in German shop [shop], in the window.
OpenPriceRow _loose(int shop, String tag, String per, double price) =>
    OpenPriceRow(
      id: 9000 + shop,
      type: OpenPriceType.category,
      price: price,
      pricePer: per,
      currency: 'EUR',
      date: '2026-10-01',
      locationId: shop,
      locationType: 'OSM',
      countryCode: 'DE',
      categoryTag: tag,
    );

/// An unnamed weighed product: only its barcode can price it.
PriceRequestLine _unnamed(String code, {String label = 'Produkt X'}) =>
    PriceRequestLine(id: code, label: label, grams: 100, productCode: code);

OpenPricesShoppingPriceService _service(
  _FakeSource source, {
  int maxRequestsPerRun = 16,
  int sessionLimit = 48,
}) => OpenPricesShoppingPriceService(
  source,
  retryDelay: const Duration(milliseconds: 1),
  maxRequestsPerRun: maxRequestsPerRun,
  sessionLimit: sessionLimit,
);

void main() {
  setUp(() => _now = DateTime(2026, 10, 11, 8));

  test('at most two requests in flight; at most six product lookups, the '
      'heaviest first', () async {
    final source = _FakeSource(
      delay: const Duration(milliseconds: 5),
      product: (_) async => null,
    );
    final unknown = [
      for (var i = 1; i <= 8; i++)
        PriceRequestLine(
          id: 'x$i',
          label: 'Produkt $i',
          grams: i * 10,
          productCode: '400000000000$i',
        ),
    ];
    final prices = await _run(_service(source), [..._list, ...unknown]);
    expect(source.peak, 2);
    expect(source.products, hasLength(6));
    expect(source.products, isNot(contains('4000000000001')));
    expect(source.products, isNot(contains('4000000000002')));
    for (final line in unknown) {
      expect(prices[line.id], isA<LinePriceNoData>(), reason: line.id);
    }
    expect(prices['milch'], isA<LinePriceEstimate>());
  });

  test('every missing entry goes into one overlap request', () async {
    final source = _FakeSource();
    await _run(_service(source));
    final overlaps = source.queries
        .where((q) => q.containsKey('product__categories_tags__overlap'))
        .map((q) => q['product__categories_tags__overlap'])
        .toSet();
    expect(overlaps, hasLength(1));
    expect(
      overlaps.single!.split(','),
      unorderedEquals(['en:yogurts', 'en:milks', 'en:bananas', 'en:salami']),
    );
    expect(source.requests, 5);
    expect(source.connections.single.closed, isTrue);
  });

  test('the per-run budget stops further requests; what it misses is '
      'unavailable', () async {
    final source = _FakeSource();
    final prices = await _run(_service(source, maxRequestsPerRun: 2));
    expect(source.requests, 2);
    expect(prices['nutella'], isA<LinePriceEstimate>());
    expect(prices['almighurt'], isA<LinePriceUnavailable>());
    expect(prices['milch'], isA<LinePriceUnavailable>());
    expect(prices['salz'], isA<LinePriceSkipped>());
  });

  test('the same list again costs nothing, no-data results included', () async {
    final source = _FakeSource();
    final service = _service(source);
    final first = await _run(service);
    expect(first['salami'], isA<LinePriceNoData>());
    final requests = source.requests;
    final run = _at(
      () async => service.estimate(_list, region: PriceRegion.germany),
    );
    final second = await run;
    expect(second.initial.keys, unorderedEquals(_list.map((l) => l.id)));
    expect(await second.result, first);
    expect(source.requests, requests);
    expect(source.connections, hasLength(1));
  });

  test('the cache holds for one day and under twelve hours', () async {
    final source = _FakeSource();
    final service = _service(source);
    await _run(service);
    final requests = source.requests;

    _now = DateTime(2026, 10, 11, 19, 59);
    await _run(service);
    expect(source.requests, requests);

    _now = DateTime(2026, 10, 11, 20);
    await _run(service);
    expect(source.requests, greaterThan(requests));

    // Rewritten at 20:00, stale after midnight.
    final late = source.requests;
    _now = DateTime(2026, 10, 12, 0, 30);
    await _run(service);
    expect(source.requests, greaterThan(late));
    expect(
      source.queries.last['date__gte'],
      '2026-08-31',
      reason: 'the window moves with the day',
    );
  });

  test('a result cut off by the page cap is shown, not cached', () async {
    bool overlap(Map<String, String> q) =>
        q.containsKey('product__categories_tags__overlap');
    final source = _FakeSource();
    final service = OpenPricesShoppingPriceService(
      source,
      retryDelay: const Duration(milliseconds: 1),
      maxTagPages: 1,
    );
    final first = await _run(service);
    // Page 1 of 2 still prices this run.
    expect(source.queries.where(overlap), hasLength(1));
    expect(first['milch'], isA<LinePriceEstimate>());
    // The next run asks again instead of keeping a partial answer all day.
    await _run(service);
    expect(source.queries.where(overlap), hasLength(2));
  });

  test('a barcode answer cut off after its one page is shown, not '
      'cached', () async {
    bool barcodes(Map<String, String> q) => q.containsKey('product_code__in');
    final source = _FakeSource(
      // Nutella's price is on page 1; X's may be on page 2.
      prices: (query) async =>
          barcodes(query) ? _pageOf(_barcodes.items, pages: 2) : _answer(query),
      product: (_) async => null,
    );
    final service = _service(source);
    final lines = [_list.first, _unnamed('4000000000099')];
    final first = await _run(service, lines);
    expect(first['nutella'], isA<LinePriceEstimate>());
    expect(first['4000000000099'], isA<LinePriceNoData>());
    expect(source.queries.where(barcodes), hasLength(1));
    // "No row on page 1" is no proof of no price: the next run asks again
    // instead of keeping that answer all day.
    await _run(service, lines);
    expect(source.queries.where(barcodes), hasLength(2));
  });

  test('barcode categories are kept like prices: until midnight and under '
      'twelve hours', () async {
    final source = _FakeSource(product: (_) async => null);
    final service = _service(source);
    final lines = [_unnamed('4000000000099')];

    _now = DateTime(2026, 10, 11, 23, 50);
    await _run(service, lines);
    expect(source.products, ['4000000000099']);
    _now = DateTime(2026, 10, 11, 23, 59);
    await _run(service, lines);
    expect(source.products, hasLength(1), reason: 'the same day');

    _now = DateTime(2026, 10, 12, 0, 10);
    await _run(service, lines);
    expect(source.products, hasLength(2), reason: 'after midnight');

    _now = DateTime(2026, 10, 12, 12, 9);
    await _run(service, lines);
    expect(source.products, hasLength(2), reason: 'under twelve hours');
    _now = DateTime(2026, 10, 12, 12, 10);
    await _run(service, lines);
    expect(source.products, hasLength(3), reason: 'twelve hours on');
  });

  test('a barcode\'s categories price a line only when the product passes '
      'the entry\'s tags and the line names no excluded word', () async {
    const fresh = ['en:fresh-vegetables', 'en:garlic'];
    final pickle = _tags.first.items
        .firstWhere((row) => row.productCode == '4306188409588')
        .categoriesTags;
    final categories = {
      '4000000000001': fresh,
      // Tagged as fresh garlic, named as granulated.
      '4000000000002': fresh,
      '4000000000003': pickle,
    };
    final source = _FakeSource(
      // Enough loose garlic and cucumber prices to price either entry.
      prices: (query) async => _pageOf([
        if (query['type'] == 'CATEGORY')
          for (var shop = 1; shop <= 3; shop++) ...[
            _loose(shop, 'en:garlic', 'KILOGRAM', 4 + shop / 10),
            _loose(10 + shop, 'en:cucumbers', 'UNIT', 0.7 + shop / 10),
          ],
      ]),
      product: (code) async => categories[code],
    );
    final prices = await _run(_service(source), [
      _unnamed('4000000000001', label: 'Bio Knolle'),
      _unnamed('4000000000002', label: 'Ostmann Knoblauchgranulat'),
      _unnamed('4000000000003', label: 'Kühne Gurkensticks'),
    ]);
    expect(prices['4000000000001'], isA<LinePriceEstimate>());
    expect(prices['4000000000002'], isA<LinePriceNoData>());
    expect(prices['4000000000003'], isA<LinePriceNoData>());
    expect(
      source.queries.map((q) => q['product__categories_tags__overlap']),
      isNot(contains(contains('en:cucumbers'))),
    );
  });

  test('a run past its budget sends nothing more', () async {
    final source = _FakeSource(
      prices: (query) async {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        return _answer(query);
      },
    );
    final service = OpenPricesShoppingPriceService(
      source,
      retryDelay: const Duration(milliseconds: 1),
      runBudget: const Duration(milliseconds: 60),
    );
    final prices = await _run(service);
    // The barcode and loose-goods requests ran into the budget; neither a
    // retry, the product lookup nor the overlap request went out after it.
    expect(source.queries, hasLength(2));
    expect(source.products, isEmpty);
    expect(prices['milch'], isA<LinePriceUnavailable>());
    expect(prices['almighurt'], isA<LinePriceUnavailable>());
    expect(prices['salz'], isA<LinePriceSkipped>());
  });

  test('failures are never cached', () async {
    var fail = true;
    final source = _FakeSource(
      prices: (query) async {
        if (fail) throw OpenPricesHttpException(503);
        return _answer(query);
      },
    );
    final service = _service(source);
    final first = await _run(service);
    expect(first['milch'], isA<LinePriceUnavailable>());
    // Two attempts per request: the retry.
    expect(source.queries.where((q) => q['type'] == 'CATEGORY'), hasLength(2));
    fail = false;
    final second = await _run(service);
    expect(second['milch'], isA<LinePriceEstimate>());
  });

  test(
    'a FormatException is not retried and reported once per session',
    () async {
      final reports = <String?>[];
      CrashReporter.debugSentrySink = (_, _, context) => reports.add(context);
      addTearDown(() => CrashReporter.debugSentrySink = null);
      final source = _FakeSource(
        prices: (_) async => throw const OpenPricesFormatException(),
      );
      final service = _service(source);
      final prices = await _run(service);
      expect(prices['bananen'], isA<LinePriceUnavailable>());
      expect(
        source.queries.where((q) => q['type'] == 'CATEGORY'),
        hasLength(1),
      );
      await _run(service);
      expect(reports, ['open_prices']);
    },
  );

  test('cancel closes the connection and ends the run as cancelled', () async {
    final hang = Completer<OpenPricesPage>();
    final source = _FakeSource(prices: (_) => hang.future);
    final run = await _at(
      () async => _service(source).estimate(_list, region: PriceRegion.germany),
    );
    await Future<void>.delayed(Duration.zero);
    expect(source.connections.single.closed, isFalse);
    run.cancel();
    expect(source.connections.single.closed, isTrue);
    await expectLater(run.result, throwsA(isA<ShoppingPriceCancelled>()));
    // A late answer changes nothing.
    hang.complete(_category);
    run.cancel();
  });

  test('dispose cancels the run in flight', () async {
    final source = _FakeSource(
      prices: (_) => Completer<OpenPricesPage>().future,
    );
    final service = _service(source);
    final run = await _at(
      () async => service.estimate(_list, region: PriceRegion.germany),
    );
    service.dispose();
    await expectLater(run.result, throwsA(isA<ShoppingPriceCancelled>()));
    expect(source.connections.single.closed, isTrue);
  });

  test('the session limit caps requests across runs', () async {
    final source = _FakeSource();
    final service = _service(source, sessionLimit: 3);
    final prices = await _run(service);
    expect(source.requests, 3);
    expect(prices.values.whereType<LinePriceUnavailable>(), isNotEmpty);
    await _run(service);
    expect(source.requests, 3);
    // Ten minutes later the window has room again.
    _now = _now.add(const Duration(minutes: 10));
    await _run(service);
    expect(source.requests, greaterThan(3));
  });

  test('lines settled locally open no connection', () async {
    final source = _FakeSource();
    final run = await _at(
      () async => _service(source).estimate(const [
        PriceRequestLine(id: 'a', label: 'Salz', amount: '1 Prise'),
        PriceRequestLine(id: 'b', label: 'Brokkoli'),
        PriceRequestLine(id: 'c', label: 'Spinat', amount: '1 Handvoll'),
        PriceRequestLine(id: 'd', label: 'Kokosmilch', amount: '1 Dose'),
        // A barcode Open Prices cannot know.
        PriceRequestLine(
          id: 'e',
          label: 'Hausmischung',
          grams: 50,
          productCode: 'manual-1',
        ),
      ], region: PriceRegion.germany),
    );
    expect(run.initial, hasLength(5));
    expect(run.initial['a'], isA<LinePriceSkipped>());
    expect(run.initial['b'], isA<LinePriceNoData>());
    expect(await run.result, run.initial);
    expect(source.connections, isEmpty);
  });
}
