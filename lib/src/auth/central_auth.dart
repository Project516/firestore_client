import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../http/timeout_http_client.dart';
import 'firebase_auth_session.dart';

/// Result of a central auth platform's `getCustomToken` handshake.
class CentralHandshake {
  const CentralHandshake({required this.customToken, this.profile});

  /// Firebase custom token to exchange on the calling app's own FirebaseAuth
  /// (`signInWithCustomToken`), scoped to the app key passed to
  /// [CentralRestAuthClient.handshake].
  final String customToken;

  /// The central platform's `users/{uid}` profile: displayName, email, role,
  /// photoURL, slackId. The central profile is authoritative for who the
  /// user is; a calling app's own profile collection still owns its
  /// in-app-only fields.
  final CentralProfile? profile;
}

/// The central platform's view of the signed-in member.
class CentralProfile {
  const CentralProfile({
    this.displayName,
    this.email,
    this.role,
    this.photoUrl,
    this.slackId,
  });

  factory CentralProfile.fromMap(Map<String, dynamic> map) => CentralProfile(
        displayName: map['displayName'] as String?,
        email: map['email'] as String?,
        role: map['role'] as String?,
        photoUrl: map['photoURL'] as String?,
        slackId: map['slackId'] as String?,
      );

  final String? displayName;
  final String? email;
  final String? role;
  final String? photoUrl;
  final String? slackId;
}

/// Why a central platform handshake failed, mapped from the callable's
/// HttpsError status so a caller can show a decision-grade message instead of
/// a raw SDK string.
enum CentralAuthErrorKind {
  /// The user doc on the central project exists but is not approved, or a
  /// brand-new central record was created as pending.
  notApproved,

  /// No app registration on the central project for the calling app's key
  /// (or it is still pending approval).
  appNotRegistered,

  /// Everything else: network, cold start, central misconfiguration.
  unknown,
}

/// Classifies a canonical error code from the central `getCustomToken`
/// callable. Both surfaces this package's callers see spell the same gRPC
/// status differently -- a REST response's `PERMISSION_DENIED` and a
/// FlutterFire `FirebaseFunctionsException.code`'s `permission-denied` mean
/// the same thing -- so this takes either spelling. Callers on a FlutterFire
/// path (which this package does not depend on) pass their exception's
/// `code` straight through; [CentralRestAuthClient] passes the REST error's
/// `status`.
///
/// This is the one place that decides "not approved" versus "unreachable",
/// which is the difference between a member working fine offline and being
/// signed out. Two apps drifting on it is a silent lockout.
CentralAuthErrorKind classifyCentralAuthError(String? code) {
  switch (code?.toLowerCase()) {
    case 'permission-denied':
    case 'permission_denied':
      return CentralAuthErrorKind.notApproved;
    case 'not-found':
    case 'not_found':
      // "App pending approval" also arrives as not-found, so both mean the
      // same user-facing thing: this is an app-side problem, not the user's
      // account.
      return CentralAuthErrorKind.appNotRegistered;
    default:
      return CentralAuthErrorKind.unknown;
  }
}

/// A classified central-platform rejection.
class CentralAuthException implements Exception {
  const CentralAuthException(this.kind, this.message);

  final CentralAuthErrorKind kind;
  final String message;

  @override
  String toString() => 'CentralAuthException(${_kindName(kind)}): $message';
}

String _kindName(CentralAuthErrorKind kind) {
  switch (kind) {
    case CentralAuthErrorKind.notApproved:
      return 'not-approved';
    case CentralAuthErrorKind.appNotRegistered:
      return 'app-not-registered';
    case CentralAuthErrorKind.unknown:
      return 'unknown';
  }
}

/// The Firebase project id of the central auth platform (see
/// [CentralRestAuthClient]): several apps sharing one Firebase project as a
/// shared approval/roster authority, each minting its own custom token from
/// it.
///
/// Empty unless configured -- this package has no built-in central project.
/// Set it at build time so self-hosting the pattern is a build flag instead
/// of a fork of this package:
///
/// ```
/// flutter build apk --dart-define=CENTRAL_PROJECT_ID=your-central-project
/// ```
const String centralProjectId = String.fromEnvironment('CENTRAL_PROJECT_ID');

/// The callable on the central project that mints per-app custom tokens.
const String customTokenCallable = 'getCustomToken';

/// The central project's callable endpoint. Defaults to the region v1 onCall
/// functions use, which is the endpoint the web SDK resolves for
/// [centralProjectId]. Only meaningful once [centralProjectId] is configured;
/// see [CentralRestAuthClient], which requires an explicit
/// `centralFunctionsBaseUrl` otherwise.
///
/// Override it with `--dart-define=CENTRAL_FUNCTIONS_BASE_URL=...` for a
/// function deployed outside `us-central1` or behind a custom domain.
/// [CentralRestAuthClient] still requires https of whatever it is given, since
/// that URL carries a bearer token.
const String defaultCentralFunctionsBaseUrl = String.fromEnvironment(
  'CENTRAL_FUNCTIONS_BASE_URL',
  defaultValue: 'https://us-central1-$centralProjectId.cloudfunctions.net',
);

/// The REST implementation of a central-auth-platform handshake -- Google ID
/// token -> central session -> `getCustomToken` -- for any platform that
/// cannot use `cloud_functions` (desktop, and mobile wherever a second
/// native FlutterFire app is not registered on the central project). A
/// web/mobile app with its own FlutterFire central app can call the callable
/// directly instead and does not need this class.
///
/// One [FirebaseAuthSession] per instance, scoped to the central project, so
/// its refresh token never mixes with the calling app's own session.
class CentralRestAuthClient {
  CentralRestAuthClient({
    required String centralApiKey,
    String? centralFunctionsBaseUrl,
    http.Client? httpClient,
    Duration? customTokenTimeout,
  })  : centralFunctionsBaseUrl =
            centralFunctionsBaseUrl ?? _requireConfiguredBaseUrl(),
        _customTokenTimeout = customTokenTimeout ?? _defaultCustomTokenTimeout,
        _http = httpClient ??
            // The transport deadline has to cover the callable's own, or a
            // cold start dies in the socket before getCustomToken's timeout
            // is ever reached and the failure reads as unreachable rather
            // than slow.
            TimeoutHttpClient(
              timeout: customTokenTimeout ?? _defaultCustomTokenTimeout,
            ),
        _ownsHttp = httpClient == null {
    final baseUri = _assertCredentialedOrigin(this.centralFunctionsBaseUrl);
    _customTokenUri = Uri(
      scheme: baseUri.scheme,
      userInfo: baseUri.userInfo,
      host: baseUri.host,
      port: baseUri.port,
      pathSegments: [
        ...baseUri.pathSegments.where((segment) => segment.isNotEmpty),
        customTokenCallable,
      ],
    );
    _session = FirebaseAuthSession(
      apiKey: centralApiKey,
      httpClient: _http,
      ownsHttpClient: _ownsHttp,
    );
  }

  /// Every call to [centralFunctionsBaseUrl] carries the central session's
  /// bearer token, so a base URL that is not HTTPS would put that token on
  /// the wire in clear, and one pointing somewhere unexpected would hand it
  /// to whoever answers. The default is correct; this guards a caller that
  /// overrides it. A query or fragment on the base URL is also rejected: it
  /// would otherwise end up appended after (or swallowing) the callable path
  /// below instead of the callable ever being reached. Tests point a
  /// [httpClient] at a fake instead of relaxing this.
  static Uri _assertCredentialedOrigin(String baseUrl) {
    final uri = Uri.tryParse(baseUrl);
    if (uri == null ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        uri.scheme != 'https' ||
        uri.query.isNotEmpty ||
        uri.fragment.isNotEmpty) {
      throw ArgumentError.value(
        baseUrl,
        'centralFunctionsBaseUrl',
        'must be an https URL with no query or fragment; it carries a '
            'bearer token',
      );
    }
    return uri;
  }

  /// Resolves the endpoint when a caller passes no explicit
  /// `centralFunctionsBaseUrl`. There is no built-in central project, so this
  /// fails fast with a clear message instead of quietly deriving a
  /// nonexistent host from an unset [centralProjectId].
  static String _requireConfiguredBaseUrl() {
    if (centralProjectId.isEmpty) {
      throw ArgumentError(
        'No central project configured. Pass centralFunctionsBaseUrl '
        'explicitly, or build with '
        '--dart-define=CENTRAL_PROJECT_ID=<your-central-project-id>.',
      );
    }
    return defaultCentralFunctionsBaseUrl;
  }

  /// The central project's callable endpoint.
  final String centralFunctionsBaseUrl;

  /// A 30-60s cold start on the central function is normal.
  static const Duration _defaultCustomTokenTimeout = Duration(seconds: 90);

  final http.Client _http;
  final bool _ownsHttp;
  final Duration _customTokenTimeout;
  late final FirebaseAuthSession _session;

  /// [centralFunctionsBaseUrl] with [customTokenCallable] appended as a
  /// normalized path segment, computed once so a trailing slash on the base
  /// URL cannot produce a doubled or empty path segment.
  late final Uri _customTokenUri;

  /// Step 2 of the handshake: exchanges a Google ID token for a session on
  /// the central project, whose roster owns approval.
  Future<FirebaseUser> signInWithGoogleIdToken(String googleIdToken) =>
      _session.signInWithGoogleIdToken(googleIdToken);

  /// A valid central-project ID token (auto-refreshed), or null when there is
  /// no live central session.
  Future<String?> getIdToken() => _session.getIdToken();

  /// Restores a persisted central session (see [toJson]) for a daily
  /// approval re-check on relaunch. Null means the refresh token was
  /// refused -- an unambiguous end of that session.
  Future<FirebaseUser?> restore(Map<String, dynamic> payload) =>
      _session.restore(payload);

  /// The central session's persistable state, for a caller to store beside
  /// (not inside) its own app session.
  Map<String, dynamic> toJson() => _session.toJson();

  Future<void> signOut() => _session.signOut();

  /// Step 3: calls the central `getCustomToken` callable with the central ID
  /// token as the bearer. [targetApp] is the calling app's key as registered
  /// on the central platform.
  Future<CentralHandshake> handshake(String targetApp) async {
    final bearerToken = await getIdToken();
    if (bearerToken == null) {
      throw const CentralAuthException(
        CentralAuthErrorKind.unknown,
        'Central sign-in returned no token.',
      );
    }
    return getCustomToken(bearerToken, targetApp);
  }

  /// The bare HTTP call behind [handshake], for a caller (a daily re-check)
  /// that already has a bearer token in hand and does not need [handshake]'s
  /// null-token check repeated.
  Future<CentralHandshake> getCustomToken(
    String bearerToken,
    String targetApp,
  ) async {
    // Built as a Request with followRedirects disabled explicitly, rather
    // than through the client's post() convenience: an injected httpClient
    // (both apps that use this package supply their own) bypasses this
    // package's TimeoutHttpClient entirely, so its redirect-following would
    // otherwise be whatever that client defaults to, and this request always
    // carries the bearer token.
    final request = http.Request('POST', _customTokenUri)
      ..followRedirects = false
      ..headers.addAll({
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $bearerToken',
      })
      ..body = jsonEncode({
        'data': {'targetApp': targetApp},
      });
    final response = await _http
        .send(request)
        .then(http.Response.fromStream)
        .timeout(_customTokenTimeout);
    final Map<String, dynamic> body;
    try {
      body = (jsonDecode(response.body) as Map).cast<String, dynamic>();
    } catch (_) {
      // A malformed 200 (a proxy returning a generic success page, for
      // example) is a central auth failure, not the plain transport error
      // FirebaseAuthException means for the non-200 codes below.
      if (response.statusCode == 200) {
        throw const CentralAuthException(
          CentralAuthErrorKind.unknown,
          'Malformed response from $customTokenCallable.',
        );
      }
      throw FirebaseAuthException(response.statusCode, response.body);
    }
    if (response.statusCode != 200) {
      final error = (body['error'] as Map?)?.cast<String, dynamic>();
      final status = error?['status'] as String?;
      final kind = classifyCentralAuthError(status);
      if (kind != CentralAuthErrorKind.unknown) {
        throw CentralAuthException(
          kind,
          kind == CentralAuthErrorKind.notApproved
              ? 'Account not approved.'
              : 'App not registered.',
        );
      }
      throw FirebaseAuthException(
        response.statusCode,
        (error?['message'] as String?) ?? response.body,
      );
    }
    try {
      final result = (body['result'] as Map).cast<String, dynamic>();
      return CentralHandshake(
        customToken: result['customToken'] as String,
        profile: result['profile'] is Map
            ? CentralProfile.fromMap(
                (result['profile'] as Map).cast<String, dynamic>(),
              )
            : null,
      );
    } catch (_) {
      // A 200 with a shape the callable never actually sends (a proxy
      // returning a generic success page, for example) is still a central
      // auth failure, not a crash a caller's CentralAuthException catch
      // clause never sees.
      throw CentralAuthException(
        CentralAuthErrorKind.unknown,
        'Malformed response from $customTokenCallable.',
      );
    }
  }

  void close() => _session.close();
}

/// Minimal storage a caller supplies for the persisted central session
/// [runCentralApprovalRecheck] verifies against: read/write/delete one
/// string. Deliberately not `SharedPreferences` -- this package stays
/// dependency-light, so each app supplies its own adapter (prefs, a file,
/// whatever it already uses to store the session).
abstract class CentralSessionStorage {
  Future<String?> read();
  Future<void> write(String value);
  Future<void> delete();
}

/// Outcome of [runCentralApprovalRecheck], for a caller that owns the
/// session lifecycle (scheduling a retry, ending the session, or doing
/// nothing), since that differs by platform.
enum CentralRecheckOutcome {
  /// Nothing persisted to verify against: a session signed in before central
  /// sessions were persisted (or before this platform persisted one at all).
  /// Not an error -- the caller simply keeps working.
  noStoredSession,

  /// The central session itself is gone (a refused refresh token). Unlike a
  /// "not approved" denial this is unambiguous, so the caller should end the
  /// session right away.
  sessionRevoked,

  /// Central was reachable but returned no ID token; try again later.
  tokenUnavailable,

  /// A definite, positive answer. The rotated central session has already
  /// been written back to [CentralSessionStorage].
  approved,

  /// A "not approved" answer that has not reached the caller's own
  /// denial threshold yet. The caller keeps the session alive and asks
  /// again next time.
  deniedPending,

  /// Enough consecutive denials to act on; the caller should end the
  /// session.
  deniedFinal,

  /// Anything else -- network, cold start, central misconfiguration. The
  /// caller keeps the session alive and retries later.
  deferred,
}

/// Re-confirms with the central platform that a persisted session's member
/// is still approved, from a session stored in [storage] (see
/// [CentralRestAuthClient.toJson]).
///
/// This is the mechanism only. The re-check cadence, the denial threshold,
/// and what a denial count means to the caller are policy an app decides for
/// itself; [onDenied] returns the caller's own running denial count, and
/// [denialsBeforeSignOut] is the caller's own threshold for it.
Future<CentralRecheckOutcome> runCentralApprovalRecheck({
  required CentralRestAuthClient client,
  required CentralSessionStorage storage,
  required String appKey,
  required int denialsBeforeSignOut,

  /// Called once the callable confirms approval, before the rotated session
  /// is written back to [storage]. A caller's implementation typically
  /// records the check time and clears any denial count.
  required Future<void> Function() onApproved,

  /// Called on a "not approved" answer. Returns the number of consecutive
  /// denials so far (including this one), for comparison against
  /// [denialsBeforeSignOut].
  required Future<int> Function() onDenied,
}) async {
  final stored = await storage.read();
  if (stored == null) return CentralRecheckOutcome.noStoredSession;

  final Map<String, dynamic> payload;
  try {
    payload = (jsonDecode(stored) as Map).cast<String, dynamic>();
  } catch (_) {
    // A malformed local blob is not a signal from central at all -- there is
    // nothing to retry against, so clear it rather than repeating the same
    // decode failure on every future recheck.
    await storage.delete();
    return CentralRecheckOutcome.sessionRevoked;
  }

  try {
    final user = await client.restore(payload);
    if (user == null) {
      await storage.delete();
      return CentralRecheckOutcome.sessionRevoked;
    }
  } catch (_) {
    // The decoded JSON has the wrong shape for a session (a field of the
    // wrong type), which restore() only discovers by throwing. Same verdict
    // as a decode failure: nothing here to retry against.
    await storage.delete();
    return CentralRecheckOutcome.sessionRevoked;
  }

  try {
    final idToken = await client.getIdToken();
    if (idToken == null) return CentralRecheckOutcome.tokenUnavailable;
    await client.getCustomToken(idToken, appKey);
    await onApproved();
  } on CentralAuthException catch (error) {
    if (error.kind != CentralAuthErrorKind.notApproved) {
      return CentralRecheckOutcome.deferred;
    }
    final denials = await onDenied();
    return denials < denialsBeforeSignOut
        ? CentralRecheckOutcome.deniedPending
        : CentralRecheckOutcome.deniedFinal;
  } catch (_) {
    return CentralRecheckOutcome.deferred;
  }

  // The callable already confirmed approval and onApproved's side effects
  // already ran; a failure here is the caller's storage failing, not an
  // inconclusive recheck, so it is not swallowed into `deferred` -- the
  // refresh may have rotated the central refresh token and this is the only
  // chance to persist it.
  await storage.write(jsonEncode(client.toJson()));
  return CentralRecheckOutcome.approved;
}
