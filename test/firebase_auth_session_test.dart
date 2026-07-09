import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

import 'package:firestore_client/firestore_client.dart';

void main() {
  group('FirebaseAuthSession', () {
    test('signInWithGoogleIdToken adopts the user and token', () async {
      final session = FirebaseAuthSession(
        apiKey: 'key',
        httpClient: MockClient((request) async {
          expect(request.url.path, contains('accounts:signInWithIdp'));
          expect(request.url.queryParameters['key'], 'key');
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['postBody'], contains('providerId=google.com'));
          return http.Response(
            jsonEncode({
              'localId': 'uid-1',
              'idToken': 'fb-token',
              'refreshToken': 'refresh-1',
              'expiresIn': '3600',
              'displayName': 'Dana',
              'email': 'dana@example.com',
            }),
            200,
          );
        }),
      );
      final user = await session.signInWithGoogleIdToken('google-token');
      expect(user.uid, 'uid-1');
      expect(user.displayName, 'Dana');
      expect(session.currentUser?.email, 'dana@example.com');
      expect(await session.getIdToken(), 'fb-token');
    });

    test('getIdToken refreshes an expiring token', () async {
      var now = DateTime.utc(2026, 7, 8, 12);
      var refreshCalls = 0;
      final session = FirebaseAuthSession(
        apiKey: 'key',
        clock: () => now,
        httpClient: MockClient((request) async {
          if (request.url.host == 'securetoken.googleapis.com') {
            refreshCalls++;
            expect(
              request.bodyFields['grant_type'],
              'refresh_token',
            );
            return http.Response(
              jsonEncode({
                'id_token': 'fb-token-2',
                'refresh_token': 'refresh-2',
                'expires_in': '3600',
              }),
              200,
            );
          }
          return http.Response(
            jsonEncode({
              'localId': 'uid-1',
              'idToken': 'fb-token-1',
              'refreshToken': 'refresh-1',
              'expiresIn': '3600',
            }),
            200,
          );
        }),
      );
      await session.signInWithGoogleIdToken('google-token');
      expect(await session.getIdToken(), 'fb-token-1');
      expect(refreshCalls, 0);

      // 59 minutes later the token is within the 5-minute leeway.
      now = now.add(const Duration(minutes: 59));
      expect(await session.getIdToken(), 'fb-token-2');
      expect(refreshCalls, 1);
    });

    test('a failed refresh signs the session out', () async {
      var now = DateTime.utc(2026, 7, 8, 12);
      final session = FirebaseAuthSession(
        apiKey: 'key',
        clock: () => now,
        httpClient: MockClient((request) async {
          if (request.url.host == 'securetoken.googleapis.com') {
            return http.Response('{"error":"revoked"}', 400);
          }
          return http.Response(
            jsonEncode({
              'localId': 'uid-1',
              'idToken': 'fb-token-1',
              'refreshToken': 'refresh-1',
              'expiresIn': '3600',
            }),
            200,
          );
        }),
      );
      await session.signInWithGoogleIdToken('google-token');
      now = now.add(const Duration(hours: 2));
      expect(await session.getIdToken(), isNull);
      expect(session.currentUser, isNull);
    });

    test('restore resumes a persisted session', () async {
      final session = FirebaseAuthSession(
        apiKey: 'key',
        httpClient: MockClient((request) async {
          expect(request.url.host, 'securetoken.googleapis.com');
          return http.Response(
            jsonEncode({
              'id_token': 'fb-token-restored',
              'refresh_token': 'refresh-2',
              'expires_in': '3600',
            }),
            200,
          );
        }),
      );
      final user = await session.restore({
        'uid': 'uid-1',
        'displayName': 'Dana',
        'email': 'dana@example.com',
        'refreshToken': 'refresh-1',
      });
      expect(user?.uid, 'uid-1');
      expect(await session.getIdToken(), 'fb-token-restored');
    });

    test('restore returns null for a revoked refresh token', () async {
      final session = FirebaseAuthSession(
        apiKey: 'key',
        httpClient: MockClient(
          (_) async => http.Response('{"error":"revoked"}', 400),
        ),
      );
      expect(
        await session.restore({'uid': 'u', 'refreshToken': 'dead'}),
        isNull,
      );
    });

    test('sign-in errors surface the API message', () async {
      final session = FirebaseAuthSession(
        apiKey: 'key',
        httpClient: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'error': {'code': 400, 'message': 'INVALID_IDP_RESPONSE'},
            }),
            400,
          ),
        ),
      );
      await expectLater(
        session.signInWithGoogleIdToken('bad'),
        throwsA(
          isA<FirebaseAuthException>()
              .having((e) => e.message, 'message', 'INVALID_IDP_RESPONSE'),
        ),
      );
    });
  });

  group('GoogleDesktopOAuth', () {
    test('codeChallengeFor is deterministic and URL-safe', () {
      final a = GoogleDesktopOAuth.codeChallengeFor('verifier');
      expect(a, GoogleDesktopOAuth.codeChallengeFor('verifier'));
      expect(a, isNot(contains('=')));
      expect(a, isNot(contains('+')));
      expect(a, isNot(contains('/')));
    });

    test('buildAuthUrl carries the PKCE parameters', () {
      final oauth = GoogleDesktopOAuth(
        clientId: 'client-1',
        launcher: (_) async {},
        httpClient: MockClient((_) async => http.Response('', 200)),
      );
      final uri = Uri.parse(
        oauth.buildAuthUrl(
          redirectUri: 'http://127.0.0.1:9999',
          codeChallenge: 'CHAL',
          state: 'STATE',
        ),
      );
      expect(uri.host, 'accounts.google.com');
      expect(uri.queryParameters['client_id'], 'client-1');
      expect(uri.queryParameters['code_challenge'], 'CHAL');
      expect(uri.queryParameters['code_challenge_method'], 'S256');
      expect(uri.queryParameters['scope'], contains('openid'));
    });

    test('exchangeCode returns all tokens and sends the secret', () async {
      final oauth = GoogleDesktopOAuth(
        clientId: 'client-1',
        clientSecret: 'secret-1',
        launcher: (_) async {},
        httpClient: MockClient((request) async {
          expect(request.url.host, 'oauth2.googleapis.com');
          expect(request.bodyFields['client_secret'], 'secret-1');
          expect(request.bodyFields['code_verifier'], 'verifier');
          return http.Response(
            jsonEncode({
              'id_token': 'google-id',
              'access_token': 'google-access',
              'refresh_token': 'google-refresh',
            }),
            200,
          );
        }),
      );
      final tokens = await oauth.exchangeCode(
        code: 'code',
        codeVerifier: 'verifier',
        redirectUri: 'http://127.0.0.1:9999',
      );
      expect(tokens.idToken, 'google-id');
      expect(tokens.accessToken, 'google-access');
      expect(tokens.refreshToken, 'google-refresh');
    });
  });
}
