// A barcode lookup that fails on the service side must not read as "unknown
// barcode": the user would type the product in by hand although only the
// database was down (review 2026-09-08). Real loopback server, real bytes.

import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/services/open_food_facts_product_service.dart';
import 'package:eatova/src/widgets/kcal/meal_analysis_sheet.dart';

Future<Object> _lookupFailure(int status, String body) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(() => server.close(force: true));
  server.listen((request) async {
    request.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(body);
    await request.response.close();
  });
  final service = OpenFoodFactsProductService(
    productBaseUrl: 'http://127.0.0.1:${server.port}/api/v3/product',
  );
  try {
    await service.lookupBarcode('4000000000001');
  } catch (error) {
    return error;
  }
  fail('The lookup must not succeed for this response.');
}

void main() {
  test('HTTP errors are service errors with their own text, never "unknown '
      'barcode" — not even with a not-found body', () async {
    for (final (status, body, text) in <(int, String, String Function(AppLocalizations))>[
      (429, '{"error":"unavailable"}', (l) => l.searchRateLimited),
      (503, '{"error":"unavailable"}', (l) => l.foodSearchUnreachableHint),
      (
        503,
        '{"result":{"id":"product_not_found"}}',
        (l) => l.foodSearchUnreachableHint,
      ),
      (502, '<html>Bad Gateway</html>', (l) => l.foodSearchUnreachableHint),
    ]) {
      final error = await _lookupFailure(status, body);
      expect(error, isA<HttpException>(), reason: '$status $body');
      for (final locale in const [Locale('de'), Locale('en')]) {
        final l10n = lookupAppLocalizations(locale);
        expect(
          mealAnalysisErrorMessage(error, 'barcode not found', l10n),
          text(l10n),
          reason: '$status $body ${locale.languageCode}',
        );
      }
    }
  });

  test('a malformed success response is not authoritative', () async {
    for (final body in [
      '{}',
      '[]',
      'not-json',
      '{"result":{"id":"product_found"}}',
    ]) {
      final error = await _lookupFailure(200, body);
      expect(error, isA<FormatException>(), reason: body);
      expect(
        mealAnalysisErrorMessage(error, 'barcode not found', deL10n),
        deL10n.foodSearchUnreachableHint,
        reason: body,
      );
    }
  });

  test('the documented v3 404 remains an unknown barcode', () async {
    final fixture = File('test/services/open_food_facts_v3_not_found.json');
    final error = await _lookupFailure(404, fixture.readAsStringSync());
    expect(error, isA<ProductNotFoundException>());
    expect(
      mealAnalysisErrorMessage(error, 'barcode not found', deL10n),
      'barcode not found',
    );
  });
}
