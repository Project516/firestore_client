import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import 'package:firestore_client/firestore_client.dart';

/// A client that never responds, standing in for a black-holed connection.
class _HangingClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    return Completer<http.StreamedResponse>().future;
  }

  @override
  void close() {}
}

void main() {
  group('TimeoutHttpClient', () {
    test('bounds a request that never returns headers', () async {
      final client = TimeoutHttpClient(
        inner: _HangingClient(),
        timeout: const Duration(milliseconds: 20),
      );
      await expectLater(
        client.get(Uri.parse('https://example.invalid')),
        throwsA(isA<TimeoutException>()),
      );
    });

    test('defaults to a bare http.Client() as the inner client', () {
      // Constructing without an explicit inner client must not throw; the
      // wrapper still owns and bounds it.
      final client = TimeoutHttpClient(timeout: const Duration(seconds: 1));
      addTearDown(client.close);
      expect(client.timeout, const Duration(seconds: 1));
    });
  });

  test('disables redirect-following so Authorization is never forwarded',
      () async {
    http.BaseRequest? seen;
    final client = TimeoutHttpClient(
      inner: _RecordingClient((request) => seen = request),
      timeout: const Duration(seconds: 1),
    );

    await client.post(
      Uri.parse('https://example.com'),
      headers: {'Authorization': 'Bearer secret'},
    );

    expect(seen!.followRedirects, isFalse);
  });

  test('disables redirect-following on a MultipartRequest too', () async {
    http.BaseRequest? seen;
    final client = TimeoutHttpClient(
      inner: _RecordingClient((request) => seen = request),
      timeout: const Duration(seconds: 1),
    );

    final request = http.MultipartRequest(
      'POST',
      Uri.parse('https://example.com'),
    )..headers['Authorization'] = 'Bearer secret';
    await client.send(request);

    expect(seen!.followRedirects, isFalse);
  });

  test('a response whose body never arrives times out', () async {
    final client = TimeoutHttpClient(
      inner: _StalledBodyClient(),
      timeout: const Duration(milliseconds: 50),
    );
    await expectLater(
      client.get(Uri.parse('https://example.com')),
      throwsA(isA<TimeoutException>()),
    );
  });
}

/// Records the request it was handed and returns an empty 200.
class _RecordingClient extends http.BaseClient {
  _RecordingClient(this.onRequest);

  final void Function(http.BaseRequest request) onRequest;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    onRequest(request);
    return http.StreamedResponse(Stream.value(<int>[]), 200);
  }
}

/// Headers arrive, then the body stalls forever: the case the response-stream
/// deadline covers, distinct from a connection that never answers at all.
class _StalledBodyClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return http.StreamedResponse(StreamController<List<int>>().stream, 200);
  }
}
