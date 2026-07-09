import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

/// The tokens returned by a completed Google OAuth flow.
class GoogleTokens {
  const GoogleTokens({
    required this.idToken,
    this.accessToken,
    this.refreshToken,
  });

  final String idToken;
  final String? accessToken;
  final String? refreshToken;
}

/// Native-app Google sign-in for desktop platforms: the standard loopback +
/// PKCE OAuth flow (RFC 8252). Opens the system browser to Google's consent
/// screen, captures the redirect on an ephemeral localhost server, and
/// exchanges the code for tokens.
///
/// Uses `dart:io`, so it does not run on the web. Pair the returned
/// [GoogleTokens.idToken] with `FirebaseAuthSession.signInWithGoogleIdToken`
/// for a Firebase session.
class GoogleDesktopOAuth {
  GoogleDesktopOAuth({
    required this.clientId,
    this.clientSecret = '',
    this.scopes = const ['openid', 'email', 'profile'],
    required Future<void> Function(Uri url) launcher,
    http.Client? httpClient,
  })  : _launch = launcher,
        _http = httpClient ?? http.Client();

  final String clientId;

  /// Google "Desktop app" OAuth clients issue a client secret that the token
  /// endpoint requires even with PKCE. It is not confidential in a native
  /// app; RFC 8252 acknowledges this.
  final String clientSecret;

  final List<String> scopes;
  final Future<void> Function(Uri url) _launch;
  final http.Client _http;

  /// Runs the interactive sign-in flow. [successHtml] is served to the
  /// browser tab after the redirect lands.
  Future<GoogleTokens> signIn({
    String successHtml = '<html><body style="font-family:sans-serif">'
        '<p>Sign-in complete. You can close this tab.</p></body></html>',
  }) async {
    final verifier = randomToken(64);
    final state = randomToken(24);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    try {
      final redirectUri = 'http://127.0.0.1:${server.port}';
      await _launch(
        Uri.parse(
          buildAuthUrl(
            redirectUri: redirectUri,
            codeChallenge: codeChallengeFor(verifier),
            state: state,
          ),
        ),
      );
      final code = await _awaitRedirectCode(server, state, successHtml);
      return exchangeCode(
        code: code,
        codeVerifier: verifier,
        redirectUri: redirectUri,
      );
    } finally {
      await server.close(force: true);
    }
  }

  /// The Google authorization URL for the loopback + PKCE flow.
  String buildAuthUrl({
    required String redirectUri,
    required String codeChallenge,
    required String state,
  }) {
    return Uri.https('accounts.google.com', '/o/oauth2/v2/auth', {
      'client_id': clientId,
      'redirect_uri': redirectUri,
      'response_type': 'code',
      'scope': scopes.join(' '),
      'code_challenge': codeChallenge,
      'code_challenge_method': 'S256',
      'state': state,
      'access_type': 'offline',
    }).toString();
  }

  /// PKCE S256 challenge: base64url(sha256(verifier)), no padding.
  static String codeChallengeFor(String verifier) {
    final digest = sha256.convert(utf8.encode(verifier));
    return base64UrlEncode(digest.bytes).replaceAll('=', '');
  }

  /// A URL-safe random token of [bytes] random bytes.
  static String randomToken(int bytes) {
    final rng = Random.secure();
    final data = List<int>.generate(bytes, (_) => rng.nextInt(256));
    return base64UrlEncode(data).replaceAll('=', '');
  }

  /// Exchanges the authorization code for tokens at Google's token endpoint.
  Future<GoogleTokens> exchangeCode({
    required String code,
    required String codeVerifier,
    required String redirectUri,
  }) async {
    final response = await _http.post(
      Uri.parse('https://oauth2.googleapis.com/token'),
      headers: const {'Content-Type': 'application/x-www-form-urlencoded'},
      body: {
        'code': code,
        'client_id': clientId,
        if (clientSecret.isNotEmpty) 'client_secret': clientSecret,
        'code_verifier': codeVerifier,
        'grant_type': 'authorization_code',
        'redirect_uri': redirectUri,
      },
    );
    if (response.statusCode != 200) {
      throw StateError('Google token exchange failed (${response.statusCode}): '
          '${response.body}');
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final idToken = data['id_token'] as String?;
    if (idToken == null || idToken.isEmpty) {
      throw StateError('Google token response had no id_token.');
    }
    return GoogleTokens(
      idToken: idToken,
      accessToken: data['access_token'] as String?,
      refreshToken: data['refresh_token'] as String?,
    );
  }

  Future<String> _awaitRedirectCode(
    HttpServer server,
    String state,
    String successHtml,
  ) async {
    await for (final request in server) {
      final params = request.uri.queryParameters;
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.html
        ..write(successHtml);
      await request.response.close();
      if (params['error'] != null) {
        throw StateError('Sign-in was cancelled or denied.');
      }
      if (params['state'] != state) {
        throw StateError('Sign-in state mismatch; aborting.');
      }
      final code = params['code'];
      if (code != null && code.isNotEmpty) return code;
    }
    throw StateError('No authorization code was received.');
  }

  void close() {
    _http.close();
  }
}
