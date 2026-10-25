import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/services/meal_analyzer.dart';
import 'package:eatova/src/services/meal_describer.dart';

import '../support/expired_session.dart';

// EdgeFunctionMealDescriber against a loopback HttpServer: the describe-mode
// body and answers. The transport it shares with the photo scan
// (AnalyzeMealTransport: 401, 429, gateway HTML, timeouts, cancellation, the
// token refresh) is pinned in the photo analyzer's wire test,
// test/services/fixlauf_d_meal_analyzer_wire_test.dart.

typedef _Handler = FutureOr<void> Function(HttpRequest request);

class _Loopback {
  _Loopback(this.server);

  final HttpServer server;
  final List<HttpRequest> seen = <HttpRequest>[];
  final List<String> bodies = <String>[];
  _Handler handler = (request) async {
    request.response.statusCode = 500;
    await request.response.close();
  };

  static Future<_Loopback> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final loopback = _Loopback(server);
    server.listen((request) async {
      loopback.seen.add(request);
      loopback.bodies.add(await utf8.decoder.bind(request).join());
      await loopback.handler(request);
    });
    return loopback;
  }

  String get baseUrl => 'http://127.0.0.1:${server.port}';

  Future<void> close() => server.close(force: true);

  void json(int status, Object body) {
    handler = (request) async {
      request.response
        ..statusCode = status
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(body));
      await request.response.close();
    };
  }

  /// 401 unless the request carries [token], else [body] with 200, like the
  /// gateway's JWT check in front of the function.
  void onlyFor(String token, Object body) {
    handler = (request) async {
      final ok = request.headers.value('authorization') == 'Bearer $token';
      request.response
        ..statusCode = ok ? 200 : 401
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(ok ? body : {'error': 'invalid_user_token'}));
      await request.response.close();
    };
  }
}

EdgeFunctionMealDescriber _describer(
  _Loopback loopback, {
  String? token = 'jwt-123',
}) => EdgeFunctionMealDescriber(
  baseUrl: loopback.baseUrl,
  anonKey: 'anon-key',
  tokenProvider: () => token,
);

const Map<String, Object?> _okResult = <String, Object?>{
  'mode': 'describe',
  'mealName': 'Nutella-Toast',
  'caloriesKcal': 146,
  'estimatedGrams': 40,
  'kcalPer100G': 365,
  'proteinG': 3,
  'carbsG': 21,
  'fatG': 6,
  'confidence': 'medium',
  'explanation': '',
  'slotHint': 'breakfast',
  'items': <Object?>[
    <String, Object?>{
      'name': 'Nutella',
      'grams': 15,
      'caloriesKcal': 81,
      'kcalPer100G': 539,
      'proteinG': 0.9,
      'carbsG': 8.6,
      'fatG': 4.6,
      'searchQuery': 'Nutella',
      'brand': 'Ferrero',
      'amountText': null,
      'gramsSource': 'estimated',
    },
  ],
};

void main() {
  late _Loopback loopback;

  setUp(() async {
    loopback = await _Loopback.start();
  });

  tearDown(() => loopback.close());

  test(
    '200 -> DescribedMeal; Header und Body wie vom Server erwartet',
    () async {
      loopback.json(200, <String, Object?>{
        'result': _okResult,
        'requestId': 'r1',
        'rateLimit': <String, Object?>{
          'user': <String, Object?>{'remaining': 3},
          'userDay': <String, Object?>{'limit': 4, 'remaining': 2},
        },
      });

      final meal = await _describer(loopback).describe(
        '  Nutella mit einer\nScheibe Toast\u0007 von Lidl  ',
        language: 'de',
      );

      expect(meal.base.mealName, 'Nutella-Toast');
      // The bucket it shares with the photo scan (PREMIUM.md 4.5).
      expect(mealAnalysisUsageOf(meal)?.used, 2);
      expect(meal.slotHint, MealSlot.breakfast);
      expect(meal.items.single.brand, 'Ferrero');
      final request = loopback.seen.single;
      expect(request.method, 'POST');
      expect(request.uri.path, '/functions/v1/analyze-meal');
      expect(request.headers.value('apikey'), 'anon-key');
      expect(request.headers.value('authorization'), 'Bearer jwt-123');
      expect(request.headers.contentType?.mimeType, 'application/json');
      final body = jsonDecode(loopback.bodies.single) as Map<String, dynamic>;
      expect(body, <String, Object?>{
        'mealText': 'Nutella mit einer Scheibe Toast von Lidl',
        'language': 'de',
      });
    },
  );

  test('422 no_food_in_text -> MealAnalysisServerError mit dem Code', () async {
    loopback.json(422, <String, Object?>{
      'error': 'no_food_in_text',
      'message': 'Kein Essen erkannt.',
    });
    await expectLater(
      _describer(loopback).describe('Hallo Welt', language: 'de'),
      throwsA(
        isA<MealAnalysisServerError>()
            .having((e) => e.statusCode, 'statusCode', 422)
            .having((e) => e.code, 'code', 'no_food_in_text'),
      ),
    );
  });

  test('Refresh liefert ein anderes Konto -> Reauth ohne Request', () async {
    final session = await expiredSession(refreshedUser: 'user-b');
    loopback.onlyFor(session.fresh, <String, Object?>{'result': _okResult});

    await expectLater(
      EdgeFunctionMealDescriber(
        baseUrl: loopback.baseUrl,
        anonKey: 'anon-key',
        auth: session.client.auth,
      ).describe('Toast mit Nutella', language: 'de'),
      throwsA(isA<MealAnalysisReauthRequired>()),
    );
    expect(loopback.seen, isEmpty);
  });

  test('429 ai_budget_exhausted bleibt ein Serverfehler mit Code', () async {
    loopback.json(429, <String, Object?>{'error': 'ai_budget_exhausted'});
    await expectLater(
      _describer(loopback).describe('Ein Apfel', language: 'de'),
      throwsA(
        isA<MealAnalysisServerError>().having(
          (e) => e.code,
          'code',
          'ai_budget_exhausted',
        ),
      ),
    );
  });

  test(
    '200 ohne brauchbaren Posten -> invalid_result, keine FormatException',
    () async {
      loopback.json(200, <String, Object?>{
        'result': <String, Object?>{..._okResult, 'items': <Object?>[]},
      });
      await expectLater(
        _describer(loopback).describe('Ein Apfel', language: 'de'),
        throwsA(
          isA<MealAnalysisServerError>()
              .having((e) => e.code, 'code', 'invalid_result')
              .having((e) => e.statusCode, 'statusCode', 200),
        ),
      );
    },
  );

  test('ungueltiger Text -> invalid_meal_text ohne Request', () async {
    for (final text in <String>['', ' x ', '\n\t', 'a' * 501]) {
      await expectLater(
        _describer(loopback).describe(text, language: 'de'),
        throwsA(
          isA<MealAnalysisServerError>()
              .having((e) => e.code, 'code', 'invalid_meal_text')
              .having((e) => e.statusCode, 'statusCode', 400),
        ),
        reason: '"$text"',
      );
    }
    expect(loopback.seen, isEmpty);
  });

  group('buildDescribeMealBody', () {
    test('normalisiert wie der Server und prueft die Grenzen', () {
      expect(
        buildDescribeMealBody(' Toast\r\n mit\u{202E} Ei', language: 'en'),
        <String, Object?>{'mealText': 'Toast mit Ei', 'language': 'en'},
      );
      expect(isValidMealText('Ei'), isTrue);
      expect(isValidMealText('E'), isFalse);
      expect(isValidMealText('a' * MealDescriber.maxTextLength), isTrue);
      expect(isValidMealText('a' * (MealDescriber.maxTextLength + 1)), isFalse);
      expect(
        isValidMealText(' ${'a' * MealDescriber.maxTextLength}  '),
        isTrue,
        reason: 'gemessen wird nach dem Normalisieren',
      );
    });
  });
}
