import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../http/timeout_http_client.dart';
import 'firebase_auth_session.dart';

/// Result of the central Spectrum App Platform's `getCustomToken` handshake.
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

/// The central project every Spectrum app authenticates against.
const String centralProjectId = 'spectrumtasks-81c63';

/// The callable on the central project that mints per-app custom tokens.
const String customTokenCallable = 'getCustomToken';

/// The central project's callable endpoint. Region default for v1 onCall
/// functions, the same endpoint the web SDK resolves.
const String defaultCentralFunctionsBaseUrl =
    'https://us-central1-$centralProjectId.cloudfunctions.net';

/// The REST implementation of the central Spectrum App Platform handshake --
/// Google ID token -> central session -> `getCustomToken` -- for any
/// platform that cannot use `cloud_functions` (desktop, and mobile wherever
/// a second native FlutterFire app is not registered on the central
/// project). A web/mobile app with its own FlutterFire central app can call
/// the callable directly instead and does not need this class.
///
/// One [FirebaseAuthSession] per instance, scoped to the central project, so
/// its refresh token never mixes with the calling app's own session.
class CentralRestAuthClient {
  CentralRestAuthClient({
    required String centralApiKey,
    this.centralFunctionsBaseUrl = defaultCentralFunctionsBaseUrl,
    http.Client? httpClient,
    Duration? customTokenTimeout,
  })  : _customTokenTimeout = customTokenTimeout ?? _defaultCustomTokenTimeout,
        _http = httpClient ??
            // The transport deadline has to cover the callable's own, or a
            // cold start dies in the socket before getCustomToken's timeout
            // is ever reached and the failure reads as unreachable rather
            // than slow.
            TimeoutHttpClient(
              timeout: customTokenTimeout ?? _defaultCustomTokenTimeout,
            ),
        _ownsHttp = httpClient == null {
    _assertCredentialedOrigin(centralFunctionsBaseUrl);
    _session = FirebaseAuthSession(apiKey: centralApiKey, httpClient: _http);
  }

  /// Every call to [centralFunctionsBaseUrl] carries the central session's
  /// bearer token, so a base URL that is not HTTPS would put that token on
  /// the wire in clear, and one pointing somewhere unexpected would hand it
  /// to whoever answers. The default is correct; this guards a caller that
  /// overrides it. Loopback is allowed so a test can point at a local stub.
  static void _assertCredentialedOrigin(String baseUrl) {
    final uri = Uri.tryParse(baseUrl);
    final host = uri?.host ?? '';
    final loopback =
        host == 'localhost' || host == '127.0.0.1' || host == '::1';
    if (uri == null ||
        !uri.hasAuthority ||
        (uri.scheme != 'https' && !loopback)) {
      throw ArgumentError.value(
        baseUrl,
        'centralFunctionsBaseUrl',
        'must be an https URL (or loopback for tests); it carries a bearer token',
      );
    }
  }

  /// The central project's callable endpoint.
  final String centralFunctionsBaseUrl;

  /// A 30-60s cold start on the central function is normal.
  static const Duration _defaultCustomTokenTimeout = Duration(seconds: 90);

  final http.Client _http;
  final bool _ownsHttp;
  final Duration _customTokenTimeout;
  late final FirebaseAuthSession _session;

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
  /// token as the bearer. [targetApp] is the calling app's SpectrumAdmin key.
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
    final response = await _http
        .post(
          Uri.parse('$centralFunctionsBaseUrl/$customTokenCallable'),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $bearerToken',
          },
          body: jsonEncode({
            'data': {'targetApp': targetApp},
          }),
        )
        .timeout(_customTokenTimeout);
    final Map<String, dynamic> body;
    try {
      body = (jsonDecode(response.body) as Map).cast<String, dynamic>();
    } catch (_) {
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
    final result = (body['result'] as Map).cast<String, dynamic>();
    return CentralHandshake(
      customToken: result['customToken'] as String,
      profile: result['profile'] is Map
          ? CentralProfile.fromMap(
              (result['profile'] as Map).cast<String, dynamic>(),
            )
          : null,
    );
  }

  void close() {
    _session.close();
    if (_ownsHttp) _http.close();
  }
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

  /// Anything else -- network, cold start, central misconfiguration, a
  /// malformed stored payload. The caller keeps the session alive and
  /// retries later.
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
  try {
    final payload = (jsonDecode(stored) as Map).cast<String, dynamic>();
    if (await client.restore(payload) == null) {
      await storage.delete();
      return CentralRecheckOutcome.sessionRevoked;
    }
    final idToken = await client.getIdToken();
    if (idToken == null) return CentralRecheckOutcome.tokenUnavailable;
    await client.getCustomToken(idToken, appKey);
    await onApproved();
    // The refresh may have rotated the central refresh token.
    await storage.write(jsonEncode(client.toJson()));
    return CentralRecheckOutcome.approved;
  } on CentralAuthException catch (error) {
    if (error.kind != CentralAuthErrorKind.notApproved) {
      return CentralRecheckOutcome.deferred;
    }
    final denials = await onDenied();
    return denials < denialsBeforeSignOut
        ? CentralRecheckOutcome.deniedPending
        : CentralRecheckOutcome.deniedFinal;
  } catch (_) {
    // A malformed stored payload lands here too (the jsonDecode/cast above is
    // inside this try): keep the session alive and retry later rather than
    // treating a bad local blob as a denial.
    return CentralRecheckOutcome.deferred;
  }
}
