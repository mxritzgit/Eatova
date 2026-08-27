import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/meal_analysis_request.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/services/eatova_http.dart';
import 'package:eatova/src/services/meal_analyzer.dart';

// Fix run 2026-08-27, F4-05 / F4-01 / F9-03: EdgeFunctionMealAnalyzer.analyze
// against a loopback HttpServer. Before, URL/anon key were static consts and
// the token came straight from Supabase.instance, so the HTTP path had no
// test at all — and a 429 with an HTML body surfaced as a FormatException.

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

final Uint8List _bytes = Uint8List.fromList(List<int>.filled(64, 7));

MealAnalysisRequest _request({MealAnalysisCancellation? cancellation}) =>
    MealAnalysisRequest(
      imageId: 'photo.jpg',
      imageBytes: _bytes,
      language: 'en',
      cancellation: cancellation,
    );

EdgeFunctionMealAnalyzer _analyzer(
  _Loopback loopback, {
  String? token = 'jwt-123',
  HttpTimeoutPolicy policy = const HttpTimeoutPolicy(
    connect: Duration(seconds: 5),
    response: Duration(seconds: 5),
    body: Duration(seconds: 5),
  ),
}) =>
    EdgeFunctionMealAnalyzer(
      baseUrl: loopback.baseUrl,
      anonKey: 'anon-key',
      tokenProvider: () => token,
      policy: policy,
    );

const Map<String, Object?> _okResult = <String, Object?>{
  'mealName': 'Spaghetti Bolognese',
  'caloriesKcal': 650,
  'estimatedGrams': 400,
  'kcalPer100G': 162.5,
  'proteinG': 30,
  'carbsG': 70,
  'fatG': 25,
  'confidence': 'medium',
  'explanation': 'Ein großer Teller.',
  'items': <Object?>[],
};

void main() {
  late _Loopback loopback;

  setUp(() async {
    loopback = await _Loopback.start();
  });

  tearDown(() => loopback.close());

  test('200 -> Ergebnis; Header und Body wie vom Server erwartet', () async {
    loopback.json(200, <String, Object?>{
      'result': _okResult,
      'requestId': 'r1',
      'rateLimit': <String, Object?>{
        'user': <String, Object?>{'remaining': 3, 'resetAt': '2026-08-27T15:00:00Z'},
      },
    });

    final result = await _analyzer(loopback).analyze(_request());

    expect(result.mealName, 'Spaghetti Bolognese');
    expect(result.caloriesKcal, 650);
    expect(loopback.seen, hasLength(1));
    final request = loopback.seen.single;
    expect(request.method, 'POST');
    expect(request.uri.path, '/functions/v1/analyze-meal');
    expect(request.headers.value('apikey'), 'anon-key');
    expect(request.headers.value('authorization'), 'Bearer jwt-123');
    expect(request.headers.contentType?.mimeType, 'application/json');
    final body = jsonDecode(loopback.bodies.single) as Map<String, dynamic>;
    expect(body['imageBase64'], base64Encode(_bytes));
    expect(body['language'], 'en');
    expect(body['portionHint'], 'normal');
  });

  test('401 -> MealAnalysisReauthRequired', () async {
    loopback.json(401, <String, Object?>{
      'error': 'invalid_user_token',
      'message': 'Bitte erneut anmelden.',
    });
    await expectLater(
      _analyzer(loopback).analyze(_request()),
      throwsA(isA<MealAnalysisReauthRequired>()),
    );
  });

  test('429 JSON -> MealAnalysisRateLimited mit resetAt', () async {
    loopback.json(429, <String, Object?>{
      'error': 'rate_limited',
      'message': 'Zu viele Analysen. Bitte später erneut versuchen.',
      'rateLimit': <String, Object?>{
        'allowed': false,
        'remaining': 0,
        'resetAt': '2026-08-27T15:30:00.000Z',
        'windowSeconds': 3600,
      },
    });
    await expectLater(
      _analyzer(loopback).analyze(_request()),
      throwsA(isA<MealAnalysisRateLimited>().having(
        (e) => e.resetAt,
        'resetAt',
        DateTime.utc(2026, 8, 27, 15, 30),
      )),
    );
  });

  test('429 HTML (Gateway) -> MealAnalysisRateLimited, keine FormatException',
      () async {
    loopback.html(429);
    await expectLater(
      _analyzer(loopback).analyze(_request()),
      throwsA(isA<MealAnalysisRateLimited>()
          .having((e) => e.resetAt, 'resetAt', isNull)),
    );
  });

  test('413 -> MealImageTooLarge', () async {
    loopback.json(413, <String, Object?>{
      'error': 'payload_too_large',
      'message': 'Bild ist zu groß.',
    });
    await expectLater(
      _analyzer(loopback).analyze(_request()),
      throwsA(isA<MealImageTooLarge>()),
    );
  });

  test('502 JSON -> MealAnalysisServerError mit Server-Code', () async {
    loopback.json(502, <String, Object?>{
      'error': 'provider_error',
      'message': 'Analyse konnte nicht abgeschlossen werden.',
    });
    await expectLater(
      _analyzer(loopback).analyze(_request()),
      throwsA(isA<MealAnalysisServerError>()
          .having((e) => e.statusCode, 'statusCode', 502)
          .having((e) => e.code, 'code', 'provider_error')
          .having((e) => e.debugMessage, 'debugMessage',
              'Analyse konnte nicht abgeschlossen werden.')),
    );
  });

  test('502 HTML -> MealAnalysisServerError http_502', () async {
    loopback.html(502);
    await expectLater(
      _analyzer(loopback).analyze(_request()),
      throwsA(isA<MealAnalysisServerError>()
          .having((e) => e.code, 'code', 'http_502')),
    );
  });

  test('200 mit result: null -> MealAnalysisServerError invalid_result',
      () async {
    loopback.json(200, <String, Object?>{'result': null, 'requestId': 'r2'});
    await expectLater(
      _analyzer(loopback).analyze(_request()),
      throwsA(isA<MealAnalysisServerError>()
          .having((e) => e.code, 'code', 'invalid_result')),
    );
  });

  test('keine Antwort -> TimeoutException (Antwort-Phase)', () async {
    final release = loopback.hold();
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
    await expectLater(
      _analyzer(
        loopback,
        policy: const HttpTimeoutPolicy(
          connect: Duration(seconds: 5),
          response: Duration(milliseconds: 300),
          body: Duration(seconds: 5),
        ),
      ).analyze(_request()),
      throwsA(isA<TimeoutException>()),
    );
  });

  test('ohne Session-Token -> MealAnalysisReauthRequired ohne Request',
      () async {
    await expectLater(
      _analyzer(loopback, token: null).analyze(_request()),
      throwsA(isA<MealAnalysisReauthRequired>()),
    );
    expect(loopback.seen, isEmpty);
  });

  test('Bild > 5 MB -> MealImageTooLarge ohne Request', () async {
    final huge = Uint8List(5 * 1000 * 1000 + 1);
    await expectLater(
      _analyzer(loopback).analyze(
        MealAnalysisRequest(imageId: 'big.jpg', imageBytes: huge),
      ),
      throwsA(isA<MealImageTooLarge>()),
    );
    expect(loopback.seen, isEmpty);
  });

  // F4-02: cancel closes the client -> the pending request dies at once
  // instead of holding the socket for up to 60 s. Client-side only: the
  // server has already consumed the rate-limit slot and its provider call
  // runs on regardless (handler.ts) — what is saved is the wait, not quota.
  test('cancel() waehrend des Requests -> MealAnalysisCancelled sofort '
      '(spart Wartezeit, nicht Server-Quota)', () async {
    final release = loopback.hold();
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
    final cancellation = MealAnalysisCancellation();
    final future = _analyzer(loopback)
        .analyze(_request(cancellation: cancellation));

    // Wait until the request reached the server, then abort.
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (loopback.seen.isEmpty) {
      if (DateTime.now().isAfter(deadline)) {
        fail('Request kam innerhalb von 5 s nicht am Loopback-Server an');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final stopwatch = Stopwatch()..start();
    cancellation.cancel();

    await expectLater(future, throwsA(isA<MealAnalysisCancelled>()));
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)),
        reason: 'der geschlossene Client darf nicht auf den Timeout warten');
  });

  test('bereits gecancelt -> MealAnalysisCancelled ohne Request', () async {
    final cancellation = MealAnalysisCancellation()..cancel();
    await expectLater(
      _analyzer(loopback).analyze(_request(cancellation: cancellation)),
      throwsA(isA<MealAnalysisCancelled>()),
    );
    expect(loopback.seen, isEmpty);
  });

  group('parseAnalyzeMealResponse', () {
    test('403 -> Reauth, 200 mit error image_too_large -> TooLarge', () {
      expect(
        () => parseAnalyzeMealResponse(403, '{"error":"forbidden"}'),
        throwsA(isA<MealAnalysisReauthRequired>()),
      );
      expect(
        () => parseAnalyzeMealResponse(400, '{"error":"image_too_large"}'),
        throwsA(isA<MealImageTooLarge>()),
      );
    });

    test('resetAt auch unter rateLimit.user', () {
      expect(
        () => parseAnalyzeMealResponse(
          429,
          '{"rateLimit":{"user":{"resetAt":"2026-08-27T16:00:00Z"}}}',
        ),
        throwsA(isA<MealAnalysisRateLimited>().having(
          (e) => e.resetAt,
          'resetAt',
          DateTime.utc(2026, 8, 27, 16),
        )),
      );
    });

    test('leerer Body mit 500 -> http_500', () {
      expect(
        () => parseAnalyzeMealResponse(500, ''),
        throwsA(isA<MealAnalysisServerError>()
            .having((e) => e.code, 'code', 'http_500')),
      );
    });

    test('gueltiges Ergebnis wird geparst', () {
      final result = parseAnalyzeMealResponse(
        200,
        jsonEncode(<String, Object?>{'result': _okResult}),
      );
      expect(result, isA<MealAnalysisResult>());
      expect(result.estimatedGrams, 400);
    });
  });

  group('MealAnalysisCancellation', () {
    test('register nach cancel laeuft sofort, unregister entfernt', () {
      final cancellation = MealAnalysisCancellation();
      var early = 0;
      var late = 0;
      final unregister = cancellation.register(() => early++);
      unregister();
      cancellation.cancel();
      expect(early, 0, reason: 'abgemeldet');
      cancellation.register(() => late++);
      expect(late, 1, reason: 'nach cancel sofort');
      cancellation.cancel();
      expect(late, 1, reason: 'idempotent');
    });
  });
}
