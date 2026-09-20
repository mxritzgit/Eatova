import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../outbox/outbox_test_helpers.dart';

/// Applies the real stateful RPC fake, then holds its response while a test
/// performs a concurrent database commit. No server result is fabricated.
class ReplayInterleavingServer extends FakeServer {
  Future<void> Function(
    Map<String, dynamic> request,
    Map<String, dynamic> receipt,
  )?
  beforeReceipt;

  @override
  http.Client client() {
    final delegate = super.client();
    addTearDown(delegate.close);
    return MockClient((request) async {
      final response = await http.Response.fromStream(
        await delegate.send(
          http.Request(request.method, request.url)
            ..headers.addAll(request.headers)
            ..bodyBytes = request.bodyBytes,
        ),
      );
      if (request.url.path.endsWith('/rpc/apply_sync_operation') &&
          response.statusCode == 200) {
        await beforeReceipt?.call(
          (jsonDecode(request.body) as Map).cast<String, dynamic>(),
          (jsonDecode(response.body) as Map).cast<String, dynamic>(),
        );
      }
      return response;
    });
  }
}
