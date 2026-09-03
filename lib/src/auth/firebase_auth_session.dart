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

/// One identity provider linked to a Firebase account.
class LinkedProvider {
  const LinkedProvider({
    required this.providerId,
    this.email,
    this.displayName,
    this.photoUrl,
  });

  /// The Identity Toolkit provider id, for example `google.com`.
  final String providerId;
  final String? email;
  final String? displayName;
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

  /// Links another provider credential to the signed-in account, so both
  /// credentials sign in to the same uid.
  ///
  /// [postBody] and [requestUri] are as for [signInWithIdp]. Throws when
  /// signed out, and with `FEDERATED_USER_ID_ALREADY_LINKED` when the
  /// credential already belongs to another account.
  Future<FirebaseUser> linkWithIdp({
    required String postBody,
    required String requestUri,
  }) async {
    final data = await _post('$_identityToolkit:signInWithIdp', {
      'idToken': await _requireIdToken(),
      'postBody': postBody,
      'requestUri': requestUri,
      'returnSecureToken': true,
    });
    // Not _adopt: the response describes the credential just linked, so it
    // can omit the account's own displayName, email or photo. Linking must
    // not blank them.
    return _refreshUserFrom(data);
  }

  /// Links a second Google account. Convenience over [linkWithIdp].
  Future<FirebaseUser> linkGoogleIdToken(
    String googleIdToken, {
    String requestUri = 'http://localhost',
  }) {
    return linkWithIdp(
      postBody: 'id_token=$googleIdToken&providerId=google.com',
      requestUri: requestUri,
    );
  }

  /// Unlinks [providerId] from the signed-in account.
  ///
  /// The caller is responsible for leaving at least one provider linked; an
  /// account with none can no longer sign in.
  Future<FirebaseUser> unlinkProvider(String providerId) async {
    final data = await _post('$_identityToolkit:update', {
      'idToken': await _requireIdToken(),
      'deleteProvider': [providerId],
      // The current token still carries the provider that was just removed.
      'returnSecureToken': true,
    });
    return _refreshUserFrom(data);
  }

  /// The providers currently linked to the signed-in account.
  Future<List<LinkedProvider>> linkedProviders() async {
    final data = await _post('$_identityToolkit:lookup', {
      'idToken': await _requireIdToken(),
    });
    final users = data['users'];
    if (users is! List || users.isEmpty) return const [];
    final info = (users.first as Map<String, dynamic>)['providerUserInfo'];
    if (info is! List) return const [];
    return info.whereType<Map<String, dynamic>>().map((entry) {
      return LinkedProvider(
        providerId: entry['providerId'] as String? ?? '',
        email: entry['email'] as String?,
        displayName: entry['displayName'] as String?,
        photoUrl: entry['photoUrl'] as String?,
      );
    }).toList();
  }

  /// Sets the account's display name, the one Identity Toolkit reports back
  /// on every later sign-in.
  Future<FirebaseUser> updateDisplayName(String displayName) async {
    final data = await _post('$_identityToolkit:update', {
      'idToken': await _requireIdToken(),
      'displayName': displayName,
      'returnSecureToken': true,
    });
    return _refreshUserFrom(data);
  }

  Future<String> _requireIdToken() async {
    final token = await getIdToken();
    if (token == null) {
      throw FirebaseAuthException(401, 'No user is signed in.');
    }
    return token;
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
    try {
      final token = await _refresh();
      // A null here means Google answered and refused: the refresh token was
      // revoked or expired, so the session really is over.
      if (token == null) return null;
    } catch (_) {
      // The server could not be reached, which is not the same thing. The user
      // stays signed in on the strength of the persisted session, keeping the
      // refresh token so a later call can exchange it. `getIdToken` still fails
      // until the network returns, which is honest: there is no valid token yet,
      // only a valid session. Relaunching in a dead spot must not sign a scout
      // out of an app whose whole point is working there (#5).
    }
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

  /// Adopts the user fields of an `accounts:update` response, and its tokens
  /// when it carried any. Unlike [_adopt] this keeps the current session
  /// alive when the response has no `idToken`, which `deleteProvider`
  /// responses do not carry.
  FirebaseUser _refreshUserFrom(Map<String, dynamic> data) {
    final current = _user;
    if (current == null) {
      throw FirebaseAuthException(401, 'No user is signed in.');
    }
    final idToken = data['idToken'] as String?;
    if (idToken != null) {
      _idToken = idToken;
      _refreshToken = (data['refreshToken'] as String?) ?? _refreshToken;
      _expiresAt = _expiryFrom(data['expiresIn']);
    }
    _user = FirebaseUser(
      uid: current.uid,
      displayName: (data['displayName'] as String?) ?? current.displayName,
      email: (data['email'] as String?) ?? current.email,
      photoUrl: (data['photoUrl'] as String?) ?? current.photoUrl,
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
