/// Where [Firestore] keeps the last successful response for a read, so the same
/// read can be answered while the network is down.
///
/// Deliberately a string key/value store rather than a document store: the
/// cache holds the raw REST payload, which is the only form guaranteed to decode
/// back into exactly what the server sent. Implement this to put the cache
/// wherever the host app already keeps state (SharedPreferences, a database, a
/// directory); [FileFirestoreCache] covers desktop and CLI use, and
/// [InMemoryFirestoreCache] covers tests and a single process run.
abstract class FirestoreCache {
  /// The stored payload for [key], or null when nothing is stored.
  Future<String?> read(String key);

  /// Stores [value] under [key], replacing anything already there.
  Future<void> write(String key, String value);

  /// Drops [key]. Removing a key that is not there succeeds.
  Future<void> remove(String key);

  /// Drops everything. Call this on sign-out: the cache holds documents the
  /// signed-in user was allowed to read, and the next user may not be.
  Future<void> clear();
}

/// A [FirestoreCache] that lives as long as the process.
///
/// Useful in tests, and in a short-lived program (a cron job) where surviving a
/// relaunch buys nothing. It does not bound its own size, so do not point it at
/// an unbounded set of documents in a long-running process.
class InMemoryFirestoreCache implements FirestoreCache {
  final Map<String, String> _entries = <String, String>{};

  /// The number of cached payloads, for tests and diagnostics.
  int get length => _entries.length;

  @override
  Future<String?> read(String key) async => _entries[key];

  @override
  Future<void> write(String key, String value) async => _entries[key] = value;

  @override
  Future<void> remove(String key) async => _entries.remove(key);

  @override
  Future<void> clear() async => _entries.clear();
}
