import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/described_meal.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_request.dart';
import 'package:eatova/src/services/eatova_http.dart';
import 'package:eatova/src/services/meal_analyzer.dart';
import 'package:eatova/src/services/meal_describer.dart';

// EdgeFunctionMealDescriber against a loopback HttpServer, like the photo
// analyzer's wire test (F4-05): same endpoint, headers, error family and
// cancellation, with the describe-mode body.

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

  void html(int status) {
    handler = (request) async {
      request.response
        ..statusCode = status
        ..headers.contentType = ContentType.html
        ..write('<html><body><h1>$status</h1></body></html>');
      await request.response.close();
    };
  }

  /// Holds the request open until [release] completes.
  Completer<void> hold() {
    final release = Completer<void>();
    handler = (request) async {
      await release.future;
      try {
        request.response.statusCode = 200;
        await request.response.close();
      } catch (_) {
        // Client already gone.
      }
    };
    return release;
  }
}

EdgeFunctionMealDescriber _describer(
  _Loopback loopback, {
  String? token = 'jwt-123',
  HttpTimeoutPolicy policy = const HttpTimeoutPolicy(
    connect: Duration(seconds: 5),
    response: Duration(seconds: 5),
    body: Duration(seconds: 5),
  ),
}) => EdgeFunctionMealDescriber(
  baseUrl: loopback.baseUrl,
  anonKey: 'anon-key',
  tokenProvider: () => token,
  policy: policy,
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

Future<void> _untilSeen(_Loopback loopback) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (loopback.seen.isEmpty) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Request kam innerhalb von 5 s nicht am Loopback-Server an');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

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
        },
      });

      final meal = await _describer(loopback).describe(
        '  Nutella mit einer\nScheibe Toast\u0007 von Lidl  ',
        language: 'de',
      );

      expect(meal.base.mealName, 'Nutella-Toast');
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

  test('401 -> MealAnalysisReauthRequired', () async {
    loopback.json(401, <String, Object?>{'error': 'invalid_user_token'});
    await expectLater(
      _describer(loopback).describe('Ein Apfel', language: 'de'),
      throwsA(isA<MealAnalysisReauthRequired>()),
    );
  });

  test('429 JSON -> MealAnalysisRateLimited mit resetAt', () async {
    loopback.json(429, <String, Object?>{
      'error': 'rate_limited',
      'rateLimit': <String, Object?>{'resetAt': '2026-10-10T15:30:00.000Z'},
    });
    await expectLater(
      _describer(loopback).describe('Ein Apfel', language: 'de'),
      throwsA(
        isA<MealAnalysisRateLimited>().having(
          (e) => e.resetAt,
          'resetAt',
          DateTime.utc(2026, 10, 10, 15, 30),
        ),
      ),
    );
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

  test('502 HTML (Gateway) -> MealAnalysisServerError http_502', () async {
    loopback.html(502);
    await expectLater(
      _describer(loopback).describe('Ein Apfel', language: 'de'),
      throwsA(
        isA<MealAnalysisServerError>().having(
          (e) => e.code,
          'code',
          'http_502',
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

  test(
    'ohne Session-Token -> MealAnalysisReauthRequired ohne Request',
    () async {
      await expectLater(
        _describer(loopback, token: null).describe('Ein Apfel', language: 'de'),
        throwsA(isA<MealAnalysisReauthRequired>()),
      );
      expect(loopback.seen, isEmpty);
    },
  );

  test('keine Antwort -> TimeoutException (Antwort-Phase)', () async {
    final release = loopback.hold();
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
    await expectLater(
      _describer(
        loopback,
        policy: const HttpTimeoutPolicy(
          connect: Duration(seconds: 5),
          response: Duration(milliseconds: 300),
          body: Duration(seconds: 5),
        ),
      ).describe('Ein Apfel', language: 'de'),
      throwsA(isA<TimeoutException>()),
    );
  });

  test(
    'cancel() waehrend des Requests -> MealAnalysisCancelled sofort',
    () async {
      final release = loopback.hold();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      final cancellation = MealAnalysisCancellation();
      final future = _describer(
        loopback,
      ).describe('Ein Apfel', language: 'de', cancellation: cancellation);

      await _untilSeen(loopback);
      final stopwatch = Stopwatch()..start();
      cancellation.cancel();

      await expectLater(future, throwsA(isA<MealAnalysisCancelled>()));
      expect(
        stopwatch.elapsed,
        lessThan(const Duration(seconds: 2)),
        reason: 'der geschlossene Client darf nicht auf den Timeout warten',
      );
    },
  );

  test('bereits gecancelt -> MealAnalysisCancelled ohne Request', () async {
    final cancellation = MealAnalysisCancellation()..cancel();
    await expectLater(
      _describer(
        loopback,
      ).describe('Ein Apfel', language: 'de', cancellation: cancellation),
      throwsA(isA<MealAnalysisCancelled>()),
    );
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

  group('parseDescribeMealResponse', () {
    test('liest das result-Objekt', () {
      final meal = parseDescribeMealResponse(
        200,
        jsonEncode(<String, Object?>{'result': _okResult}),
      );
      expect(meal, isA<DescribedMeal>());
      expect(meal.items.single.name, 'Nutella');
    });

    test('result fehlt -> invalid_result', () {
      expect(
        () => parseDescribeMealResponse(200, '{"result":null}'),
        throwsA(
          isA<MealAnalysisServerError>().having(
            (e) => e.code,
            'code',
            'invalid_result',
          ),
        ),
      );
    });
  });
}
