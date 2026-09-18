# Changelog

## 0.6.0

- **Breaking:** the central-auth-platform defines are renamed
  `CENTRAL_PROJECT_ID` and `CENTRAL_FUNCTIONS_BASE_URL` (from
  `SPECTRUM_CENTRAL_PROJECT_ID` / `SPECTRUM_CENTRAL_FUNCTIONS_BASE_URL`), and
  `centralProjectId` no longer defaults to Spectrum's own Firebase project.
  This package has no built-in central project now: `CentralRestAuthClient`
  throws `ArgumentError` at construction if `CENTRAL_PROJECT_ID` is unset and
  no `centralFunctionsBaseUrl` was passed explicitly, instead of silently
  resolving to `spectrumtasks-81c63`. An app depending on the old default
  passes `--dart-define=CENTRAL_PROJECT_ID=<its central project>` (or
  `centralFunctionsBaseUrl` directly) going forward.
- Doc comments and the README no longer name Spectrum specifically; the
  central-auth-platform handshake is a general pattern, not tied to one team.

## 0.5.1

- `GoogleDesktopOAuth.signIn` now bounds the wait for the loopback redirect
  with a `timeout` (default 5 minutes). Closing the browser tab before
  finishing the flow sent nothing to the loopback server, so the returned
  future never settled and a desktop sign-in attempt hung until the app was
  restarted (Spectrum3847/SpectrumStrategy#1694).

## 0.5.0

- `centralProjectId` and `defaultCentralFunctionsBaseUrl` are build-time
  defines (`SPECTRUM_CENTRAL_PROJECT_ID`,
  `SPECTRUM_CENTRAL_FUNCTIONS_BASE_URL`) instead of hard-coded constants, both
  defaulting to the values they held in 0.4.1. A build that passes no defines
  is unchanged. Another team running a Spectrum app against their own central
  platform now overrides them at build time rather than forking this package.
  An overridden base URL still has to be https, which `CentralRestAuthClient`
  enforces as of 0.4.1.

## 0.4.1

Hardening for `CentralRestAuthClient` and `runCentralApprovalRecheck`, found
reviewing an orphaned duplicate of the 0.4.0 work (Project516/firestore_client#14,
closed as a dead duplicate) against what actually shipped
(Project516/firestore_client#15):

- The bearer-token origin check no longer allows a loopback `http://` URL.
  Tests point `httpClient` at a mock instead of relaxing the runtime check,
  since the token would otherwise ride in clear over any origin matching
  `localhost`/`127.0.0.1`/`::1`.
- `getCustomToken`'s request URL is now built from the base URL's parsed path
  plus the callable name as a normalized path segment, instead of string
  concatenation, so a trailing slash, query, or fragment on
  `centralFunctionsBaseUrl` can no longer misdirect the request.
- `CentralRestAuthClient.close()` no longer closes a caller-supplied
  `httpClient`. It previously closed it via `FirebaseAuthSession.close()`
  regardless of who owned it.
- A 200 response from the callable with an unexpected shape (no `result`
  key) now throws `CentralAuthException` instead of an uncaught `TypeError`.
- `runCentralApprovalRecheck` distinguishes a malformed persisted session
  (deleted, reported as `sessionRevoked`) from a transient failure
  (`deferred`), and no longer reports a recheck as `deferred` after the
  callable has already succeeded and `onApproved`'s side effects have
  already run -- a failure persisting the rotated session now surfaces as a
  real exception instead of being misreported as inconclusive.
- `TimeoutHttpClient` no longer follows redirects automatically, so a
  same-host or subdomain redirect can no longer carry the `Authorization`
  bearer token to it. This also covers `getCustomToken`'s own request and
  every `FirebaseAuthSession` request (sign-in, token refresh, display-name
  update, provider linking) directly, since both apps that use this package
  inject their own `httpClient` instead of this package's
  `TimeoutHttpClient`, so the fix could not rely on that wrapper alone.
- `FirebaseAuthSession.restore` (and so `CentralRestAuthClient.restore`) now
  treats a wrong-typed persisted field (a `uid` that decoded to something
  other than a string, for example) the same as a missing one -- returns
  null instead of throwing a `TypeError` -- so a caller reading a malformed
  local blob does not have to catch a `TypeError` to find out.

## 0.4.0

- `CentralRestAuthClient`, the REST implementation of the central Spectrum
  App Platform handshake (Google ID token -> central session ->
  `getCustomToken`) for any platform that cannot use `cloud_functions`. Moved
  out of a Flutter app so two apps stop writing the same handshake twice.
- `CentralAuthErrorKind` and `classifyCentralAuthError`, so every caller
  agrees on what counts as "not approved" versus "unreachable" -- the
  difference between a member working fine offline and being signed out.
  Takes either spelling of the central callable's status
  (`PERMISSION_DENIED` from the REST error, `permission-denied` from a
  FlutterFire `FirebaseFunctionsException.code`), so a FlutterFire caller can
  reuse it without this package depending on `cloud_functions`.
- `CentralHandshake`, `CentralProfile`, `CentralAuthException`.
- `runCentralApprovalRecheck` and `CentralRecheckOutcome`: the daily
  approval re-check mechanism against a persisted central session. Takes a
  `CentralSessionStorage` (read/write/delete one string) and plain
  `onApproved`/`onDenied` callbacks instead of `SharedPreferences`, so the
  re-check cadence and denial threshold stay app policy while the network
  call and its classification live in one place.
- `TimeoutHttpClient`: bounds an `http.Client` with a deadline on both the
  response headers and each gap in the body stream, so a black-holed
  connection fails instead of hanging forever. `CentralRestAuthClient`
  defaults to it; a bare `http.Client()` has no such bound.

## 0.3.0

- `FirebaseAuthSession.updateDisplayName`, so an account can be renamed
  without a re-sign-in. Fields the Identity Toolkit response omits are carried
  over from the current user rather than cleared.
- `FirebaseAuthSession.linkWithIdp` and `linkGoogleIdToken`: link a second
  provider credential to the signed-in account, so both sign in to one uid.
  The account keeps its own profile: the response carries the linked
  provider's name and email, and adopting those would swap the signed-in
  identity for the one just attached to it.
- `FirebaseAuthSession.unlinkProvider` and `linkedProviders`, with the new
  `LinkedProvider` type.
- `FirestoreValueCodec` and `Document.fromJson` are now tested against a
  Firestore REST document whose wire encoding was read from a live database
  rather than written from memory. No behavior change: the audit found the
  codec already correct, including the three encodings most easily got wrong
  from the docs alone (`integerValue` as a JSON string, an integral
  `doubleValue` as a bare number, and an empty map arriving as
  `{"mapValue": {}}` with no `fields` key).

  Prompted by `statbotics_client` v0.4.0, where models that had never run
  against a live body shipped four releases broken while their hand-written
  tests passed, because the tests agreed with the models rather than the API.
  See `test/fixtures/README.md` for what the fixture preserves verbatim and
  what is substituted.

## 0.2.1

- Non-finite doubles. Firestore encodes `NaN`, `Infinity` and `-Infinity` as
  strings in REST values; the codec now writes them in that form instead of
  emitting invalid JSON, and reads them back as Dart doubles.
- `signIn` awaits `exchangeCode` inside its `try` block. Same behavior, and it
  clears `unawaited_return_in_try_block` under Dart 3.13.1's analyzer.

## 0.2.0

- `Firestore.pollCollection`: cancelling the subscription now stops the polling
  loop promptly, even while it is waiting between polls; the pending delay
  resolves early instead of letting the loop run a final poll afterward.
- Offline reads. `Firestore` takes an optional `FirestoreCache`; a successful
  `getDocument`, `listDocuments` or `runQuery` is cached, and a later read that
  cannot reach the server is served from the cache with `Document.fromCache`
  set. `FileFirestoreCache` persists across a relaunch,
  `InMemoryFirestoreCache` does not. Without a cache the client behaves exactly
  as before.
- A 403 or 404 never falls back to cached data: the server answered, so stale
  data would be wrong. A 429 or 5xx does fall back, as does any failure to reach
  the server at all. A 404 also drops the cached copy, so a deleted document
  cannot come back.
- `Firestore.clearCache()`, for sign-out.
- Offline writes. `Firestore` takes an optional `FirestoreWriteQueue`; a write
  that cannot reach the server is queued and `flushWrites()` replays it. Writes
  replay oldest first and the flush stops at the first still-unreachable one, so
  order is preserved. A write the server *refuses* (403, a failed `exists`
  precondition) is dropped and reported in `FlushResult.rejected` rather than
  blocking the queue behind it forever.
- A queued `setDocument` or `createDocument` returns a local `Document` with
  `fromCache` set: the caller's own value, since the server has not seen it. A
  `createDocument` with no explicit id is never queued, because the id would come
  from the server.
- An offline `deleteDocument` drops the cached copy immediately, so a later
  offline read cannot serve a document the caller already deleted.
- `FirebaseAuthSession.restore` keeps the session when the token endpoint cannot
  be reached, instead of treating that as a revoked token and signing the user
  out. A relaunch with no network resolves the persisted user; `getIdToken`
  still fails until the network returns. `FileFirestoreCache.clear()` removes
  only its own entries and leaves the directory in place, so a cache pointed at
  a directory the host also uses cannot delete unrelated state.
- `FileFirestoreCache` hashes keys into filenames, so a long key (a `runQuery`
  key holds the whole encoded query) stays inside the filesystem's name limit,
  and each write uses its own temporary file.
- A cache that throws on write never downgrades a successful read: the payload
  the server returned is still returned, uncached.

## 0.1.0

- Initial release: `FirebaseAuthSession` (Identity Toolkit sign-in +
  Secure Token refresh + session persistence), `GoogleDesktopOAuth`
  (loopback + PKCE), `Firestore` (get/create/set/delete/list/runQuery +
  polling change stream), and `FirestoreValueCodec`.
- `Firestore.commitUpdate`: masked updates through `documents:commit` with
  atomic array transforms (`appendMissingElements`/`removeAllFromArray`, the
  REST equivalents of `arrayUnion`/`arrayRemove`) and an optional
  `exists: true` precondition.
- `FirestoreApiException` carries the canonical `status` name and an
  `isNotFound` helper; batch-endpoint error arrays are parsed.
