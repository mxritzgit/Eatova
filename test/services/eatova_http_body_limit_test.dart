import 'dart:io';

import 'package:eatova/src/services/eatova_http.dart';
import 'package:flutter_test/flutter_test.dart';

// Loopback requests against a local HttpServer; no external network.

const _policy = HttpTimeoutPolicy(
  connect: Duration(seconds: 5),
  response: Duration(seconds: 5),
  body: Duration(seconds: 5),
);

Future<HttpServer> _serve(void Function(HttpResponse response) answer) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(() => server.close(force: true));
  server.listen((request) async {
    answer(request.response);
    await request.response.close();
  });
  return server;
}

Future<HttpTextResponse> _get(HttpServer server, {required int limit}) async {
  final client = createHttpClient(_policy);
  addTearDown(() => client.close(force: true));
  return sendTextRequest(
    client,
    method: 'GET',
    uri: Uri.parse('http://127.0.0.1:${server.port}/body'),
    policy: _policy,
    operation: 'test.limit',
    maxBodyBytes: limit,
  );
}

void main() {
  test('a streamed body beyond the limit is rejected', () async {
    final server = await _serve((response) {
      // Chunked: no Content-Length announces the size.
      for (var i = 0; i < 8; i++) {
        response.write('x' * 512);
      }
    });
    await expectLater(
      _get(server, limit: 1024),
      throwsA(
        isA<HttpResponseTooLargeException>().having(
          (error) => error.maxBytes,
          'maxBytes',
          1024,
        ),
      ),
    );
  });

  test('an announced Content-Length beyond the limit is rejected', () async {
    final server = await _serve((response) {
      response
        ..contentLength = 2048
        ..write('y' * 2048);
    });
    await expectLater(
      _get(server, limit: 1024),
      throwsA(isA<HttpResponseTooLargeException>()),
    );
  });

  test('a body of exactly the limit is still decoded as UTF-8', () async {
    // 'ü' is two bytes: 511 of them plus two ASCII bytes make 1024 bytes.
    final text = '${'ü' * 511}ok';
    final server = await _serve((response) {
      response.headers.contentType = ContentType.text;
      response.write(text);
    });
    final result = await _get(server, limit: 1024);
    expect(result.statusCode, 200);
    expect(result.body, text);
  });

  test('the default limit stays generous for small JSON endpoints', () {
    expect(maxHttpResponseBytes, 4 * 1024 * 1024);
    expect(
      const HttpResponseTooLargeException(10).toString(),
      'HTTP response exceeds 10 bytes',
    );
  });
}
