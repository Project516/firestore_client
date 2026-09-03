# Changelog

## 0.3.0

- `FirebaseAuthSession.updateDisplayName`, so an account can be renamed
  without a re-sign-in. Fields the Identity Toolkit response omits are carried
  over from the current user rather than cleared.
- `FirebaseAuthSession.linkWithIdp` and `linkGoogleIdToken`: link a second
  provider credential to the signed-in account, so both sign in to one uid.
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
