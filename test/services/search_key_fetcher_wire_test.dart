// G2: the Dart client path of `search-key` was only covered by source
// comparison. This runs the real HTTP path (header construction, status code
// branches, JSON contract, budget) over a loopback HttpServer.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/services/search_credentials.dart';

class _KeyServer {
  _KeyServer._(this._server);

  final HttpServer _server;
  final List<HttpHeaders> seenHeaders = <HttpHeaders>[];
  int status = 200;
  Object? body;
  Duration delay = Duration.zero;

  static Future<_KeyServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final ks = _KeyServer._(server);
    server.listen((request) async {
      ks.seenHeaders.add(request.headers);
      if (ks.delay > Duration.zero) {
        await Future<void>.delayed(ks.delay);
      }
      request.response
        ..statusCode = ks.status
        ..headers.contentType = ContentType.json
        ..write(ks.body is String ? ks.body : jsonEncode(ks.body));
      await request.response.close();
    });
    return ks;
  }

  String get baseUrl => 'http://127.0.0.1:${_server.port}';

  Future<void> close() => _server.close(force: true);
}

void main() {
  late _KeyServer server;

  setUp(() async {
    server = await _KeyServer.start();
    server.body = <String, dynamic>{
      'mirrorBaseUrl': 'https://mirror.example',
      'searchKey': 'ms-key-123',
      'ttlSeconds': 600,
    };
  });

  tearDown(() => server.close());

  EdgeFunctionSearchKeyFetcher fetcher({String? token = 'jwt-abc'}) =>
      EdgeFunctionSearchKeyFetcher(
        baseUrl: server.baseUrl,
        anonKey: 'anon-key-test',
        tokenProvider: () => token,
      );

  test('Happy Path: Antwortfelder und Header laufen wirklich ueber die '
      'Leitung', () async {
    final creds = await fetcher().fetch();

    expect(creds, isNotNull);
    expect(creds!.baseUrl, 'https://mirror.example');
    expect(creds.searchKey, 'ms-key-123');
    expect(creds.ttl, const Duration(minutes: 10));

    final headers = server.seenHeaders.single;
    expect(headers.value('apikey'), 'anon-key-test');
    expect(headers.value(HttpHeaders.authorizationHeader), 'Bearer jwt-abc');
  });

  test('ohne Token wird GAR NICHT angefragt — Kaltstart-Fenster heisst '
      '"behalten, was da ist"', () async {
    final creds = await fetcher(token: null).fetch();

    expect(creds, isNull);
    expect(server.seenHeaders, isEmpty,
        reason: 'ein Request ohne Bearer waere ein 401 und reine Last');
  });

  test('Nicht-2xx (fehlendes Server-Secret, 403, 500) liefert null statt zu '
      'werfen', () async {
    server.status = 500;
    expect(await fetcher().fetch(), isNull);
    server.status = 403;
    expect(await fetcher().fetch(), isNull);
  });

  test('kaputtes JSON und fehlende Pflichtfelder liefern null', () async {
    server.body = '<html>Bad Gateway</html>';
    expect(await fetcher().fetch(), isNull);
    server.body = <String, dynamic>{'searchKey': 'nur-eins'};
    expect(await fetcher().fetch(), isNull);
  });

  test('non-https mirrorBaseUrl wird verworfen (Sicherheits-Audit) — kein '
      'Klartext-Mirror, nichts wird gecacht', () async {
    server.body = <String, dynamic>{
      'mirrorBaseUrl': 'http://mirror.example',
      'searchKey': 'ms-key-123',
      'ttlSeconds': 600,
    };
    expect(await fetcher().fetch(), isNull,
        reason: 'ein http-Mirror aus der Server-Antwort darf nicht uebernommen '
            'werden — der Key ginge sonst im Klartext raus');
  });

  test('fehlendes ttlSeconds faellt auf die 12-h-Default-TTL', () async {
    server.body = <String, dynamic>{
      'mirrorBaseUrl': 'https://mirror.example',
      'searchKey': 'ms-key-123',
    };
    final creds = await fetcher().fetch();
    expect(creds!.ttl, const Duration(hours: 12));
  });

  test('das Budget kappt die Wartezeit — eine langsame Antwort wird '
      'verworfen', () async {
    server.delay = const Duration(seconds: 2);
    final creds =
        await fetcher().fetch(budget: const Duration(milliseconds: 100));
    expect(creds, isNull);
  });
}
