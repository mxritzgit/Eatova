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
  for (final status in [429, 503]) {
    test(
      'HTTP $status JSON is a service error, not an unknown barcode',
      () async {
        final error = await _lookupFailure(status, '{"error":"unavailable"}');
        expect(error, isA<HttpException>());
        for (final locale in const [Locale('de'), Locale('en')]) {
          final l10n = lookupAppLocalizations(locale);
          expect(
            mealAnalysisErrorMessage(error, 'barcode not found', l10n),
            status == 429
                ? l10n.searchRateLimited
                : l10n.foodSearchUnreachableHint,
          );
        }
      },
    );
  }

  test('HTTP 503 cannot become not-found through a misleading body', () async {
    final error = await _lookupFailure(
      503,
      '{"result":{"id":"product_not_found"}}',
    );
    expect(error, isA<HttpException>());
  });

  test('HTML gateway failure names the service outage', () async {
    final error = await _lookupFailure(502, '<html>Bad Gateway</html>');
    expect(error, isA<HttpException>());
    expect(
      mealAnalysisErrorMessage(error, 'barcode not found', deL10n),
      deL10n.foodSearchUnreachableHint,
    );
  });

  for (final body in [
    '{}',
    '[]',
    'not-json',
    '{"result":{"id":"product_found"}}',
  ]) {
    test('malformed success response is not authoritative: $body', () async {
      final error = await _lookupFailure(200, body);
      expect(error, isA<FormatException>());
      expect(
        mealAnalysisErrorMessage(error, 'barcode not found', deL10n),
        deL10n.foodSearchUnreachableHint,
      );
    });
  }

  test('documented v3 404 remains an unknown barcode', () async {
    final fixture = File('test/services/open_food_facts_v3_not_found.json');
    final error = await _lookupFailure(404, fixture.readAsStringSync());
    expect(error, isA<ProductNotFoundException>());
    expect(
      mealAnalysisErrorMessage(error, 'barcode not found', deL10n),
      'barcode not found',
    );
  });
}
