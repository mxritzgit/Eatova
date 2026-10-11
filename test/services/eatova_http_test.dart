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
    'total deckelt die SUMME der Phasen (Review P10-02)',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) {});

      // Every phase generous, the sum tight: without `total` this request
      // would sit here for the 30 s the three phases add up to.
      const policy = HttpTimeoutPolicy(
        connect: Duration(seconds: 10),
        response: Duration(seconds: 10),
        body: Duration(seconds: 10),
        total: Duration(milliseconds: 200),
      );
      final client = createHttpClient(policy);
      final uhr = Stopwatch()..start();
      try {
        await expectLater(
          sendTextRequest(
            client,
            method: 'GET',
            uri: Uri.parse('http://127.0.0.1:${server.port}/hang'),
            policy: policy,
            operation: 'test.total',
          ),
          throwsA(isA<TimeoutException>()),
        );
      } finally {
        uhr.stop();
        client.close(force: true);
      }
      expect(uhr.elapsed, lessThan(const Duration(seconds: 5)));
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

    // Review P10-02: the phases run one after another, so their SUM is what a
    // request costs. `total` is the ceiling on that sum, and it has to be
    // BELOW the sum or it is decoration.
    expect(HttpTimeoutPolicy.mirror.total, const Duration(seconds: 10));
    expect(HttpTimeoutPolicy.openFoodFacts.total, const Duration(seconds: 20));
    // P10-02b: the photo path had `total` = the phase sum (15+60+15 = 90 s),
    // i.e. a field that could never fire. Every policy's ceiling now really is
    // one.
    expect(HttpTimeoutPolicy.mealAnalysis.total, const Duration(seconds: 75));
    for (final policy in const <HttpTimeoutPolicy>[
      HttpTimeoutPolicy.mirror,
      HttpTimeoutPolicy.openFoodFacts,
      HttpTimeoutPolicy.mealAnalysis,
    ]) {
      expect(policy.total, isNotNull);
      expect(policy.total!, lessThan(policy.connect + policy.response +
          policy.body));
    }
  });

  test('Die Foto-Frist bleibt ueber der Serverfrist (P10-02b/P10-02c)', () {
    // Calibration, not taste. analyze-meal aborts itself at
    // ANALYZE_MEAL_REQUEST_BUDGET_MS and the provider call at 45 s, so a client
    // ceiling of 90 s meant waiting at least 35 s on something that was
    // already dead. The new ceiling has to stay ABOVE the server's own
    // deadline plus the connect phase plus the response transfer, otherwise a
    // live-but-slow scan would be cut off by the client.
    //
    // P10-02c: the server budget used to sit HERE as a Dart literal (`const
    // serverBudget = Duration(seconds: 55)`) — the same number as in
    // handler.ts, maintained in only one of the two places. Raising it on the
    // server (the clamp allows up to 120 s) left this test green and cut live
    // analyses off at the 75 s client ceiling: the user reads "this is taking
    // too long" while the function is still working. The number is now READ
    // from handler.ts, so the two move together or the build turns red.
    final serverBudget = _analyzeMealServerBudget();
    const policy = HttpTimeoutPolicy.mealAnalysis;

    expect(
      policy.total!,
      greaterThanOrEqualTo(policy.connect + serverBudget + _antwortTransfer),
      reason:
          'HttpTimeoutPolicy.mealAnalysis.total ist ${policy.total!.inSeconds} '
          's, gebraucht werden aber connect (${policy.connect.inSeconds} s) + '
          'ANALYZE_MEAL_REQUEST_BUDGET_MS aus $_analyzeMealHandlerPfad '
          '(${serverBudget.inSeconds} s) + Antwort-Transfer '
          '(${_antwortTransfer.inSeconds} s) = '
          '${(policy.connect + serverBudget + _antwortTransfer).inSeconds} s. '
          'Darunter schneidet der Client eine noch LEBENDE Analyse ab. '
          'Beide Zahlen gehoeren zusammen bewegt.',
    );
    // ... and below the blind wait it replaces.
    expect(policy.total!, lessThan(const Duration(seconds: 90)));
    // The body phase keeps room for the (small) JSON answer even when connect
    // and the server both use their full budget.
    expect(
      policy.total! - policy.connect - serverBudget,
      greaterThanOrEqualTo(_antwortTransfer),
      reason: 'fuer die (kleine) JSON-Antwort bleibt keine Zeit mehr uebrig',
    );
  });
}

// ---------------------------------------------------------------------------
// P10-02c — the server deadline, read instead of copied
//
// `HttpTimeoutPolicy.mealAnalysis.total` (75 s) is not a taste decision but an
// arithmetic one: connect (15 s) + the edge function's OWN request budget
// (55 s) + the response transfer (5 s). Two of those three live in
// eatova_http.dart, the third one lives in TypeScript. Writing it down twice
// is the failure mode this block exists to prevent — the same class the
// MAX_INPUT_CHARS/MAX_INPUT_BYTES rule in repo_rules_test.dart closes for the
// coach composer: extract, never transcribe.
// ---------------------------------------------------------------------------

/// The file that OWNS the server-side deadline.
const String _analyzeMealHandlerPfad =
    'supabase/functions/analyze-meal/handler.ts';

/// The client's share of [HttpTimeoutPolicy.mealAnalysis.total] beyond connect
/// and the server budget: time for the small JSON answer to come back. Lives
/// nowhere else, so it stays a literal here.
const Duration _antwortTransfer = Duration(seconds: 5);

/// `REQUEST_BUDGET_MS` from [_analyzeMealHandlerPfad], as a [Duration].
///
/// The declaration reads
/// `positiveIntFromEnv('ANALYZE_MEAL_REQUEST_BUDGET_MS', 55_000, 55_000)`,
/// so the DEFAULT is the SECOND argument — what actually ships. The THIRD is
/// the ceiling an operator's env value is clamped to, and this asserts the two
/// are EQUAL: the ceiling was lowered to the client's tolerance, because a
/// budget above it would have the function work on a request nobody waits for.
/// Shortening stays possible (any env value below the default still applies);
/// lengthening has to go through the client first, and then both numbers move
/// together.
///
/// Guarded from the Dart side on purpose. The Deno suite runs in CI with
/// `--allow-env` and deliberately without `--allow-read` (minimal permissions,
/// see .github/workflows/security.yml), so a server-side guard would have had
/// to weaken that for a source read. This file already has handler.ts open.
///
/// Matched by shape (the call, its arguments), not by line number, so moving
/// the declaration around in handler.ts does not turn this red for no reason.
/// `\x27` is the apostrophe — the pattern is a raw string, so it cannot carry
/// one directly.
Duration _analyzeMealServerBudget() {
  final datei = File(_analyzeMealHandlerPfad);
  if (!datei.existsSync()) {
    fail(
      '$_analyzeMealHandlerPfad fehlt (aufgeloest von '
      '${Directory.current.path})',
    );
  }
  final quelle = datei.readAsStringSync();
  final treffer = RegExp(
    r'REQUEST_BUDGET_MS\s*=\s*positiveIntFromEnv\(\s*[\x27"]'
    r'ANALYZE_MEAL_REQUEST_BUDGET_MS[\x27"]\s*,\s*([\d_]+)\s*'
    r'(?:,\s*([\d_]+)\s*)?,?\s*\)',
  ).firstMatch(quelle);
  expect(
    treffer,
    isNotNull,
    reason:
        'ANALYZE_MEAL_REQUEST_BUDGET_MS nicht in $_analyzeMealHandlerPfad '
        'gefunden — ohne die Zahl waere diese Zusicherung blind, und genau '
        'das war P10-02c. Aufruf-Form geaendert? Dann hier den Ausdruck '
        'nachziehen, NICHT die Zahl abschreiben.',
  );
  int zahl(String roh) => int.parse(roh.replaceAll('_', ''));
  final standard = zahl(treffer!.group(1)!);
  expect(
    standard,
    greaterThan(0),
    reason: 'ein Budget von 0 ms waere kein Budget',
  );
  final clampRoh = treffer.group(2);
  expect(
    clampRoh,
    isNotNull,
    reason:
        'der dritte Parameter fehlt. Ohne eigene Obergrenze gilt der Vorgabewert '
        'aus env.ts (EDGE_RATE_LIMIT_MAX_LIMIT), und der hat mit der Wartezeit '
        'des Clients nichts zu tun — ein Betreiber koennte das Budget dann per '
        'Umgebungsvariable beliebig hoch setzen',
  );
  expect(
    zahl(clampRoh!),
    standard,
    reason:
        'die Clamp-Obergrenze in handler.ts ist nicht mehr gleich dem Standard. '
        'Damit laesst sich per Umgebungsvariable ein Serverbudget setzen, auf '
        'das der Client gar nicht mehr wartet: mealAnalysis.total gibt nach '
        '${HttpTimeoutPolicy.mealAnalysis.total?.inSeconds} s auf, davon gehen '
        '${HttpTimeoutPolicy.mealAnalysis.connect.inSeconds} s Verbindungsaufbau '
        'und ${_antwortTransfer.inSeconds} s Antwort-Transfer ab. '
        'Die Function arbeitet dann an einer Anfrage weiter, der niemand mehr '
        'zuhoert — der Nutzer sieht eine Zeitueberschreitung UND der '
        'Provider-Slot ist verbraucht. KUERZEN bleibt erlaubt (jeder Wert unter '
        'dem Standard greift weiterhin); verlaengern muss ueber '
        'HttpTimeoutPolicy.mealAnalysis.total gehen, und dann wandern beide '
        'Zahlen gemeinsam',
  );
  return Duration(milliseconds: standard);
}
