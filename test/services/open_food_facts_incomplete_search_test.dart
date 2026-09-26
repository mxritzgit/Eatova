import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/services/fallback_product_service.dart';
import 'package:eatova/src/services/open_food_facts_product_service.dart';

class _EmptyMirror implements ProductLookupService {
  @override
  Future<MealAnalysisResult> lookupBarcode(String barcode) =>
      throw UnimplementedError();

  @override
  Future<List<ProductSearchResult>> searchProducts(String query) async => [];
}

void main() {
  test(
    'a timed-out second catalog is not cached as a definitive miss',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final worldStarted = Completer<void>();
      final worldFinished = Completer<void>();
      final releaseWorld = Completer<void>();
      server.listen((request) async {
        final isWorld = request.uri.path == '/world';
        if (isWorld) {
          if (!worldStarted.isCompleted) worldStarted.complete();
          await releaseWorld.future;
        }
        try {
          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType.json
            ..add(utf8.encode('{"products":[]}'));
          await request.response.close();
        } on IOException {
          // The request deadline closes the client before the held response.
        } finally {
          if (isWorld && !worldFinished.isCompleted) worldFinished.complete();
        }
      });
      final service = OpenFoodFactsProductService(
        searchBaseUrls: [
          'http://127.0.0.1:${server.port}/de',
          'http://127.0.0.1:${server.port}/world',
        ],
        searchChainBudget: const Duration(seconds: 3),
      );

      final search = FallbackProductService(
        _EmptyMirror(),
        service,
      ).searchProducts('world-only product');
      final timeoutAssertion = expectLater(
        search.timeout(
          const Duration(seconds: 10),
          onTimeout: () => throw StateError('OFF search did not finish'),
        ),
        throwsA(isA<TimeoutException>()),
      );
      try {
        await Future.wait<void>([
          worldStarted.future.timeout(const Duration(seconds: 8)),
          timeoutAssertion,
        ]);
      } finally {
        releaseWorld.complete();
      }
      await worldFinished.future.timeout(const Duration(seconds: 5));
    },
  );
}
