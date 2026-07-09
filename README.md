# firestore_client

A pure-Dart Firebase Auth and Cloud Firestore client over the public REST
APIs, for the platforms FlutterFire does not cover -- notably **Flutter on
Linux desktop** -- and for plain Dart programs (CLIs, servers, cron jobs).

## Why

FlutterFire has no Linux support, and the existing pure-Dart alternatives are
either dormant (`firedart`, last released 2024) or do not implement Firestore
(`flutterfire_desktop`, `firebase_dart`). This package fills that gap with a
small, dependency-light client:

- `crypto` and `http` are the only dependencies.
- No generated code, no gRPC, no platform channels.

## What it does

- **`FirebaseAuthSession`** -- Firebase Authentication over the Identity
  Toolkit REST API: sign in with an identity provider credential (for example
  a Google ID token), automatic ID-token refresh via the Secure Token API,
  and session persistence (`toJson`/`restore`).
- **`GoogleDesktopOAuth`** -- native-app Google sign-in for desktop: the
  standard loopback + PKCE OAuth flow (RFC 8252). Opens the system browser,
  captures the redirect on localhost, exchanges the code for tokens.
- **`Firestore`** -- Cloud Firestore over the v1 REST API: document get,
  create, set (with `updateMask` merge semantics), delete, paginated
  collection listing, structured queries (`runQuery` with typed filters), and
  a polling change stream for platforms without the gRPC `Listen` API.
- **`FirestoreValueCodec`** -- lossless conversion between plain Dart values
  and Firestore's REST `Value` JSON (null, bool, int, double, String,
  DateTime, bytes, GeoPoint, document references, lists, maps).

## What it does not do (yet)

- Realtime listeners (`Listen` is gRPC-only; `pollCollection` is the honest
  REST substitute).
- Offline persistence or local caching.
- Transactions and aggregate queries.
- Other Firebase products (Storage, Functions, RTDB, Messaging).

Contributions welcome for any of these.

## Usage

```dart
import 'package:firestore_client/firestore_client.dart';

Future<void> main() async {
  // 1. Google sign-in (desktop loopback + PKCE).
  final oauth = GoogleDesktopOAuth(
    clientId: '<your-oauth-desktop-client-id>',
    clientSecret: '<its-client-secret>',
    launcher: (url) async {/* open the URL in a browser */},
  );
  final googleTokens = await oauth.signIn();

  // 2. Exchange it for a Firebase session.
  final session = FirebaseAuthSession(apiKey: '<firebase-web-api-key>');
  final user = await session.signInWithGoogleIdToken(googleTokens.idToken);
  print('Signed in as ${user.displayName}');

  // 3. Talk to Firestore. Tokens refresh automatically.
  final firestore = Firestore(
    projectId: '<firebase-project-id>',
    idTokenProvider: session.getIdToken,
  );
  final doc = await firestore.getDocument('users/${user.uid}');
  print(doc?.fields);

  await firestore.setDocument(
    'users/${user.uid}',
    {'lastSeen': DateTime.now()},
    updateMask: ['lastSeen'],
  );
}
```

In a Flutter app, pass `launchUrl` from `url_launcher` as the `launcher` and
store `session.toJson()` (for example with `shared_preferences`) to restore
the session on the next launch with `session.restore(...)`.

## Security notes

- The OAuth "Desktop app" client secret is not confidential in a native app;
  RFC 8252 acknowledges this. Do not reuse it for anything that assumes
  confidentiality.
- `FirebaseAuthSession.toJson()` contains the refresh token. Store it in a
  private location.
- All access control must live in your Firestore security rules, exactly as
  with the official SDKs.

## Status

Early but tested: the codec, auth session, and Firestore document/query
surfaces have unit tests against mocked HTTP. Built to power the Linux
desktop build of a FRC scouting app; expect the API to grow as real usage
demands.

## License

AGPL-3.0.
