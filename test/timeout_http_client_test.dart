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
}
