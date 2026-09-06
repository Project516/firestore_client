import 'dart:async';

import 'package:http/http.dart' as http;

/// An [http.Client] that bounds every request with a deadline, so a
/// black-holed connection fails with a [TimeoutException] instead of hanging
/// its await forever. The deadline applies both to reaching the response
/// headers and to each gap in the body stream.
///
/// Used as the default HTTP client wherever this package talks to a network
/// endpoint on a caller's behalf (for example [CentralRestAuthClient]), so a
/// bare `http.Client()` -- which never times out on its own -- cannot leave a
/// sign-in hanging forever.
class TimeoutHttpClient extends http.BaseClient {
  TimeoutHttpClient({
    http.Client? inner,
    this.timeout = const Duration(seconds: 20),
  }) : _inner = inner ?? http.Client();

  final http.Client _inner;
  final Duration timeout;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    // A request that carries an Authorization header (every call this
    // package makes) must not auto-follow a redirect: package:http's IO
    // transport forwards Authorization to a same-host or subdomain target,
    // which would hand a bearer token to wherever that redirect points.
    if (request is http.Request) {
      request.followRedirects = false;
    }
    final response = await _inner.send(request).timeout(timeout);
    final boundedBody = response.stream.timeout(
      timeout,
      onTimeout: (sink) {
        sink.addError(
          TimeoutException('Response body stalled for ${request.url}', timeout),
        );
        sink.close();
      },
    );
    return http.StreamedResponse(
      boundedBody,
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
