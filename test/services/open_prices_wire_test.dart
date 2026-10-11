// Wire test for the Open Prices client and the shopping price estimate
// (docs/SHOPPING-PRICES.md), in the style of open_food_facts_wire_test.dart:
// recorded answers are served byte for byte by a loopback HttpServer and go
// through the real chain (HttpClient -> UTF-8 -> jsonDecode -> rows ->
// aggregation -> line prices). Every outgoing parameter name is checked
// against the published OpenAPI spec, because the server silently drops
// unknown parameters and would answer a typo with unfiltered data.
//
// FIXTURE ORIGIN (test/services/open_prices_fixtures/): live answers of
// prices.openfoodfacts.org captured on 2026-10-11 (EUR rows within 450 km of
// Germany's centre, last 42 days; the barcode lookups with a 90-day window),
// trimmed: at most ~60 rows per page, every top-level field of a row kept,
// nested product/location/proof records cut to the fields that identify
// them and the ones the client reads, contributor names pseudonymised to
// contributor-N, proof image paths, hashes and comments removed.
// product_found.json is a captured product record; product_not_found.json
// and envelope_broken.json are reconstructed (Django REST framework's 404
// and its default pagination envelope).

import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/shopping_price.dart';
import 'package:eatova/src/services/eatova_http.dart';
import 'package:eatova/src/services/open_prices_api.dart';
import 'package:eatova/src/services/shopping_price_service.dart';

/// Query parameter names of `GET /api/v1/prices`, copied from
/// https://prices.openfoodfacts.org/api/schema on 2026-10-11.
const Set<String> _specParameters = {
  'category_tag', 'created__gte', 'created__lte', 'currency', 'date', //
  'date__gt', 'date__gte', 'date__lt', 'date__lte', 'date__month', //
  'date__year', 'discount_type', 'duplicate_of__isnull', 'kind', //
  'labels_tags__contains', 'lat', 'location__osm_name__contains', //
  'location__type', 'location_id', 'location_id__in', 'location_id__isnull',
  'location_osm_id', 'location_osm_type', 'lon', 'order_by', //
  'origins_tags__contains', 'owner', 'page', 'price', 'price__gt', //
  'price__gte', 'price__lt', 'price__lte', 'price_is_discounted', //
  'product__categories_tags__contains', 'product__categories_tags__overlap',
  'product__source', 'product__source__isnull', 'product_code', //
  'product_code__in', 'product_code__isnull', 'product_id', //
  'product_id__in', 'product_id__isnull', 'product_name', 'proof__type', //
  'proof_id', 'proof_id__in', 'proof_id__isnull', 'radius_km', 'size', //
  'tags__contains', 'type',
};

/// The yogurt whose own prices are older than six weeks.
const _yogurtCode = '4002971840209';

/// Nutella 450 g, the German barcode with one recent German price.
const _nutellaCode = '4008400401621';

final _today = DateTime(2026, 10, 11, 12);

List<int> _fixture(String name) {
  final file = File('test/services/open_prices_fixtures/$name');
  if (!file.existsSync()) fail('Fixture $name fehlt');
  return file.readAsBytesSync();
}

/// Serves the fixtures like Open Prices and records every request.
class _PricesServer {
  _PricesServer._(this._server);

  final HttpServer _server;
  final List<HttpRequest> requests = [];

  /// Statuses answered (in order) before the real answer, per query kind:
  /// `category`, `barcodes`, `tags`, `product`.
  final Map<String, List<int>> failures = {};

  /// Kinds that never answer.
  final Set<String> hang = {};

  /// Replaces the answer of a kind with this body.
  final Map<String, String> bodies = {};

  String get baseUrl => 'http://127.0.0.1:${_server.port}/api/v1';

  static Future<_PricesServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final prices = _PricesServer._(server);
    server.listen(prices._handle);
    return prices;
  }

  Future<void> close() => _server.close(force: true);

  Iterable<Uri> get priceQueries =>
      requests.map((r) => r.uri).where((u) => u.path.endsWith('/prices'));

  Future<void> _handle(HttpRequest request) async {
    requests.add(request);
    final uri = request.uri;
    final query = uri.queryParameters;
    final kind = uri.path.contains('/products/code/')
        ? 'product'
        : query['type'] == 'CATEGORY'
        ? 'category'
        : query.containsKey('product_code__in')
        ? 'barcodes'
        : 'tags';
    if (hang.contains(kind)) return;
    final failing = failures[kind];
    if (failing != null && failing.isNotEmpty) {
      request.response
        ..statusCode = failing.removeAt(0)
        ..write('<html>busy</html>');
      await request.response.close();
      return;
    }
    if (bodies[kind] case final body?) {
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(body);
      await request.response.close();
      return;
    }
    final (status, name) = switch (kind) {
      'category' => (200, 'category_page.json'),
      'barcodes' => (200, 'barcodes.json'),
      'tags' => (200, 'tags_page${query['page']}.json'),
      _ when uri.pathSegments.last == _yogurtCode => (
        200,
        'product_found.json',
      ),
      _ => (404, 'product_not_found.json'),
    };
    request.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..add(_fixture(name));
    await request.response.close();
  }
}

/// The owner's kind of list: weighed items with barcodes, free text with
/// amounts, seasoning, an unknown food and a false friend.
const _lines = [
  PriceRequestLine(
    id: 'nutella',
    label: 'Nutella',
    grams: 30,
    productCode: _nutellaCode,
  ),
  PriceRequestLine(
    id: 'almighurt',
    label: 'Almighurt Kirsche',
    grams: 150,
    productCode: _yogurtCode,
  ),
  PriceRequestLine(id: 'milch', label: 'Milch', amount: '500 ml'),
  PriceRequestLine(id: 'butter', label: 'Butter', amount: '250 g'),
  PriceRequestLine(id: 'bananen', label: 'Bananen', amount: '6'),
  PriceRequestLine(id: 'gurke', label: 'Gurke', amount: '1'),
  PriceRequestLine(id: 'salami', label: 'Salami', amount: '200 g'),
  PriceRequestLine(id: 'salz', label: 'Salz', amount: '1 Prise'),
  PriceRequestLine(id: 'brokkoli', label: 'Brokkoli'),
  PriceRequestLine(id: 'brot', label: 'Brot', amount: '1'),
  PriceRequestLine(id: 'lachs', label: 'Lachs', amount: '2 x 150 g'),
  PriceRequestLine(id: 'spinat', label: 'Spinat', amount: '1 Handvoll'),
  PriceRequestLine(id: 'kokos', label: 'Kokosmilch', amount: '1 Dose'),
];

Future<Map<String, LinePrice>> _estimate(
  OpenPricesShoppingPriceService service, [
  List<PriceRequestLine> lines = _lines,
]) => withClock(
  Clock.fixed(_today),
  () => service.estimate(lines, region: PriceRegion.germany).result,
);

Map<String, Object> _summary(Map<String, LinePrice> prices) => {
  for (final MapEntry(key: id, value: price) in prices.entries)
    id: switch (price) {
      LinePriceEstimate(:final cents) => cents,
      _ => price.runtimeType.toString(),
    },
};

void main() {
  late _PricesServer server;
  late HttpOpenPricesSource source;

  setUp(() async {
    server = await _PricesServer.start();
    source = HttpOpenPricesSource(baseUrl: server.baseUrl);
  });

  tearDown(() => server.close());

  OpenPricesShoppingPriceService service({
    HttpOpenPricesSource? via,
    int maxTagPages = 8,
  }) => OpenPricesShoppingPriceService(
    via ?? source,
    retryDelay: const Duration(milliseconds: 10),
    maxTagPages: maxTagPages,
  );

  test(
    'a German list end to end: barcode, categories, tags, loose goods',
    () async {
      final prices = await _estimate(service());

      expect(_summary(prices), {
        // 3.99 EUR for 450 g, its own barcode: 30 g.
        'nutella': 27,
        // No recent price of its own; its categories make it a yogurt.
        'almighurt': 42,
        'milch': 57,
        'butter': 119,
        // Six unpeeled bananas of 170 g at the loose price per kilogram.
        'bananen': 132,
        // Two shops with a cucumber price: too few.
        'gurke': 'LinePriceNoData',
        'salami': 'LinePriceNoData',
        'salz': 'LinePriceSkipped',
        'brokkoli': 'LinePriceNoData',
        // A loaf of 500 g; a shop's repeat reports of one bread count once.
        'brot': 217,
        'lachs': 1197,
        'spinat': 'LinePriceNoData',
        'kokos': 'LinePriceNoData',
      });
      final butter = prices['butter']! as LinePriceEstimate;
      expect(butter.aggregate.median, closeTo(4.76, 1e-9));
      expect(butter.aggregate.samples, 5);
      final nutella = prices['nutella']! as LinePriceEstimate;
      expect(nutella.aggregate.exactProduct, isTrue);
      // Barcodes, loose goods, one product record, two pages of tags.
      expect(server.requests, hasLength(5));
    },
  );

  test('every parameter is one the spec knows, with the agreed values', () async {
    await _estimate(service());
    final queries = server.priceQueries.toList();
    expect(queries, hasLength(4));
    for (final uri in queries) {
      final query = uri.queryParameters;
      expect(
        query.keys.toSet().difference(_specParameters),
        isEmpty,
        reason: '$uri',
      );
      expect(query, containsPair('currency', 'EUR'));
      expect(query, containsPair('lat', '51.1657'));
      expect(query, containsPair('lon', '10.4515'));
      expect(query, containsPair('radius_km', '470'));
      expect(query, containsPair('date__gte', '2026-08-30'));
      expect(query, containsPair('duplicate_of__isnull', 'true'));
      expect(query, containsPair('order_by', '-id'));
      expect(query, containsPair('size', '100'));
    }
    final byType = {
      for (final uri in queries)
        '${uri.queryParameters['type']}:${uri.queryParameters['page']}'
                '${uri.queryParameters.containsKey('product_code__in') ? ':codes' : ''}':
            uri.queryParameters,
    };
    expect(
      byType.keys,
      unorderedEquals([
        'CATEGORY:1',
        'PRODUCT:1:codes',
        'PRODUCT:1',
        'PRODUCT:2',
      ]),
    );
    expect(
      byType['PRODUCT:1:codes']!['product_code__in']!.split(','),
      unorderedEquals([_nutellaCode, _yogurtCode]),
    );
    // Every missing entry in one overlap filter.
    expect(
      byType['PRODUCT:1']!['product__categories_tags__overlap']!.split(','),
      unorderedEquals([
        'en:yogurts',
        'en:milks',
        'en:butters',
        'en:bananas',
        'en:cucumbers',
        'en:salami',
        'en:breads',
        'en:salmons',
      ]),
    );
    expect(
      byType['PRODUCT:2']!['product__categories_tags__overlap'],
      byType['PRODUCT:1']!['product__categories_tags__overlap'],
    );
  });

  test(
    'the requests name the app, carry no credentials and no cookie',
    () async {
      await _estimate(service());
      for (final request in server.requests) {
        expect(
          request.headers.value(HttpHeaders.userAgentHeader),
          HttpOpenPricesSource.userAgent,
        );
        expect(
          request.headers.value(HttpHeaders.acceptHeader),
          'application/json',
        );
        expect(request.headers.value(HttpHeaders.authorizationHeader), isNull);
        expect(request.headers.value(HttpHeaders.cookieHeader), isNull);
        expect(request.method, 'GET');
      }
      expect(
        server.requests
            .where((r) => r.uri.path.contains('/products/code/'))
            .single
            .uri
            .path,
        '/api/v1/products/code/$_yogurtCode',
      );
    },
  );

  test('paging stops at the last page and at the page cap', () async {
    final capped = await _estimate(service(maxTagPages: 1));
    final tagPages = server.priceQueries
        .where(
          (u) => u.queryParameters.containsKey(
            'product__categories_tags__overlap',
          ),
        )
        .map((u) => u.queryParameters['page'])
        .toList();
    expect(tagPages, ['1']);
    // A truncated answer still prices what it holds.
    expect(capped['milch'], isA<LinePriceEstimate>());
  });

  test('a 503 is retried once, then succeeds', () async {
    server.failures['category'] = [503];
    final prices = await _estimate(service());
    expect(prices['bananen'], isA<LinePriceEstimate>());
    expect(
      server.priceQueries.where((u) => u.queryParameters['type'] == 'CATEGORY'),
      hasLength(2),
    );
  });

  test('a second 503 leaves the dependent lines unavailable, the rest '
      'priced', () async {
    server.failures['category'] = [503, 503];
    final prices = await _estimate(service());
    // Every entry that also uses loose-goods prices.
    expect(prices['bananen'], isA<LinePriceUnavailable>());
    expect(prices['brot'], isA<LinePriceUnavailable>());
    expect(prices['milch'], isA<LinePriceEstimate>());
    expect(prices['salz'], isA<LinePriceSkipped>());
  });

  test('a 400 is not retried', () async {
    server.failures['barcodes'] = [400];
    final prices = await _estimate(service());
    expect(
      server.priceQueries.where(
        (u) => u.queryParameters.containsKey('product_code__in'),
      ),
      hasLength(1),
    );
    // The barcodes failed: Nutella falls back to its name (hazelnut spreads,
    // none recent in the fixture), the yogurt to its categories.
    expect(prices['nutella'], isA<LinePriceNoData>());
    expect(prices['almighurt'], isA<LinePriceEstimate>());
    expect(
      server.priceQueries
          .firstWhere(
            (u) => u.queryParameters.containsKey(
              'product__categories_tags__overlap',
            ),
          )
          .queryParameters['product__categories_tags__overlap'],
      contains('en:hazelnut-spreads'),
    );
  });

  test(
    'a hanging server times out under the policy and is retried once',
    () async {
      server.hang.add('category');
      final tight = HttpOpenPricesSource(
        baseUrl: server.baseUrl,
        policy: const HttpTimeoutPolicy(
          connect: Duration(seconds: 2),
          response: Duration(milliseconds: 150),
          body: Duration(milliseconds: 150),
          total: Duration(milliseconds: 250),
        ),
      );
      final watch = Stopwatch()..start();
      final prices = await _estimate(service(via: tight));
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
      expect(prices['bananen'], isA<LinePriceUnavailable>());
      expect(prices['milch'], isA<LinePriceEstimate>());
      expect(
        server.priceQueries.where(
          (u) => u.queryParameters['type'] == 'CATEGORY',
        ),
        hasLength(2),
      );
    },
  );

  group('the connection on its own', () {
    late OpenPricesConnection connection;

    setUp(() => connection = source.connect());
    tearDown(() => connection.close());

    test('a known product gives its categories, an unknown one null', () async {
      expect(
        await connection.productCategories(_yogurtCode),
        containsAll(['en:yogurts', 'en:fruit-yogurts']),
      );
      expect(await connection.productCategories('4000000000000'), isNull);
    });

    test('a page reads its envelope and rows', () async {
      final page = await connection.prices(
        OpenPricesQuery.categoryPrices(PriceRegion.germany, '2026-08-30'),
      );
      expect(page.pages, 1);
      expect(page.items, isNotEmpty);
      expect(page.items.where((r) => r.countryCode == 'DE'), hasLength(34));
      expect(page.items.every((r) => r.type == OpenPriceType.category), isTrue);
    });

    test('a changed envelope or a non-JSON body is a FormatException '
        'without its content', () async {
      server.bodies['category'] = utf8.decode(_fixture('envelope_broken.json'));
      await expectLater(
        connection.prices(
          OpenPricesQuery.categoryPrices(PriceRegion.germany, '2026-08-30'),
        ),
        throwsA(isA<OpenPricesFormatException>()),
      );
      server.bodies['category'] = '<html>maintenance</html>';
      await expectLater(
        connection.prices(
          OpenPricesQuery.categoryPrices(PriceRegion.germany, '2026-08-30'),
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            isNot(contains('maintenance')),
          ),
        ),
      );
    });

    test('an error status says whether a retry is worth it', () async {
      for (final (status, retryable) in const [
        (503, true),
        (429, true),
        (404, false),
        (400, false),
      ]) {
        server.failures['barcodes'] = [status];
        await expectLater(
          connection.prices(
            OpenPricesQuery.barcodes(PriceRegion.germany, '2026-08-30', [
              _nutellaCode,
            ]),
          ),
          throwsA(
            isA<OpenPricesHttpException>()
                .having((e) => e.statusCode, 'statusCode', status)
                .having((e) => e.retryable, 'retryable', retryable),
          ),
        );
      }
    });

    test('a runaway body stops at the byte limit', () async {
      server.bodies['tags'] = 'x' * (HttpOpenPricesSource.maxPageBytes + 1);
      await expectLater(
        connection.prices(
          OpenPricesQuery.tags(PriceRegion.germany, '2026-08-30', ['en:milks']),
        ),
        throwsA(isA<HttpResponseTooLargeException>()),
      );
    });

    test('close fails the call in flight', () async {
      server.hang.add('category');
      final pending = connection.prices(
        OpenPricesQuery.categoryPrices(PriceRegion.germany, '2026-08-30'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      connection.close();
      await expectLater(pending, throwsA(anything));
    });
  });

  test('the fixtures are trimmed, pseudonymised and without proof images', () {
    final owner = RegExp(r'^contributor-\d+$');
    for (final name in const [
      'category_page.json',
      'tags_page1.json',
      'tags_page2.json',
      'barcodes.json',
    ]) {
      final json =
          jsonDecode(utf8.decode(_fixture(name))) as Map<String, dynamic>;
      expect(
        json.keys,
        containsAll(['items', 'page', 'pages', 'size', 'total']),
      );
      final items = json['items'] as List<dynamic>;
      expect(items.length, lessThanOrEqualTo(60), reason: name);
      for (final item in items.cast<Map<String, dynamic>>()) {
        expect(owner.hasMatch(item['owner'] as String), isTrue, reason: name);
        final proof = item['proof'] as Map<String, dynamic>?;
        if (proof != null) {
          expect(owner.hasMatch(proof['owner'] as String), isTrue);
          expect(
            proof.keys,
            isNot(
              anyOf(
                contains('file_path'),
                contains('image_md5_hash'),
                contains('image_thumb_path'),
              ),
            ),
          );
        }
      }
    }
  });
}
