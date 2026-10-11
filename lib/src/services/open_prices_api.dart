// Read-only client for Open Prices (prices.openfoodfacts.org), the Open
// Food Facts community price database, for the shopping list's estimate.
// Contract: docs/SHOPPING-PRICES.md.
//
// No authentication and no cookies. The server silently drops unknown query
// parameters, so every filter sent here is checked again on each row by
// shopping_price_aggregation.dart, and the wire test pins every parameter
// name against the published OpenAPI spec.

import 'dart:convert';
import 'dart:io';

import '../models/shopping_price.dart';
import 'eatova_http.dart';

/// Opens one connection per estimate run.
abstract interface class OpenPricesSource {
  OpenPricesConnection connect();
}

abstract interface class OpenPricesConnection {
  /// One page of `GET /prices` for [query] (see [OpenPricesQuery]).
  Future<OpenPricesPage> prices(Map<String, String> query);

  /// The `categories_tags` of an Open Food Facts barcode; null for a product
  /// Open Prices does not know (404).
  Future<List<String>?> productCategories(String code);

  /// Force-closes the socket; calls in flight fail. Used for cancellation.
  void close();
}

/// The production source over dart:io.
class HttpOpenPricesSource implements OpenPricesSource {
  const HttpOpenPricesSource({
    this.baseUrl = defaultBaseUrl,
    this.policy = HttpTimeoutPolicy.openPrices,
  });

  static const String defaultBaseUrl =
      'https://prices.openfoodfacts.org/api/v1';

  /// Names the app, as Open Food Facts asks; never the user.
  static const String userAgent =
      'Eatova/1.0 (Open Prices shopping estimate; mxritzgit/eatova)';

  /// A page of 100 rows is about 340 KB before decompression.
  static const int maxPageBytes = 2 * 1024 * 1024;
  static const int maxProductBytes = 512 * 1024;

  final String baseUrl;
  final HttpTimeoutPolicy policy;

  @override
  OpenPricesConnection connect() => _HttpOpenPricesConnection(baseUrl, policy);
}

class _HttpOpenPricesConnection implements OpenPricesConnection {
  _HttpOpenPricesConnection(this.baseUrl, this.policy)
    : _client = createHttpClient(policy);

  final String baseUrl;
  final HttpTimeoutPolicy policy;
  final HttpClient _client;
  bool _closed = false;

  Future<HttpTextResponse> _get(Uri uri, String operation, int maxBytes) =>
      sendTextRequest(
        _client,
        method: 'GET',
        uri: uri,
        policy: policy,
        operation: operation,
        maxBodyBytes: maxBytes,
        configure: (request) => request.headers
          ..set(HttpHeaders.userAgentHeader, HttpOpenPricesSource.userAgent)
          ..set(HttpHeaders.acceptHeader, 'application/json'),
      );

  @override
  Future<OpenPricesPage> prices(Map<String, String> query) async {
    final uri = Uri.parse('$baseUrl/prices').replace(queryParameters: query);
    final response = await _get(
      uri,
      'openPrices.prices',
      HttpOpenPricesSource.maxPageBytes,
    );
    if (response.statusCode != 200) {
      throw OpenPricesHttpException(response.statusCode);
    }
    return OpenPricesPage.fromJson(_decode(response.body));
  }

  @override
  Future<List<String>?> productCategories(String code) async {
    final uri = Uri.parse(
      '$baseUrl/products/code/${Uri.encodeComponent(code)}',
    );
    final response = await _get(
      uri,
      'openPrices.product',
      HttpOpenPricesSource.maxProductBytes,
    );
    if (response.statusCode == 404) return null;
    if (response.statusCode != 200) {
      throw OpenPricesHttpException(response.statusCode);
    }
    final json = _decode(response.body);
    if (json is! Map<String, dynamic>) throw const OpenPricesFormatException();
    final tags = json['categories_tags'];
    if (tags == null) return const [];
    if (tags is! List) throw const OpenPricesFormatException();
    return [
      for (final tag in tags)
        if (tag is String) tag,
    ];
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _client.close(force: true);
  }
}

/// A body that is not JSON surfaces without its content.
Object? _decode(String body) {
  try {
    return jsonDecode(body);
  } on FormatException {
    throw const OpenPricesFormatException();
  }
}

/// An answer other than 200 (or 404 for a product).
class OpenPricesHttpException extends HttpException {
  OpenPricesHttpException(this.statusCode)
    : super('Open Prices answered $statusCode');

  final int statusCode;

  /// Worth one more try: the server or its rate limiter.
  bool get retryable => statusCode >= 500 || statusCode == 429;
}

/// An answer in an unexpected shape; carries no response content.
class OpenPricesFormatException extends FormatException {
  const OpenPricesFormatException()
    : super('Open Prices answered in an unexpected shape');
}

/// Whether a row is a product's price or a loose-goods category price.
enum OpenPriceType { product, category }

/// One price row, reduced to what the estimate reads.
class OpenPriceRow {
  const OpenPriceRow({
    required this.id,
    required this.type,
    required this.price,
    this.isDiscounted = false,
    this.priceWithoutDiscount,
    this.pricePer,
    this.currency,
    this.date,
    this.duplicateOf,
    this.locationId,
    this.locationType,
    this.countryCode,
    this.productCode,
    this.categoryTag,
    this.productQuantity,
    this.productQuantityUnit,
    this.productQuantityText,
    this.categoriesTags = const [],
  });

  final int id;
  final OpenPriceType type;
  final double price;
  final bool isDiscounted;
  final double? priceWithoutDiscount;

  /// `KILOGRAM` or `UNIT` on a category row; null on a product row.
  final String? pricePer;
  final String? currency;

  /// Purchase date, `YYYY-MM-DD`.
  final String? date;
  final int? duplicateOf;
  final int? locationId;

  /// `OSM` for a shop, `ONLINE` for a web shop.
  final String? locationType;
  final String? countryCode;
  final String? productCode;
  final String? categoryTag;

  /// The product's pack size in [productQuantityUnit] (`g` or `ml`).
  final double? productQuantity;
  final String? productQuantityUnit;

  /// The pack size as printed ("10 Stück", "7x 70g").
  final String? productQuantityText;
  final List<String> categoriesTags;

  /// Null for a row with a missing or odd field: one bad row is skipped,
  /// never the page.
  static OpenPriceRow? tryParse(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    try {
      final id = json['id'];
      final price = json['price'];
      final type = switch (json['type']) {
        'PRODUCT' => OpenPriceType.product,
        'CATEGORY' => OpenPriceType.category,
        _ => null,
      };
      if (id is! int || price is! num || type == null) return null;
      final location = json['location'];
      final product = json['product'];
      if (location != null && location is! Map<String, dynamic>) return null;
      if (product != null && product is! Map<String, dynamic>) return null;
      final date = _string(json['date']);
      final tags = product is Map<String, dynamic>
          ? product['categories_tags']
          : null;
      if (tags != null && tags is! List) return null;
      return OpenPriceRow(
        id: id,
        type: type,
        price: price.toDouble(),
        isDiscounted: json['price_is_discounted'] == true,
        priceWithoutDiscount: _double(json['price_without_discount']),
        pricePer: _string(json['price_per']),
        currency: _string(json['currency']),
        date: date != null && _dayKey.hasMatch(date) ? date : null,
        duplicateOf: _int(json['duplicate_of']),
        locationId: _int(json['location_id']),
        locationType: _string(location?['type']),
        countryCode: _string(
          location?['osm_address_country_code'],
        )?.toUpperCase(),
        productCode: _string(json['product_code']),
        categoryTag: _string(json['category_tag']),
        productQuantity: _double(product?['product_quantity']),
        productQuantityUnit: _string(product?['product_quantity_unit']),
        productQuantityText: _string(product?['quantity']),
        categoriesTags: [
          for (final tag in (tags as List?) ?? const [])
            if (tag is String) tag,
        ],
      );
    } on _BadField {
      return null;
    }
  }
}

final RegExp _dayKey = RegExp(r'^\d{4}-\d{2}-\d{2}$');

/// A row field of the wrong type.
class _BadField implements Exception {
  const _BadField();
}

String? _string(Object? value) {
  if (value == null) return null;
  if (value is! String) throw const _BadField();
  return value;
}

int? _int(Object? value) {
  if (value == null) return null;
  if (value is! int) throw const _BadField();
  return value;
}

double? _double(Object? value) {
  if (value == null) return null;
  if (value is! num) throw const _BadField();
  return value.toDouble();
}

/// One page of `GET /prices`.
class OpenPricesPage {
  const OpenPricesPage({
    required this.items,
    required this.page,
    required this.pages,
    required this.total,
  });

  /// Throws [OpenPricesFormatException] without an items list or a page
  /// count; single broken rows are dropped.
  factory OpenPricesPage.fromJson(Object? json) {
    if (json is! Map<String, dynamic>) throw const OpenPricesFormatException();
    final items = json['items'];
    final pages = json['pages'];
    final page = json['page'];
    final total = json['total'];
    if (items is! List || pages is! int) {
      throw const OpenPricesFormatException();
    }
    return OpenPricesPage(
      items: [
        for (final item in items)
          if (OpenPriceRow.tryParse(item) case final row?) row,
      ],
      page: page is int ? page : 1,
      pages: pages,
      total: total is int ? total : items.length,
    );
  }

  final List<OpenPriceRow> items;
  final int page, pages, total;
}

/// The three queries an estimate sends. Every one carries the region's
/// currency and geo circle, the window start, the duplicate filter and a
/// stable order (`-id`; `-date` pages unstably).
abstract final class OpenPricesQuery {
  /// The server's cap; a larger size is silently reduced to it.
  static const int pageSize = 100;
  static const int maxCodes = 40;
  static const int maxTags = 30;

  static Map<String, String> _shared(
    PriceRegion region,
    String since,
    int page,
  ) => {
    'currency': region.currency,
    'lat': '${region.lat}',
    'lon': '${region.lon}',
    'radius_km': '${region.radiusKm}',
    'date__gte': since,
    'duplicate_of__isnull': 'true',
    'order_by': '-id',
    'size': '$pageSize',
    'page': '$page',
  };

  /// Loose-goods prices per kilogram or piece.
  static Map<String, String> categoryPrices(
    PriceRegion region,
    String since, {
    int page = 1,
  }) => {..._shared(region, since, page), 'type': 'CATEGORY'};

  /// Prices of exact barcodes (at most [maxCodes]).
  static Map<String, String> barcodes(
    PriceRegion region,
    String since,
    List<String> codes, {
    int page = 1,
  }) => {
    ..._shared(region, since, page),
    'type': 'PRODUCT',
    'product_code__in': codes.join(','),
  };

  /// Product prices in any of [tags] (at most [maxTags]).
  static Map<String, String> tags(
    PriceRegion region,
    String since,
    List<String> tags, {
    int page = 1,
  }) => {
    ..._shared(region, since, page),
    'type': 'PRODUCT',
    'product__categories_tags__overlap': tags.join(','),
  };
}
