import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

import 'package:firestore_client/firestore_client.dart';

/// A stand-in central project id, since this package has no built-in
/// default and most of these tests inject their own [httpClient] and never
/// actually resolve this host.
const _testCentralBaseUrl =
    'https://us-central1-example-central.cloudfunctions.net';

/// A minimal in-memory [CentralSessionStorage], standing in for whatever
/// prefs/file adapter a real caller supplies.
class _MemoryStorage implements CentralSessionStorage {
  String? value;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String v) async => value = v;

  @override
  Future<void> delete() async => value = null;
}

/// A mocked backend for the central handshake: `accounts:signInWithIdp`,
/// its token refresh, and the `getCustomToken` callable.
MockClient _centralBackend({
  int callableStatus = 200,
  Map<String, Object?> callableBody = const {
    'result': {
      'customToken': 'custom-token-1',
      'profile': {'displayName': 'Dana Scout', 'email': 'dana@example.com'},
    },
  },
}) {
  return MockClient((request) async {
    if (request.url.host == 'securetoken.googleapis.com') {
      return http.Response(
        jsonEncode({
          'id_token': 'central-token-refreshed',
          'refresh_token': 'central-refresh-2',
          'expires_in': '3600',
        }),
        200,
      );
    }
    if (request.url.path.endsWith('/getCustomToken')) {
      return http.Response(jsonEncode(callableBody), callableStatus);
    }
    expect(request.url.path, contains('accounts:signInWithIdp'));
    return http.Response(
      jsonEncode({
        'localId': 'central-uid-1',
        'idToken': 'central-token-1',
        'refreshToken': 'central-refresh-1',
        'expiresIn': '3600',
        'displayName': 'Dana Scout',
        'email': 'dana@example.com',
      }),
      200,
    );
  });
}

void main() {
  group('classifyCentralAuthError', () {
    test('PERMISSION_DENIED (REST) means the account is not approved', () {
      expect(
        classifyCentralAuthError('PERMISSION_DENIED'),
        CentralAuthErrorKind.notApproved,
      );
    });

    test('permission-denied (FlutterFire code) also means not approved', () {
      expect(
        classifyCentralAuthError('permission-denied'),
        CentralAuthErrorKind.notApproved,
      );
    });

    test('NOT_FOUND / not-found mean the app is not registered', () {
      expect(
        classifyCentralAuthError('NOT_FOUND'),
        CentralAuthErrorKind.appNotRegistered,
      );
      expect(
        classifyCentralAuthError('not-found'),
        CentralAuthErrorKind.appNotRegistered,
      );
    });

    test('anything else, including null, is unknown', () {
      expect(
          classifyCentralAuthError('INTERNAL'), CentralAuthErrorKind.unknown);
      expect(classifyCentralAuthError(null), CentralAuthErrorKind.unknown);
    });
  });

  group('CentralRestAuthClient', () {
    test('handshake signs in and returns the custom token and profile',
        () async {
      final client = CentralRestAuthClient(
        centralApiKey: 'key',
        centralFunctionsBaseUrl: _testCentralBaseUrl,
        httpClient: _centralBackend(),
      );
      await client.signInWithGoogleIdToken('google-id-token');

      final handshake = await client.handshake('example-app');

      expect(handshake.customToken, 'custom-token-1');
      expect(handshake.profile?.displayName, 'Dana Scout');
      expect(handshake.profile?.email, 'dana@example.com');
    });

    test('handshake with no central session throws unknown', () async {
      final client = CentralRestAuthClient(
        centralApiKey: 'key',
        centralFunctionsBaseUrl: _testCentralBaseUrl,
        httpClient: _centralBackend(),
      );

      await expectLater(
        client.handshake('example-app'),
        throwsA(
          isA<CentralAuthException>().having(
            (e) => e.kind,
            'kind',
            CentralAuthErrorKind.unknown,
          ),
        ),
      );
    });

    test('a PERMISSION_DENIED callable response is not-approved', () async {
      final client = CentralRestAuthClient(
        centralApiKey: 'key',
        centralFunctionsBaseUrl: _testCentralBaseUrl,
        httpClient: _centralBackend(
          callableStatus: 403,
          callableBody: {
            'error': {
              'status': 'PERMISSION_DENIED',
              'message': 'Account not approved.',
            },
          },
        ),
      );
      await client.signInWithGoogleIdToken('google-id-token');

      await expectLater(
        client.handshake('example-app'),
        throwsA(
          isA<CentralAuthException>().having(
            (e) => e.kind,
            'kind',
            CentralAuthErrorKind.notApproved,
          ),
        ),
      );
    });

    test('a NOT_FOUND callable response is app-not-registered', () async {
      final client = CentralRestAuthClient(
        centralApiKey: 'key',
        centralFunctionsBaseUrl: _testCentralBaseUrl,
        httpClient: _centralBackend(
          callableStatus: 404,
          callableBody: {
            'error': {
              'status': 'NOT_FOUND',
              'message': 'No app registered.',
            },
          },
        ),
      );
      await client.signInWithGoogleIdToken('google-id-token');

      await expectLater(
        client.handshake('example-app'),
        throwsA(
          isA<CentralAuthException>().having(
            (e) => e.kind,
            'kind',
            CentralAuthErrorKind.appNotRegistered,
          ),
        ),
      );
    });

    test('an unreachable callable surfaces as a plain exception, not a denial',
        () async {
      final client = CentralRestAuthClient(
        centralApiKey: 'key',
        centralFunctionsBaseUrl: _testCentralBaseUrl,
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/getCustomToken')) {
            throw const SocketException('Failed host lookup');
          }
          if (request.url.host == 'securetoken.googleapis.com') {
            return http.Response(
              jsonEncode({
                'id_token': 'central-token-restored',
                'refresh_token': 'central-refresh-2',
                'expires_in': '3600',
              }),
              200,
            );
          }
          throw StateError('unexpected request: ${request.url}');
        }),
      );
      final restored = await client.restore({
        'uid': 'central-uid-1',
        'refreshToken': 'central-refresh-1',
      });
      expect(restored, isNotNull);

      await expectLater(
        client.handshake('example-app'),
        throwsA(isNot(isA<CentralAuthException>())),
      );
    });

    test('the default constructor builds without an explicit httpClient', () {
      // Boundedness of the default client is covered by
      // timeout_http_client_test.dart; this only confirms the constructor
      // does not require one.
      final client = CentralRestAuthClient(
        centralApiKey: 'key',
        centralFunctionsBaseUrl: _testCentralBaseUrl,
      );
      addTearDown(client.close);
    });

    test(
        'a 200 with no result shape throws CentralAuthException, not a '
        'TypeError', () async {
      final client = CentralRestAuthClient(
        centralApiKey: 'key',
        centralFunctionsBaseUrl: _testCentralBaseUrl,
        httpClient: MockClient((request) async => http.Response('{}', 200)),
      );
      addTearDown(client.close);

      await expectLater(
        client.getCustomToken('bearer', 'example-app'),
        throwsA(isA<CentralAuthException>()),
      );
    });

    test(
        'a 200 that is not valid JSON throws CentralAuthException, not '
        'FirebaseAuthException', () async {
      final client = CentralRestAuthClient(
        centralApiKey: 'key',
        centralFunctionsBaseUrl: _testCentralBaseUrl,
        httpClient:
            MockClient((request) async => http.Response('not json{', 200)),
      );
      addTearDown(client.close);

      await expectLater(
        client.getCustomToken('bearer', 'example-app'),
        throwsA(isA<CentralAuthException>()),
      );
    });

    test('disables redirect-following even with an injected httpClient',
        () async {
      http.BaseRequest? seen;
      final client = CentralRestAuthClient(
        centralApiKey: 'key',
        centralFunctionsBaseUrl: _testCentralBaseUrl,
        httpClient: MockClient((request) async {
          seen = request;
          return http.Response(
            jsonEncode({
              'result': {'customToken': 'custom-token-1'},
            }),
            200,
          );
        }),
      );
      addTearDown(client.close);

      await client.getCustomToken('bearer', 'example-app');

      expect(seen!.followRedirects, isFalse);
    });

    test('close() does not close a caller-supplied httpClient', () async {
      final shared = MockClient((request) async => http.Response('{}', 200));
      final client = CentralRestAuthClient(
        centralApiKey: 'key',
        centralFunctionsBaseUrl: _testCentralBaseUrl,
        httpClient: shared,
      );

      client.close();

      // A closed MockClient still throws on further use; this only has to
      // not throw here, proving close() left `shared` usable.
      await shared.get(Uri.parse('https://example.com'));
    });
  });

  group('runCentralApprovalRecheck', () {
    late CentralRestAuthClient client;
    late _MemoryStorage storage;
    int denialCount = 0;
    bool approvedCalled = false;

    setUp(() {
      denialCount = 0;
      approvedCalled = false;
      storage = _MemoryStorage();
    });

    Future<int> onDenied() async => ++denialCount;
    Future<void> onApproved() async => approvedCalled = true;

    test('no stored session', () async {
      client = CentralRestAuthClient(
        centralApiKey: 'key',
        centralFunctionsBaseUrl: _testCentralBaseUrl,
        httpClient: _centralBackend(),
      );
      final outcome = await runCentralApprovalRecheck(
        client: client,
        storage: storage,
        appKey: 'example-app',
        denialsBeforeSignOut: 2,
        onApproved: onApproved,
        onDenied: onDenied,
      );
      expect(outcome, CentralRecheckOutcome.noStoredSession);
    });

    test('approved re-check rotates and stores the session', () async {
      final signedIn = CentralRestAuthClient(
        centralApiKey: 'key',
        centralFunctionsBaseUrl: _testCentralBaseUrl,
        httpClient: _centralBackend(),
      );
      await signedIn.signInWithGoogleIdToken('google-id-token');
      storage.value = jsonEncode(signedIn.toJson());

      client = CentralRestAuthClient(
        centralApiKey: 'key',
        centralFunctionsBaseUrl: _testCentralBaseUrl,
        httpClient: _centralBackend(),
      );
      final outcome = await runCentralApprovalRecheck(
        client: client,
        storage: storage,
        appKey: 'example-app',
        denialsBeforeSignOut: 2,
        onApproved: onApproved,
        onDenied: onDenied,
      );

      expect(outcome, CentralRecheckOutcome.approved);
      expect(approvedCalled, isTrue);
      expect(storage.value, isNotNull);
    });

    test('a revoked refresh token ends the session', () async {
      storage.value = jsonEncode({'uid': 'u', 'refreshToken': 'dead'});
      client = CentralRestAuthClient(
        centralApiKey: 'key',
        centralFunctionsBaseUrl: _testCentralBaseUrl,
        httpClient: MockClient(
          (_) async => http.Response('{"error":"revoked"}', 400),
        ),
      );

      final outcome = await runCentralApprovalRecheck(
        client: client,
        storage: storage,
        appKey: 'example-app',
        denialsBeforeSignOut: 2,
        onApproved: onApproved,
        onDenied: onDenied,
      );

      expect(outcome, CentralRecheckOutcome.sessionRevoked);
      expect(storage.value, isNull);
    });

    test('a single denial is pending until the threshold', () async {
      final signedIn = CentralRestAuthClient(
        centralApiKey: 'key',
        centralFunctionsBaseUrl: _testCentralBaseUrl,
        httpClient: _centralBackend(),
      );
      await signedIn.signInWithGoogleIdToken('google-id-token');
      storage.value = jsonEncode(signedIn.toJson());

      client = CentralRestAuthClient(
        centralApiKey: 'key',
        centralFunctionsBaseUrl: _testCentralBaseUrl,
        httpClient: _centralBackend(
          callableStatus: 403,
          callableBody: {
            'error': {'status': 'PERMISSION_DENIED', 'message': 'x'},
          },
        ),
      );

      final outcome = await runCentralApprovalRecheck(
        client: client,
        storage: storage,
        appKey: 'example-app',
        denialsBeforeSignOut: 2,
        onApproved: onApproved,
        onDenied: onDenied,
      );

      expect(outcome, CentralRecheckOutcome.deniedPending);
      expect(denialCount, 1);
    });

    test('denials reaching the threshold end the session', () async {
      final signedIn = CentralRestAuthClient(
        centralApiKey: 'key',
        centralFunctionsBaseUrl: _testCentralBaseUrl,
        httpClient: _centralBackend(),
      );
      await signedIn.signInWithGoogleIdToken('google-id-token');
      storage.value = jsonEncode(signedIn.toJson());

      client = CentralRestAuthClient(
        centralApiKey: 'key',
        centralFunctionsBaseUrl: _testCentralBaseUrl,
        httpClient: _centralBackend(
          callableStatus: 403,
          callableBody: {
            'error': {'status': 'PERMISSION_DENIED', 'message': 'x'},
          },
        ),
      );
      denialCount = 1; // Yesterday's first denial already happened.

      final outcome = await runCentralApprovalRecheck(
        client: client,
        storage: storage,
        appKey: 'example-app',
        denialsBeforeSignOut: 2,
        onApproved: onApproved,
        onDenied: onDenied,
      );

      expect(outcome, CentralRecheckOutcome.deniedFinal);
      expect(denialCount, 2);
    });

    test('an unreachable central platform defers rather than denies', () async {
      storage.value = jsonEncode({'uid': 'u', 'refreshToken': 'r'});
      client = CentralRestAuthClient(
        centralApiKey: 'key',
        centralFunctionsBaseUrl: _testCentralBaseUrl,
        httpClient: MockClient((_) async {
          throw const SocketException('Failed host lookup');
        }),
      );

      final outcome = await runCentralApprovalRecheck(
        client: client,
        storage: storage,
        appKey: 'example-app',
        denialsBeforeSignOut: 2,
        onApproved: onApproved,
        onDenied: onDenied,
      );

      expect(outcome, CentralRecheckOutcome.deferred);
      expect(denialCount, 0);
    });

    test('a malformed stored payload is revoked, not deferred', () async {
      storage.value = 'not json{';
      client = CentralRestAuthClient(
        centralApiKey: 'key',
        centralFunctionsBaseUrl: _testCentralBaseUrl,
        httpClient: _centralBackend(),
      );

      final outcome = await runCentralApprovalRecheck(
        client: client,
        storage: storage,
        appKey: 'example-app',
        denialsBeforeSignOut: 2,
        onApproved: onApproved,
        onDenied: onDenied,
      );

      expect(outcome, CentralRecheckOutcome.sessionRevoked);
      expect(storage.value, isNull);
    });

    test('a stored payload with the wrong field types is revoked too',
        () async {
      // Valid JSON, wrong shape: restore() only discovers this by throwing
      // when it casts 'uid' to a String.
      storage.value = jsonEncode({'uid': 12345, 'refreshToken': 'r'});
      client = CentralRestAuthClient(
        centralApiKey: 'key',
        centralFunctionsBaseUrl: _testCentralBaseUrl,
        httpClient: _centralBackend(),
      );

      final outcome = await runCentralApprovalRecheck(
        client: client,
        storage: storage,
        appKey: 'example-app',
        denialsBeforeSignOut: 2,
        onApproved: onApproved,
        onDenied: onDenied,
      );

      expect(outcome, CentralRecheckOutcome.sessionRevoked);
      expect(storage.value, isNull);
    });
  });

  group('CentralRestAuthClient origin validation', () {
    test('rejects a base URL that is not https', () {
      expect(
        () => CentralRestAuthClient(
          centralApiKey: 'key',
          centralFunctionsBaseUrl: 'http://evil.example.com',
        ),
        throwsArgumentError,
      );
    });

    test('rejects loopback: tests use a mock client, not http', () {
      expect(
        () => CentralRestAuthClient(
          centralApiKey: 'key',
          centralFunctionsBaseUrl: 'http://localhost:8080',
        ),
        throwsArgumentError,
      );
    });

    test('rejects a base URL with a query or fragment', () {
      expect(
        () => CentralRestAuthClient(
          centralApiKey: 'key',
          centralFunctionsBaseUrl:
              'https://us-central1-proj.cloudfunctions.net?x=1',
        ),
        throwsArgumentError,
      );
      expect(
        () => CentralRestAuthClient(
          centralApiKey: 'key',
          centralFunctionsBaseUrl:
              'https://us-central1-proj.cloudfunctions.net#frag',
        ),
        throwsArgumentError,
      );
    });

    test('rejects an https URL with no host', () {
      expect(
        () => CentralRestAuthClient(
          centralApiKey: 'key',
          centralFunctionsBaseUrl: 'https:///functions',
        ),
        throwsArgumentError,
      );
    });

    test('normalizes a trailing slash on the base URL', () async {
      Uri? calledUri;
      final client = CentralRestAuthClient(
        centralApiKey: 'key',
        centralFunctionsBaseUrl: 'https://example.com/',
        httpClient: MockClient((request) async {
          calledUri = request.url;
          return http.Response(
            jsonEncode({
              'result': {'customToken': 'custom-token-1'},
            }),
            200,
          );
        }),
      );
      addTearDown(client.close);

      await client.getCustomToken('bearer', 'example-app');

      expect(calledUri, Uri.parse('https://example.com/getCustomToken'));
    });

    test('allows an explicit https endpoint', () {
      expect(
        () => CentralRestAuthClient(
          centralApiKey: 'key',
          centralFunctionsBaseUrl: _testCentralBaseUrl,
        ),
        returnsNormally,
      );
    });
  });

  group('central platform configuration', () {
    // Build-time defines, so any team can point this package at their own
    // central project without forking it. There is no built-in default.
    test('has no built-in central project', () {
      expect(centralProjectId, isEmpty);
    });

    test('throws when unconfigured and no explicit base URL is given', () {
      expect(
        () => CentralRestAuthClient(centralApiKey: 'key'),
        throwsArgumentError,
      );
    });

    test('an explicit base URL works without CENTRAL_PROJECT_ID', () {
      expect(
        () => CentralRestAuthClient(
          centralApiKey: 'key',
          centralFunctionsBaseUrl:
              'https://us-central1-example-central.cloudfunctions.net',
        ),
        returnsNormally,
      );
    });
  });
}
