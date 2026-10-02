> **Moved.** This package now lives in [Project516/dart-packages](https://github.com/Project516/dart-packages/tree/main/packages/firestore_client), tagged per release, currently `firestore_client-v0.6.0`. This repo is archived and gets no further updates.

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
  and session persistence (`toJson`/`restore`). Also account management:
  `updateDisplayName`, `linkGoogleIdToken` and `unlinkProvider` for signing
  one account in with several credentials, and `linkedProviders` to list
  them.
- **`GoogleDesktopOAuth`** -- native-app Google sign-in for desktop: the
  standard loopback + PKCE OAuth flow (RFC 8252). Opens the system browser,
  captures the redirect on localhost, exchanges the code for tokens.
- **`Firestore`** -- Cloud Firestore over the v1 REST API: document get,
  create, set (with `updateMask` merge semantics), delete, paginated
  collection listing, structured queries (`runQuery` with typed filters), and
  a polling change stream for platforms without the gRPC `Listen` API
  (cancelling its subscription stops the loop promptly).
- **`FirestoreCache`** -- offline reads. Point `Firestore` at a cache and every
  successful get, list and query is stored; a later read that cannot reach the
  server is answered from it, with `Document.fromCache` set so the caller can
  say the data is a snapshot. `FileFirestoreCache` survives a relaunch,
  `InMemoryFirestoreCache` lasts as long as the process. Off by default.
- **`FirestoreWriteQueue`** -- offline writes. Point `Firestore` at a queue and a
  write that cannot reach the server is kept instead of thrown away;
  `flushWrites()` replays them oldest first and reports what landed, what the
  server refused, and what is still waiting. `commitUpdate`'s array transforms
  are the safe thing to queue, since the server merges them. Off by default.
- **`FirestoreValueCodec`** -- lossless conversion between plain Dart values
  and Firestore's REST `Value` JSON (null, bool, int, double, String,
  DateTime, bytes, GeoPoint, document references, lists, maps).
- **`CentralRestAuthClient`** -- the REST handshake for a central-auth-platform
  pattern: exchange a Google ID token for a session on a shared central
  Firebase project, then call its `getCustomToken` callable to mint
  a custom token scoped to the calling app. For any platform that cannot use
  `cloud_functions` (desktop, or a mobile app with no native FlutterFire app
  registered on the central project). `classifyCentralAuthError` maps the
  callable's status to `CentralAuthErrorKind` (`notApproved`,
  `appNotRegistered`, `unknown`) so a caller can tell "this member is not
  approved" apart from "the server was unreachable" -- the difference
  between working offline and being signed out. `runCentralApprovalRecheck`
  re-verifies a persisted central session against a caller-supplied
  `CentralSessionStorage` and `onApproved`/`onDenied` callbacks; the re-check
  cadence and denial threshold are the caller's own policy.
- **`TimeoutHttpClient`** -- wraps an `http.Client` with a deadline on both
  the response headers and each gap in the body stream, so a black-holed
  connection times out instead of hanging forever. `CentralRestAuthClient`
  uses it by default.

## What it does not do (yet)

- Realtime listeners (`Listen` is gRPC-only; `pollCollection` is the honest
  REST substitute).
- Transactions and multi-document atomicity. A queued write is replayed on its
  own, not as part of a batch.
- Aggregate queries.
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

### Central auth-platform handshake

Several apps can share one Firebase project as a central approval/roster
authority: each app signs in there and exchanges that session for a custom
token scoped to itself. There is no built-in central project, so set
`CENTRAL_PROJECT_ID` at build time (or pass `centralFunctionsBaseUrl`
directly):

```
flutter build apk --dart-define=CENTRAL_PROJECT_ID=your-central-project
```

```dart
final client = CentralRestAuthClient(centralApiKey: '<central-web-api-key>');
await client.signInWithGoogleIdToken(googleTokens.idToken);
try {
  final handshake = await client.handshake('<your-app-key>');
  // Exchange handshake.customToken on your own app's FirebaseAuth
  // (signInWithCustomToken), and store client.toJson() for the daily
  // re-check below.
} on CentralAuthException catch (error) {
  switch (error.kind) {
    case CentralAuthErrorKind.notApproved:
      // Show "not approved yet".
      break;
    case CentralAuthErrorKind.appNotRegistered:
      // Show "app not registered" -- an app-side problem, not the user's.
      break;
    case CentralAuthErrorKind.unknown:
      // Network, cold start, or a central-side problem; let the member
      // keep working and retry later.
      break;
  }
}
```

`runCentralApprovalRecheck` re-verifies a persisted session, for example once
a day at launch:

```dart
final outcome = await runCentralApprovalRecheck(
  client: client,
  storage: myCentralSessionStorage, // implements CentralSessionStorage
  appKey: '<your-app-key>',
  denialsBeforeSignOut: 2,
  onApproved: () async { /* record the check time, clear any denial count */ },
  onDenied: () async { /* increment and return a running denial count */ },
);
switch (outcome) {
  case CentralRecheckOutcome.deniedFinal:
    // End the session.
    break;
  default:
    // Everything else keeps the session alive; see CentralRecheckOutcome's
    // doc comments for what each one means.
    break;
}
```

## Security notes

- The OAuth "Desktop app" client secret is not confidential in a native app;
  RFC 8252 acknowledges this. Do not reuse it for anything that assumes
  confidentiality.
- `FirebaseAuthSession.toJson()` contains the refresh token. Store it in a
  private location.
- `FileFirestoreCache` writes document payloads to disk as plaintext, and those
  documents are whatever the signed-in user was allowed to read. Point it at a
  private directory, and call `Firestore.clearCache()` on sign-out so the next
  user cannot read the previous one's data.
- All access control must live in your Firestore security rules, exactly as
  with the official SDKs.

## Status

Early but tested: the codec, auth session, and Firestore document/query
surfaces have unit tests against mocked HTTP. Built to power the Linux
desktop build of a FRC scouting app; expect the API to grow as real usage
demands.

## License

AGPL-3.0.
