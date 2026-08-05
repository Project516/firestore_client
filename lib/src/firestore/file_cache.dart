import 'dart:convert';
import 'dart:io';

import 'cache.dart';

/// A [FirestoreCache] backed by one file per key under [directory].
///
/// Survives a relaunch, which is the point: a scout who opened the app on the
/// venue wifi yesterday should still see their data in a dead spot today. The
/// directory is created on first write.
///
/// Keys are hashed into filenames, so a document path with slashes in it does
/// not become a directory tree.
class FileFirestoreCache implements FirestoreCache {
  FileFirestoreCache(this.directory);

  /// Where the payload files live. One file per cached read.
  final Directory directory;

  File _fileFor(String key) {
    // A stable, filesystem-safe name for an arbitrary key. base64url of the
    // UTF-8 bytes rather than a hash: it round-trips, so a cache directory can
    // be read back by a human debugging what got stored.
    final name = base64Url.encode(utf8.encode(key));
    return File('${directory.path}${Platform.pathSeparator}$name');
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
      final temp = File('${target.path}.tmp');
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

  @override
  Future<void> clear() async {
    try {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    } on FileSystemException {
      // Same as remove: a cache that will not clear is not worth throwing over.
    }
  }
}
