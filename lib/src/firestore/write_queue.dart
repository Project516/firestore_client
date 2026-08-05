import 'dart:convert';

/// Which write a [QueuedWrite] replays.
enum QueuedWriteKind {
  /// `createDocument` with an explicit id. A create without one is never queued:
  /// the id would come from the server, and a caller cannot be handed an id that
  /// does not exist yet.
  create,

  /// `setDocument`, with or without an `updateMask`.
  set,

  /// `commitUpdate`, including its array transforms.
  commit,

  /// `deleteDocument`.
  delete;

  static QueuedWriteKind? fromName(String name) {
    for (final kind in QueuedWriteKind.values) {
      if (kind.name == name) return kind;
    }
    // A kind written by a later version of the package. Skipped rather than
    // crashing the flush, and reported so it is not silently dropped.
    return null;
  }
}

/// One write that could not reach the server, held until it can.
///
/// Stored as JSON rather than as a closure, because the point is to survive the
/// process that made it.
class QueuedWrite {
  const QueuedWrite({
    required this.sequence,
    required this.kind,
    required this.path,
    this.fields = const <String, dynamic>{},
    this.updateMask,
    this.appendMissingElements = const <String, List<Object?>>{},
    this.removeAllFromArray = const <String, List<Object?>>{},
    this.mustExist = false,
  });

  /// Monotonic per queue, and the replay order. Two writes to one document have
  /// to land in the order they were made or the later one loses.
  final int sequence;

  final QueuedWriteKind kind;

  /// Document path for every kind except [QueuedWriteKind.create], where it is
  /// the collection path with the explicit id appended, so replay is a plain
  /// `setDocument`-shaped call against a known path.
  final String path;

  final Map<String, dynamic> fields;
  final List<String>? updateMask;
  final Map<String, List<Object?>> appendMissingElements;
  final Map<String, List<Object?>> removeAllFromArray;
  final bool mustExist;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'sequence': sequence,
        'kind': kind.name,
        'path': path,
        if (fields.isNotEmpty) 'fields': fields,
        if (updateMask != null) 'updateMask': updateMask,
        if (appendMissingElements.isNotEmpty)
          'appendMissingElements': appendMissingElements,
        if (removeAllFromArray.isNotEmpty)
          'removeAllFromArray': removeAllFromArray,
        if (mustExist) 'mustExist': true,
      };

  /// Null when the stored entry cannot be read back, which covers a kind from a
  /// later package version and a hand-corrupted file.
  static QueuedWrite? fromJson(Map<String, dynamic> json) {
    final kind = QueuedWriteKind.fromName(json['kind'] as String? ?? '');
    final path = json['path'] as String? ?? '';
    final sequence = (json['sequence'] as num?)?.toInt();
    if (kind == null || path.isEmpty || sequence == null) return null;
    Map<String, List<Object?>> transforms(Object? raw) {
      if (raw is! Map) return const <String, List<Object?>>{};
      return <String, List<Object?>>{
        for (final entry in raw.entries)
          if (entry.value is List)
            entry.key.toString(): (entry.value as List).cast<Object?>(),
      };
    }

    return QueuedWrite(
      sequence: sequence,
      kind: kind,
      path: path,
      fields: (json['fields'] as Map?)?.cast<String, dynamic>() ??
          const <String, dynamic>{},
      updateMask: (json['updateMask'] as List?)
          ?.map((e) => e.toString())
          .toList(growable: false),
      appendMissingElements: transforms(json['appendMissingElements']),
      removeAllFromArray: transforms(json['removeAllFromArray']),
      mustExist: json['mustExist'] as bool? ?? false,
    );
  }
}

/// Where writes wait while the server is unreachable.
///
/// One list, in order, holding whole entries. Deliberately not a per-document
/// map: replay order is global so a write cannot overtake an earlier one to a
/// different document that it depended on.
///
/// Implement this over whatever the host app already persists with;
/// [InMemoryWriteQueue] covers tests and a single process run.
abstract class FirestoreWriteQueue {
  /// Every pending write, oldest first.
  Future<List<QueuedWrite>> load();

  /// Replaces the stored list.
  Future<void> save(List<QueuedWrite> writes);
}

/// A [FirestoreWriteQueue] that lives as long as the process.
///
/// Fine for a CLI or a cron job, where a crash means the run is repeated
/// anyway. An app that wants a write to survive a relaunch needs a persistent
/// implementation.
class InMemoryWriteQueue implements FirestoreWriteQueue {
  List<QueuedWrite> _writes = const <QueuedWrite>[];

  @override
  Future<List<QueuedWrite>> load() async => List<QueuedWrite>.of(_writes);

  @override
  Future<void> save(List<QueuedWrite> writes) async =>
      _writes = List<QueuedWrite>.of(writes);
}

/// A [FirestoreWriteQueue] over a single JSON string, for a host that already
/// has somewhere to keep one (SharedPreferences, a settings row, a file).
///
/// Saves the whole list on every change. The queue is short by construction --
/// it drains as soon as the network returns -- so rewriting it costs less than
/// the bookkeeping an append-only format would need.
class StringBackedWriteQueue implements FirestoreWriteQueue {
  StringBackedWriteQueue({required this.read, required this.write});

  /// Returns the stored JSON, or null when nothing is stored.
  final Future<String?> Function() read;

  /// Stores the JSON.
  final Future<void> Function(String value) write;

  @override
  Future<List<QueuedWrite>> load() async {
    final raw = await read();
    if (raw == null || raw.trim().isEmpty) return const <QueuedWrite>[];
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      // A corrupt queue is not worth failing every write over, and there is
      // nothing to recover from it.
      return const <QueuedWrite>[];
    }
    if (decoded is! List) return const <QueuedWrite>[];
    final writes = <QueuedWrite>[];
    for (final entry in decoded) {
      if (entry is! Map) continue;
      final write = QueuedWrite.fromJson(entry.cast<String, dynamic>());
      // A null is an entry this version cannot read, which is skipped rather
      // than failing the whole queue.
      if (write != null) writes.add(write);
    }
    return writes;
  }

  @override
  Future<void> save(List<QueuedWrite> writes) =>
      write(jsonEncode([for (final w in writes) w.toJson()]));
}

/// What one [Firestore.flushWrites] attempt did.
class FlushResult {
  const FlushResult({
    required this.replayed,
    required this.rejected,
    required this.pending,
  });

  /// Writes the server accepted, and which are now gone from the queue.
  final int replayed;

  /// Writes the server refused for a reason retrying cannot fix (a permission
  /// change, a failed `exists` precondition, a malformed path). Dropped from the
  /// queue, and reported here so the app can tell the user their change did not
  /// land instead of losing it silently.
  final List<({QueuedWrite write, Object error})> rejected;

  /// Writes still queued because the server could not be reached. The flush
  /// stops at the first of these rather than working through the rest, so order
  /// is preserved.
  final int pending;

  /// True when nothing is left to send.
  bool get isDrained => pending == 0;
}
