import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// The signed-in Firebase user, as reported by the Identity Toolkit API.
class FirebaseUser {
  const FirebaseUser({
    required this.uid,
    this.displayName = '',
    this.email,
    this.photoUrl,
  });

  final String uid;
  final String displayName;
  final String? email;
  final String? photoUrl;
}

/// Error from the Identity Toolkit or Secure Token API.
class FirebaseAuthException implements Exception {
  FirebaseAuthException(this.statusCode, this.message);

  final int statusCode;
  final String message;

  @override
  String toString() => 'FirebaseAuthException($statusCode): $message';
}

/// A Firebase Authentication session over the Identity Toolkit REST API.
///
/// Sign in with an external identity provider's token (for example a Google
/// ID token from an OAuth flow), then use [getIdToken] wherever a Firebase ID
/// token is needed; it transparently refreshes the token via the Secure Token
/// API before it expires. [toJson]/[FirebaseAuthSession.restore] persist a
/// session across restarts (store the JSON somewhere private; it contains the
/// refresh token).
class FirebaseAuthSession {
  FirebaseAuthSession({
    required this.apiKey,
    http.Client? httpClient,
    DateTime Function()? clock,
  })  : _http = httpClient ?? http.Client(),
        _clock = clock ?? DateTime.now;

  /// The Firebase project's Web API key.
  final String apiKey;

  final http.Client _http;
  final DateTime Function() _clock;

  final StreamController<FirebaseUser?> _authState =
      StreamController<FirebaseUser?>.broadcast();

  FirebaseUser? _user;
  String? _idToken;
  String? _refreshToken;
  DateTime? _expiresAt;

  /// The signed-in user, or null.
  FirebaseUser? get currentUser => _user;

  /// Emits the user on sign-in and null on sign-out.
  Stream<FirebaseUser?> get authStateChanges => _authState.stream;

  static const _identityToolkit =
      'https://identitytoolkit.googleapis.com/v1/accounts';
  static const _secureToken = 'https://securetoken.googleapis.com/v1/token';

  /// Signs in with an external provider credential via `signInWithIdp`.
  ///
  /// [postBody] is the provider credential in form encoding, for example
  /// `id_token=<google-id-token>&providerId=google.com`. [requestUri] is the
  /// redirect URI the credential was obtained on (any valid URI works for
  /// native flows, e.g. the loopback address).
  Future<FirebaseUser> signInWithIdp({
    required String postBody,
    required String requestUri,
  }) async {
    final data = await _post('$_identityToolkit:signInWithIdp', {
      'postBody': postBody,
      'requestUri': requestUri,
      'returnSecureToken': true,
    });
    return _adopt(data);
  }

  /// Signs in with a Google ID token. Convenience over [signInWithIdp].
  Future<FirebaseUser> signInWithGoogleIdToken(
    String googleIdToken, {
    String requestUri = 'http://localhost',
  }) {
    return signInWithIdp(
      postBody: 'id_token=$googleIdToken&providerId=google.com',
      requestUri: requestUri,
    );
  }

  /// Returns a valid Firebase ID token, refreshing it first when it is
  /// within [leeway] of expiry. Null when signed out.
  Future<String?> getIdToken({
    Duration leeway = const Duration(minutes: 5),
  }) async {
    if (_idToken == null) return null;
    final expiresAt = _expiresAt;
    if (expiresAt != null && _clock().isBefore(expiresAt.subtract(leeway))) {
      return _idToken;
    }
    return _refresh();
  }

  Future<String?> _refresh() async {
    final refreshToken = _refreshToken;
    if (refreshToken == null) return _idToken;
    final response = await _http.post(
      Uri.parse('$_secureToken?key=$apiKey'),
      headers: const {'Content-Type': 'application/x-www-form-urlencoded'},
      body: {
        'grant_type': 'refresh_token',
        'refresh_token': refreshToken,
      },
    );
    if (response.statusCode != 200) {
      // The refresh token was revoked or expired: the session is over.
      await signOut();
      return null;
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    _idToken = data['id_token'] as String?;
    _refreshToken = (data['refresh_token'] as String?) ?? _refreshToken;
    _expiresAt = _expiryFrom(data['expires_in']);
    return _idToken;
  }

  /// Clears the session and emits a signed-out state.
  Future<void> signOut() async {
    _user = null;
    _idToken = null;
    _refreshToken = null;
    _expiresAt = null;
    if (!_authState.isClosed) _authState.add(null);
  }

  /// Serializes the session for persistence. Contains the refresh token, so
  /// store it privately.
  Map<String, dynamic> toJson() => {
        'uid': _user?.uid,
        'displayName': _user?.displayName,
        'email': _user?.email,
        'photoUrl': _user?.photoUrl,
        'refreshToken': _refreshToken,
      };

  /// Restores a persisted session and refreshes its ID token immediately.
  /// Returns the user, or null when the stored refresh token is no longer
  /// valid.
  Future<FirebaseUser?> restore(Map<String, dynamic> json) async {
    final uid = json['uid'] as String?;
    final refreshToken = json['refreshToken'] as String?;
    if (uid == null || refreshToken == null) return null;
    _refreshToken = refreshToken;
    _idToken = 'expired';
    _expiresAt = null;
    final token = await _refresh();
    if (token == null) return null;
    _user = FirebaseUser(
      uid: uid,
      displayName: (json['displayName'] as String?) ?? '',
      email: json['email'] as String?,
      photoUrl: json['photoUrl'] as String?,
    );
    if (!_authState.isClosed) _authState.add(_user);
    return _user;
  }

  Future<Map<String, dynamic>> _post(
    String url,
    Map<String, dynamic> body,
  ) async {
    final response = await _http.post(
      Uri.parse('$url?key=$apiKey'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );
    if (response.statusCode != 200) {
      String message = response.body;
      try {
        message = (jsonDecode(response.body)['error']?['message'] as String?) ??
            message;
      } catch (_) {
        // Keep the raw body.
      }
      throw FirebaseAuthException(response.statusCode, message);
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  FirebaseUser _adopt(Map<String, dynamic> data) {
    final uid = data['localId'] as String?;
    final idToken = data['idToken'] as String?;
    if (uid == null || idToken == null) {
      throw FirebaseAuthException(200, 'Sign-in response was missing fields.');
    }
    _idToken = idToken;
    _refreshToken = data['refreshToken'] as String?;
    _expiresAt = _expiryFrom(data['expiresIn']);
    _user = FirebaseUser(
      uid: uid,
      displayName: (data['displayName'] as String?) ?? '',
      email: data['email'] as String?,
      photoUrl: data['photoUrl'] as String?,
    );
    if (!_authState.isClosed) _authState.add(_user);
    return _user!;
  }

  DateTime? _expiryFrom(Object? expiresIn) {
    final seconds = int.tryParse(expiresIn?.toString() ?? '');
    return seconds == null ? null : _clock().add(Duration(seconds: seconds));
  }

  void close() {
    _authState.close();
    _http.close();
  }
}
