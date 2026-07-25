# Changelog

## Unreleased

- `Firestore.pollCollection`: cancelling the subscription now stops the polling
  loop promptly, even while it is waiting between polls; the pending delay
  resolves early instead of letting the loop run a final poll afterward.

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
