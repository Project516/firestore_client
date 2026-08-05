import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'cache.dart';

/// A [FirestoreCache] backed by one file per key under [directory].
///
/// Survives a relaunch, which is the point: a scout who opened the app on the
/// venue wifi yesterday should still see their data in a dead spot today. The
/// directory is created on first write.
///
/// Keys are hashed into filenames, so a document path with slashes in it does
/// not become a directory tree and a long key does not exceed the filesystem's
/// name limit.
///
/// The payloads are plaintext and are scoped to the signed-in user, so point
/// this at a private directory and call [Firestore.clearCache] on sign-out.
class FileFirestoreCache implements FirestoreCache {
  FileFirestoreCache(this.directory);

  /// Where the payload files live. One file per cached read.
  final Directory directory;

  /// Extension on every file this cache writes, so [clear] can tell its own
  /// entries from anything else in a directory it does not own.
  static const String _extension = '.fcache';

  File _fileFor(String key) {
    // Hashed, not encoded. base64url round-trips and reads nicely, but a
    // runQuery key holds the whole encoded query body, and encoding that
    // produces a filename past the 255-byte limit every filesystem here
    // enforces, so the write fails and the cache silently never works for
    // queries. A digest is fixed-length.
    final name = sha256.convert(utf8.encode(key)).toString();
    return File('${directory.path}${Platform.pathSeparator}$name$_extension');
  }

  @override
  Future<String?> read(String key) async {
    final file = _fileFor(key);
    if (!await file.exists()) return null;
    try {
      return await file.readAsString();
    } on FileSystemException {
      // A half-written or unreadable file is a cache miss, never an error: the
      // caller is already handling the network failure that got it here.
      return null;
    }
  }

  @override
  Future<void> write(String key, String value) async {
    try {
      await directory.create(recursive: true);
      // Written to a temporary file and renamed, so a process that dies mid
      // write cannot leave a truncated payload that decodes into a wrong
      // document.
      final target = _fileFor(key);
      // A temp name unique per call. Deriving it from the key alone let two
      // concurrent writers for one key share a temp file and interleave their
      // bytes into it, and the rename then published a payload that decodes
      // into neither value.
      final temp = File('${target.path}.$_writeCounter.tmp');
      _writeCounter++;
      await temp.writeAsString(value, flush: true);
      await temp.rename(target.path);
    } on FileSystemException {
      // A cache that cannot be written must not fail the read it came from.
    }
  }

  @override
  Future<void> remove(String key) async {
    try {
      final file = _fileFor(key);
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // Nothing to report: the next read treats it as a miss either way.
    }
  }

  /// Distinguishes concurrent writes. A counter rather than a random suffix so
  /// the package stays dependency-light and the name is reproducible in a test.
  int _writeCounter = 0;

  @override
  Future<void> clear() async {
    // Only this cache's own files, and the directory itself survives.
    // Deleting the directory recursively removed files the cache never wrote:
    // clearCache() runs on sign-out, and a host that points the cache at an
    // existing state directory would lose unrelated data, including the
    // persisted session sitting next to it.
    try {
      if (!await directory.exists()) return;
      await for (final entry in directory.list()) {
        if (entry is File && entry.path.endsWith(_extension)) {
          try {
            await entry.delete();
          } on FileSystemException {
            // One stuck file does not stop the rest from being cleared.
          }
        }
      }
    } on FileSystemException {
      // Same as remove: a cache that will not clear is not worth throwing over.
    }
  }
}
