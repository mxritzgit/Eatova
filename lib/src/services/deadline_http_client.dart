import 'dart:async';

import 'package:http/http.dart' as http;

/// Fails one request with [TimeoutException] when its response headers or
/// body stall past [deadline]; GoTrue reports that as a network error.
///
/// With [bounds], only matching requests get the deadline. All others reach
/// [_inner] unchanged, so their own budgets and abort triggers stay in charge.
class DeadlineHttpClient extends http.BaseClient {
  DeadlineHttpClient(
    this._inner,
    this.deadline, {
    bool Function(Uri url)? bounds,
  }) : _bounds = bounds;

  final http.Client _inner;
  final Duration deadline;
  final bool Function(Uri url)? _bounds;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (_bounds case final bounds? when !bounds(request.url)) {
      return _inner.send(request);
    }
    final response = await _inner.send(request).timeout(deadline);
    return http.StreamedResponse(
      response.stream.timeout(deadline),
      response.statusCode,
      contentLength: response.contentLength,
      request: response.request,
      headers: response.headers,
      isRedirect: response.isRedirect,
      persistentConnection: response.persistentConnection,
      reasonPhrase: response.reasonPhrase,
    );
  }

  @override
  void close() => _inner.close();
}
