# Changelog

## Unreleased

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
- `Firestore.clearCache()`, for sign-out. `FileFirestoreCache.clear()` removes
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
