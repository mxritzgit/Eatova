import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/services/eatova_http.dart';

// Real loopback requests against a local HttpServer (plain `test()` leaves
// dart:io untouched), plus a pin on the timeout policies.

void main() {
  test(
    'sendTextRequest liest Status und UTF-8-Body, POST-Body kommt an',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));

      String? receivedMethod;
      String? receivedBody;
      server.listen((request) async {
        receivedMethod = request.method;
        receivedBody = await utf8.decoder.bind(request).join();
        request.response
          ..statusCode = 201
          ..headers.contentType = ContentType.json
          ..write('{"gruß":"Müsli"}');
        await request.response.close();
      });

      const policy = HttpTimeoutPolicy(
        connect: Duration(seconds: 5),
        response: Duration(seconds: 5),
        body: Duration(seconds: 5),
      );
      final client = createHttpClient(policy);
      try {
        final response = await sendTextRequest(
          client,
          method: 'POST',
          uri: Uri.parse('http://127.0.0.1:${server.port}/search'),
          policy: policy,
          operation: 'test.post',
          configure: (request) =>
              request.headers.contentType = ContentType.json,
          body: '{"q":"salami"}',
        );

        expect(response.statusCode, 201);
        // UTF-8 decoding: umlauts survive the transport.
        expect(response.body, '{"gruß":"Müsli"}');
        expect(receivedMethod, 'POST');
        expect(receivedBody, '{"q":"salami"}');
      } finally {
        client.close(force: true);
      }
    },
  );

  test(
    'sendTextRequest wirft TimeoutException, wenn die Antwort ausbleibt',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      // Accept the connection but never answer — the hang the old OFF barcode
      // path would have waited out forever.
      server.listen((request) {});

      const policy = HttpTimeoutPolicy(
        connect: Duration(seconds: 5),
        response: Duration(milliseconds: 200),
        body: Duration(seconds: 5),
      );
      final client = createHttpClient(policy);
      try {
        await expectLater(
          sendTextRequest(
            client,
            method: 'GET',
            uri: Uri.parse('http://127.0.0.1:${server.port}/hang'),
            policy: policy,
            operation: 'test.hang',
          ),
          throwsA(isA<TimeoutException>()),
        );
      } finally {
        client.close(force: true);
      }
    },
  );

  test(
    'sendTextRequest folgt Redirects NICHT — der Auth-Header leckt nicht ans '
    'Redirect-Ziel (Sicherheits-Audit 2026-08-09)',
    () async {
      // Target server: records whether a request reaches it and with what.
      final ziel = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => ziel.close(force: true));
      var zielGetroffen = false;
      String? geleakterHeader;
      ziel.listen((request) async {
        zielGetroffen = true;
        geleakterHeader =
            request.headers.value(HttpHeaders.authorizationHeader);
        request.response
          ..statusCode = 200
          ..write('{"ok":true}');
        await request.response.close();
      });

      final quelle = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => quelle.close(force: true));
      quelle.listen((request) async {
        request.response
          ..statusCode = 302
          ..headers.set(HttpHeaders.locationHeader,
              'http://127.0.0.1:${ziel.port}/klau')
          ..close();
      });

      const policy = HttpTimeoutPolicy(
        connect: Duration(seconds: 5),
        response: Duration(seconds: 5),
        body: Duration(seconds: 5),
      );
      final client = createHttpClient(policy);
      try {
        final response = await sendTextRequest(
          client,
          method: 'GET',
          uri: Uri.parse('http://127.0.0.1:${quelle.port}/start'),
          policy: policy,
          operation: 'test.redirect',
          configure: (request) => request.headers
              .set(HttpHeaders.authorizationHeader, 'Bearer geheim-jwt'),
        );

        // The redirect is NOT followed: the caller sees the 302 itself.
        expect(response.statusCode, 302);
        expect(zielGetroffen, isFalse,
            reason: 'der Token-tragende Request darf das Redirect-Ziel nie '
                'erreichen');
        expect(geleakterHeader, isNull);
      } finally {
        client.close(force: true);
      }
    },
  );

  test('Timeout-Policies behalten die abgestimmten Werte', () {
    // The mirror stays aggressively fast — the OFF fallback sits behind it.
    expect(HttpTimeoutPolicy.mirror.connect, const Duration(seconds: 4));
    expect(HttpTimeoutPolicy.mirror.response, const Duration(seconds: 6));
    expect(HttpTimeoutPolicy.mirror.body, const Duration(seconds: 6));

    expect(HttpTimeoutPolicy.openFoodFacts.connect, const Duration(seconds: 8));
    expect(
      HttpTimeoutPolicy.openFoodFacts.response,
      const Duration(seconds: 12),
    );
    expect(HttpTimeoutPolicy.openFoodFacts.body, const Duration(seconds: 12));

    // analyze-meal: 15/60/15 — the client outlasts the edge function (45 s).
    expect(HttpTimeoutPolicy.mealAnalysis.connect, const Duration(seconds: 15));
    expect(
      HttpTimeoutPolicy.mealAnalysis.response,
      const Duration(seconds: 60),
    );
    expect(HttpTimeoutPolicy.mealAnalysis.body, const Duration(seconds: 15));
  });
}
