import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/services/eatova_http.dart';

// Tests fuer die gemeinsame dart:io-HTTP-Schicht (eatova_http.dart):
// echte Loopback-Requests gegen einen lokalen HttpServer (kein Binding,
// kein flutter_test-HttpOverrides-Mock — plain `test()` laesst dart:io
// unangetastet) plus ein Pin auf die verifizierten Timeout-Policies.

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
        // UTF-8-Dekodierung: Umlaute ueberleben den Transport.
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
      // Verbindung annehmen, aber nie antworten — genau der Haenger, den die
      // :99-Stelle im alten OFF-Barcode-Pfad endlos ausgesessen haette.
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
      // Ziel-Server: protokolliert, ob ihn ueberhaupt ein Request erreicht,
      // und ob er dabei den Authorization-Header traegt.
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

      // Quell-Server: antwortet mit 302 auf den Ziel-Server (Cross-Origin).
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

        // Der Redirect wird NICHT gefolgt: der Aufrufer sieht den 302 selbst.
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
    // Mirror bleibt aggressiv-schnell — der OFF-Fallback haengt dahinter.
    expect(HttpTimeoutPolicy.mirror.connect, const Duration(seconds: 4));
    expect(HttpTimeoutPolicy.mirror.response, const Duration(seconds: 6));
    expect(HttpTimeoutPolicy.mirror.body, const Duration(seconds: 6));

    expect(HttpTimeoutPolicy.openFoodFacts.connect, const Duration(seconds: 8));
    expect(
      HttpTimeoutPolicy.openFoodFacts.response,
      const Duration(seconds: 12),
    );
    expect(HttpTimeoutPolicy.openFoodFacts.body, const Duration(seconds: 12));

    // analyze-meal: 15/60/15 — der Client haelt laenger durch als die
    // Edge Function (45 s serverseitig).
    expect(HttpTimeoutPolicy.mealAnalysis.connect, const Duration(seconds: 15));
    expect(
      HttpTimeoutPolicy.mealAnalysis.response,
      const Duration(seconds: 60),
    );
    expect(HttpTimeoutPolicy.mealAnalysis.body, const Duration(seconds: 15));
  });
}
