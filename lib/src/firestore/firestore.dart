import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'cache.dart';
import 'write_queue.dart';
import 'value_codec.dart';

/// A Firestore document: its path, decoded fields, and server timestamps.
class Document {
  const Document({
    required this.name,
    required this.fields,
    this.createTime,
    this.updateTime,
    this.fromCache = false,
  });

  /// Full resource name, `projects/{p}/databases/{d}/documents/{path}`.
  final String name;

  /// Decoded field values (see [FirestoreValueCodec] for supported types).
  final Map<String, dynamic> fields;

  final DateTime? createTime;
  final DateTime? updateTime;

  /// True when this document came from the offline cache rather than the
  /// server, so it may be stale. Callers that show data to a person should say
  /// so; callers that make decisions on it should treat it as a snapshot, not
  /// as the current state.
  final bool fromCache;

  /// A copy of this document marked as having come from the cache.
  Document asCached() => Document(
        name: name,
        fields: fields,
        createTime: createTime,
        updateTime: updateTime,
        fromCache: true,
      );

  /// The path below `/documents/`, e.g. `users/alice`.
  String get path {
    final i = name.indexOf('/documents/');
    return i < 0 ? name : name.substring(i + '/documents/'.length);
  }

  /// The last path segment (the document id).
  String get id => name.substring(name.lastIndexOf('/') + 1);

  static Document fromJson(Map<String, dynamic> json) => Document(
        name: json['name'] as String,
        fields: FirestoreValueCodec.decodeFields(
          (json['fields'] as Map?)?.cast<String, dynamic>(),
        ),
        createTime: json['createTime'] != null
            ? DateTime.parse(json['createTime'] as String).toUtc()
            : null,
        updateTime: json['updateTime'] != null
            ? DateTime.parse(json['updateTime'] as String).toUtc()
            : null,
      );
}

/// Error from the Firestore REST API.
class FirestoreApiException implements Exception {
  FirestoreApiException(this.statusCode, this.message, {this.status = ''});

  final int statusCode;
  final String message;

  /// The canonical gRPC status name from the error payload when present,
  /// e.g. `NOT_FOUND`, `PERMISSION_DENIED`, `FAILED_PRECONDITION`. Empty when
  /// the response carried no structured error.
  final String status;

  /// True when the error means the target document does not exist (a plain
  /// 404 or a failed `exists: true` precondition).
  bool get isNotFound =>
      statusCode == 404 ||
      status == 'NOT_FOUND' ||
      status == 'FAILED_PRECONDITION';

  @override
  String toString() => 'FirestoreApiException($statusCode $status): $message';
}

/// A single field filter for [Firestore.runQuery].
///
/// Operators follow the REST enum: `EQUAL`, `NOT_EQUAL`, `LESS_THAN`,
/// `LESS_THAN_OR_EQUAL`, `GREATER_THAN`, `GREATER_THAN_OR_EQUAL`,
/// `ARRAY_CONTAINS`, `IN`, `ARRAY_CONTAINS_ANY`, `NOT_IN`.
class FieldFilter {
  const FieldFilter(this.field, this.op, this.value);

  final String field;
  final String op;
  final Object? value;

  Map<String, dynamic> toJson() => {
        'fieldFilter': {
          'field': {'fieldPath': field},
          'op': op,
          'value': FirestoreValueCodec.encode(value),
        },
      };
}

/// A minimal Cloud Firestore client over the v1 REST API.
///
/// Authentication is delegated to [idTokenProvider], which returns a Firebase
/// ID token (or null when signed out; requests are then unauthenticated and
/// only succeed where the security rules allow public access).
class Firestore {
  Firestore({
    required this.projectId,
    required Future<String?> Function() idTokenProvider,
    this.databaseId = '(default)',
    http.Client? httpClient,
    FirestoreCache? cache,
    FirestoreWriteQueue? writeQueue,
  })  : _idToken = idTokenProvider,
        _http = httpClient ?? http.Client(),
        _cache = cache,
        _queue = writeQueue;

  final String projectId;
  final String databaseId;
  final Future<String?> Function() _idToken;
  final http.Client _http;

  /// Where successful reads are kept so they can be served again when the
  /// server cannot be reached. Null disables caching entirely, which is the
  /// default: a cache is a place on disk and only the host app knows where that
  /// should be.
  final FirestoreCache? _cache;

  /// Where writes wait when the server cannot be reached. Null disables
  /// queueing, which is the default: a queued write changes what a failed write
  /// means, and that has to be the caller's choice.
  final FirestoreWriteQueue? _queue;

  /// True when the client has somewhere to cache reads.
  bool get isCaching => _cache != null;

  /// True when the client has somewhere to queue writes.
  bool get isQueueingWrites => _queue != null;

  /// How many writes are waiting to be sent.
  Future<int> get pendingWriteCount async =>
      (await _queue?.load())?.length ?? 0;

  /// Sends the queued writes, oldest first, and reports what happened.
  ///
  /// Stops at the first write the server cannot be reached for, leaving it and
  /// everything after it queued: replaying out of order would let a later write
  /// land before an earlier one to the same document. A write the server
  /// *refuses* is dropped and reported in [FlushResult.rejected], because
  /// retrying it forever would block the queue behind it.
  ///
  /// Safe to call when nothing is queued, and safe to call repeatedly.
  Future<FlushResult> flushWrites() async {
    final queue = _queue;
    if (queue == null) {
      return const FlushResult(replayed: 0, rejected: [], pending: 0);
    }
    final writes = await queue.load()
      ..sort((a, b) => a.sequence.compareTo(b.sequence));
    var replayed = 0;
    final rejected = <({QueuedWrite write, Object error})>[];
    final remaining = <QueuedWrite>[];
    for (var i = 0; i < writes.length; i++) {
      final write = writes[i];
      if (remaining.isNotEmpty) {
        // Already stopped on an unreachable server; everything after it keeps
        // its place in line.
        remaining.add(write);
        continue;
      }
      try {
        await _send(write);
        replayed++;
      } catch (error) {
        if (_isUnreachable(error)) {
          remaining.add(write);
        } else {
          rejected.add((write: write, error: error));
        }
      }
    }
    await queue.save(remaining);
    return FlushResult(
      replayed: replayed,
      rejected: rejected,
      pending: remaining.length,
    );
  }

  /// Replays one queued write against the server.
  Future<void> _send(QueuedWrite write) {
    switch (write.kind) {
      case QueuedWriteKind.create:
      case QueuedWriteKind.set:
        // A queued create replays as a set against its explicit path. The
        // create endpoint would fail the second time a flush ran after a
        // partial success, and a set is what the caller meant either way.
        return _setDocumentRemote(
          write.path,
          write.fields,
          updateMask: write.updateMask,
        );
      case QueuedWriteKind.commit:
        return _commitUpdateRemote(
          write.path,
          fields: write.fields,
          updateMask: write.updateMask,
          appendMissingElements: write.appendMissingElements,
          removeAllFromArray: write.removeAllFromArray,
          mustExist: write.mustExist,
        );
      case QueuedWriteKind.delete:
        return _deleteDocumentRemote(write.path);
    }
  }

  /// Whether [error] means the server was never reached, so the write should
  /// stay queued rather than being reported as refused.
  ///
  /// Same rule as the read path: an answer from the server, unless it says the
  /// server was temporarily unable to give one.
  bool _isUnreachable(Object error) {
    if (error is! FirestoreApiException) return true;
    return error.statusCode == 429 || error.statusCode >= 500;
  }

  /// Adds [write] to the queue and returns true, or returns false when there is
  /// no queue and the caller should see the original failure.
  Future<bool> _enqueue(QueuedWrite Function(int sequence) build) async {
    final queue = _queue;
    if (queue == null) return false;
    final writes = await queue.load();
    final next = writes.isEmpty
        ? 1
        : writes.map((w) => w.sequence).reduce((a, b) => a > b ? a : b) + 1;
    await queue.save(<QueuedWrite>[...writes, build(next)]);
    return true;
  }

  /// Drops every cached read. Call it on sign-out: the cache holds documents
  /// the previous user was allowed to see.
  Future<void> clearCache() async => _cache?.clear();

  /// Cache key for a read. Namespaced by project and database so two clients in
  /// one process cannot answer each other's reads, and prefixed by the kind of
  /// read so a document and a query over the same path stay separate.
  String _cacheKey(String kind, String target) =>
      'firestore_client/v1/$projectId/$databaseId/$kind/$target';

  /// Whether [error] means the server was never reached, or reached and could
  /// not answer, so a cached payload is the better response.
  ///
  /// Anything that is not a [FirestoreApiException] never got an answer at all
  /// (socket, DNS, timeout, a client that was closed). A [FirestoreApiException]
  /// did get one, so it is only cache-eligible when the server said it was
  /// temporarily unable: 429 and 5xx. A 403 or 404 is a real answer and must not
  /// be papered over with stale data.
  bool _shouldServeFromCache(Object error) {
    if (error is! FirestoreApiException) return true;
    return error.statusCode == 429 || error.statusCode >= 500;
  }

  /// Runs [request], caching a success and falling back to the cached payload
  /// when the server could not answer.
  ///
  /// Returns the payload and whether it came from the cache, so the caller can
  /// mark what it decodes as stale. A read with nothing cached rethrows the
  /// original failure: there is no better answer to give.
  ///
  /// [cacheable] is false for a response that must not be stored, such as the
  /// empty body standing in for a 404.
  Future<({String payload, bool fromCache})> _cachedRead(
    String key,
    Future<String> Function() request, {
    bool Function(String payload)? cacheable,
  }) async {
    final cache = _cache;
    if (cache == null) {
      return (payload: await request(), fromCache: false);
    }
    final String payload;
    try {
      payload = await request();
    } catch (error) {
      if (!_shouldServeFromCache(error)) rethrow;
      final cached = await cache.read(key);
      if (cached == null) rethrow;
      return (payload: cached, fromCache: true);
    }
    // Outside the try above on purpose. A FirestoreCache is a public interface,
    // so a host implementation may throw from write; with the write inside the
    // try, that threw into the catch, which then discarded the payload the
    // server had just returned and answered with an older cached one marked
    // fromCache. A cache that cannot be written is a lost optimisation, never a
    // reason to serve stale data over fresh.
    if (cacheable?.call(payload) ?? true) {
      try {
        await cache.write(key, payload);
      } catch (_) {
        // Deliberately swallowed: see above.
      }
    }
    return (payload: payload, fromCache: false);
  }

  String get _documentsUrl =>
      'https://firestore.googleapis.com/v1/projects/$projectId'
      '/databases/$databaseId/documents';

  Future<Map<String, String>> _headers() async {
    final token = await _idToken();
    return {
      'Content-Type': 'application/json',
      if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
    };
  }

  Never _throw(http.Response response) {
    String message = response.body;
    String status = '';
    try {
      final decoded = jsonDecode(response.body);
      final error = decoded is List
          // Batch endpoints (e.g. commit) wrap the error in a one-item array.
          ? (decoded.first as Map)['error']
          : decoded['error'];
      message = (error?['message'] as String?) ?? message;
      status = (error?['status'] as String?) ?? '';
    } catch (_) {
      // Keep the raw body.
    }
    throw FirestoreApiException(response.statusCode, message, status: status);
  }

  /// Fetches the document at [path] (e.g. `users/alice`); null on 404.
  ///
  /// With a cache configured, a successful read is stored, and a later read that
  /// cannot reach the server is answered from it with [Document.fromCache] set.
  /// A 404 drops any cached copy: the document is gone, and serving the old one
  /// would resurrect it.
  Future<Document?> getDocument(String path) async {
    final key = _cacheKey('doc', path);
    // A deleted document has no payload to cache or decode, so it short-circuits
    // rather than going through _cachedRead. A 404 is a real answer; it is not
    // cache-eligible, and _shouldServeFromCache would not have served it anyway.
    var deleted = false;
    final read = await _cachedRead(
      key,
      () async {
        final response = await _http.get(
          Uri.parse('$_documentsUrl/$path'),
          headers: await _headers(),
        );
        if (response.statusCode == 404) {
          deleted = true;
          return '';
        }
        if (response.statusCode != 200) _throw(response);
        return response.body;
      },
      // The 404 stand-in must not be written, even for the moment before the
      // removal below: a concurrent read falling back inside that window would
      // get '' and throw FormatException out of jsonDecode.
      cacheable: (_) => !deleted,
    );
    if (deleted) {
      await _cache?.remove(key);
      return null;
    }
    final document = Document.fromJson(
      jsonDecode(read.payload) as Map<String, dynamic>,
    );
    return read.fromCache ? document.asCached() : document;
  }

  /// Creates a document in [collectionPath]. With [id] the write fails if the
  /// document already exists; without it Firestore assigns a random id.
  Future<Document> createDocument(
    String collectionPath,
    Map<String, dynamic> data, {
    String? id,
  }) async {
    final uri = Uri.parse('$_documentsUrl/$collectionPath').replace(
      queryParameters: {if (id != null) 'documentId': id},
    );
    try {
      final response = await _http.post(
        uri,
        headers: await _headers(),
        body: jsonEncode({'fields': FirestoreValueCodec.encodeFields(data)}),
      );
      if (response.statusCode != 200) _throw(response);
      return Document.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>,
      );
    } catch (error) {
      // Only an explicit id can be queued. Without one the id comes from the
      // server, and handing the caller an invented id would name a document
      // that may never exist under that name.
      if (id == null || !_isUnreachable(error)) rethrow;
      final path = '$collectionPath/$id';
      final queued = await _enqueue(
        (sequence) => QueuedWrite(
          sequence: sequence,
          kind: QueuedWriteKind.create,
          path: path,
          fields: data,
        ),
      );
      if (!queued) rethrow;
      return _localDocument(path, data);
    }
  }

  /// Writes the document at [path], creating or fully replacing it. With
  /// [updateMask] only the named fields are changed and the rest of the
  /// document is preserved (a merge/partial update).
  ///
  /// With a write queue configured, a write that cannot reach the server is
  /// queued and a local [Document] is returned with [Document.fromCache] set:
  /// the caller's own value, not the server's, because the server has not seen
  /// it yet. Call [flushWrites] when the network is back.
  Future<Document> setDocument(
    String path,
    Map<String, dynamic> data, {
    List<String>? updateMask,
  }) async {
    try {
      return await _setDocumentReturning(path, data, updateMask: updateMask);
    } catch (error) {
      if (!_isUnreachable(error)) rethrow;
      final queued = await _enqueue(
        (sequence) => QueuedWrite(
          sequence: sequence,
          kind: QueuedWriteKind.set,
          path: path,
          fields: data,
          updateMask: updateMask,
        ),
      );
      if (!queued) rethrow;
      return _localDocument(path, data);
    }
  }

  /// The document the caller just wrote, as this client understands it while the
  /// write is still queued. Marked [Document.fromCache], and carrying no
  /// `createTime` or `updateTime`, because only the server can set those.
  Document _localDocument(String path, Map<String, dynamic> fields) => Document(
        name: 'projects/$projectId/databases/$databaseId/documents/$path',
        fields: Map<String, dynamic>.unmodifiable(fields),
        fromCache: true,
      );

  Future<Document> _setDocumentReturning(
    String path,
    Map<String, dynamic> data, {
    List<String>? updateMask,
  }) async {
    final response = await _patch(path, data, updateMask: updateMask);
    return Document.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  Future<void> _setDocumentRemote(
    String path,
    Map<String, dynamic> data, {
    List<String>? updateMask,
  }) async {
    await _patch(path, data, updateMask: updateMask);
  }

  Future<http.Response> _patch(
    String path,
    Map<String, dynamic> data, {
    List<String>? updateMask,
  }) async {
    // updateMask.fieldPaths is a repeated query parameter, which
    // Uri.queryParameters cannot express; build it by hand.
    var url = '$_documentsUrl/$path';
    if (updateMask != null && updateMask.isNotEmpty) {
      final params = updateMask
          .map((f) => 'updateMask.fieldPaths=${Uri.encodeQueryComponent(f)}')
          .join('&');
      url = '$url${url.contains('?') ? '&' : '?'}$params';
    }
    final response = await _http.patch(
      Uri.parse(url),
      headers: await _headers(),
      body: jsonEncode({'fields': FirestoreValueCodec.encodeFields(data)}),
    );
    if (response.statusCode != 200) _throw(response);
    return response;
  }

  /// Updates the document at [path] through `documents:commit`, queueing it when
  /// the server cannot be reached.
  ///
  /// Prefer this over [setDocument] for a queued write that others may also be
  /// making: [appendMissingElements] and [removeAllFromArray] are applied by the
  /// server, so two clients replaying after an outage merge instead of
  /// overwriting each other. A plain field set is last-write-wins, which for a
  /// queued write means last-*replayed*-wins.
  Future<void> commitUpdate(
    String path, {
    Map<String, dynamic> fields = const {},
    List<String>? updateMask,
    Map<String, List<Object?>> appendMissingElements = const {},
    Map<String, List<Object?>> removeAllFromArray = const {},
    bool mustExist = false,
  }) async {
    try {
      await _commitUpdateRemote(
        path,
        fields: fields,
        updateMask: updateMask,
        appendMissingElements: appendMissingElements,
        removeAllFromArray: removeAllFromArray,
        mustExist: mustExist,
      );
    } catch (error) {
      if (!_isUnreachable(error)) rethrow;
      final queued = await _enqueue(
        (sequence) => QueuedWrite(
          sequence: sequence,
          kind: QueuedWriteKind.commit,
          path: path,
          fields: fields,
          updateMask: updateMask ?? fields.keys.toList(growable: false),
          appendMissingElements: appendMissingElements,
          removeAllFromArray: removeAllFromArray,
          mustExist: mustExist,
        ),
      );
      if (!queued) rethrow;
    }
  }

  /// Updates the document at [path] through `documents:commit`, which is the
  /// only REST surface that supports server-side field transforms.
  ///
  /// [fields] (masked by [updateMask], or by its own keys when the mask is
  /// omitted) are plain sets. [appendMissingElements] and [removeAllFromArray]
  /// are atomic array transforms, the REST equivalents of the SDKs'
  /// `arrayUnion`/`arrayRemove`: concurrent writers merge instead of
  /// overwriting each other. With [mustExist] the write fails (`NOT_FOUND` /
  /// `FAILED_PRECONDITION`, see [FirestoreApiException.isNotFound]) instead of
  /// creating the document.
  Future<void> _commitUpdateRemote(
    String path, {
    Map<String, dynamic> fields = const {},
    List<String>? updateMask,
    Map<String, List<Object?>> appendMissingElements = const {},
    Map<String, List<Object?>> removeAllFromArray = const {},
    bool mustExist = false,
  }) async {
    final write = <String, dynamic>{
      'update': {
        'name': 'projects/$projectId/databases/$databaseId'
            '/documents/$path',
        'fields': FirestoreValueCodec.encodeFields(fields),
      },
      'updateMask': {
        'fieldPaths': updateMask ?? fields.keys.toList(),
      },
      if (mustExist) 'currentDocument': {'exists': true},
      if (appendMissingElements.isNotEmpty || removeAllFromArray.isNotEmpty)
        'updateTransforms': [
          for (final e in appendMissingElements.entries)
            {
              'fieldPath': e.key,
              'appendMissingElements': {
                'values': [
                  for (final v in e.value) FirestoreValueCodec.encode(v)
                ],
              },
            },
          for (final e in removeAllFromArray.entries)
            {
              'fieldPath': e.key,
              'removeAllFromArray': {
                'values': [
                  for (final v in e.value) FirestoreValueCodec.encode(v)
                ],
              },
            },
        ],
    };
    final url = 'https://firestore.googleapis.com/v1/projects/$projectId'
        '/databases/$databaseId/documents:commit';
    final response = await _http.post(
      Uri.parse(url),
      headers: await _headers(),
      body: jsonEncode({
        'writes': [write],
      }),
    );
    if (response.statusCode != 200) _throw(response);
  }

  /// Deletes the document at [path]. Deleting a missing document succeeds.
  ///
  /// Queued when the server cannot be reached, and the cached copy is dropped
  /// immediately so a later read does not serve a document the caller has
  /// already deleted.
  Future<void> deleteDocument(String path) async {
    try {
      await _deleteDocumentRemote(path);
    } catch (error) {
      if (!_isUnreachable(error)) rethrow;
      final queued = await _enqueue(
        (sequence) => QueuedWrite(
          sequence: sequence,
          kind: QueuedWriteKind.delete,
          path: path,
        ),
      );
      if (!queued) rethrow;
    }
    await _cache?.remove(_cacheKey('doc', path));
  }

  Future<void> _deleteDocumentRemote(String path) async {
    final response = await _http.delete(
      Uri.parse('$_documentsUrl/$path'),
      headers: await _headers(),
    );
    if (response.statusCode != 200) _throw(response);
  }

  /// Lists every document in [collectionPath], following pagination.
  ///
  /// With a cache configured, the assembled list is cached as one payload, and a
  /// list that cannot reach the server is served from it with every
  /// [Document.fromCache] set. A partial fetch is never cached: if page three
  /// fails, the cached list would silently lose everything after page two.
  Future<List<Document>> listDocuments(
    String collectionPath, {
    int pageSize = 300,
  }) async {
    final read = await _cachedRead(_cacheKey('list', collectionPath), () async {
      final documents = <Map<String, dynamic>>[];
      String? pageToken;
      do {
        final uri = Uri.parse('$_documentsUrl/$collectionPath').replace(
          queryParameters: {
            'pageSize': '$pageSize',
            if (pageToken != null) 'pageToken': pageToken,
          },
        );
        final response = await _http.get(uri, headers: await _headers());
        if (response.statusCode != 200) _throw(response);
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        for (final doc in (json['documents'] as List? ?? const [])) {
          documents.add((doc as Map).cast<String, dynamic>());
        }
        pageToken = json['nextPageToken'] as String?;
      } while (pageToken != null);
      return jsonEncode({'documents': documents});
    });
    final json = jsonDecode(read.payload) as Map<String, dynamic>;
    return [
      for (final doc in (json['documents'] as List? ?? const []))
        _decode((doc as Map).cast<String, dynamic>(), read.fromCache),
    ];
  }

  static Document _decode(Map<String, dynamic> json, bool fromCache) {
    final document = Document.fromJson(json);
    return fromCache ? document.asCached() : document;
  }

  /// Runs a structured query over the top-level collection [collectionId].
  ///
  /// Multiple [filters] are combined with AND. [orderBy] is a field path,
  /// with [descending] controlling its direction.
  Future<List<Document>> runQuery(
    String collectionId, {
    List<FieldFilter> filters = const [],
    String? orderBy,
    bool descending = false,
    int? limit,
  }) async {
    final structuredQuery = <String, dynamic>{
      'from': [
        {'collectionId': collectionId},
      ],
      if (filters.length == 1) 'where': filters.single.toJson(),
      if (filters.length > 1)
        'where': {
          'compositeFilter': {
            'op': 'AND',
            'filters': [for (final f in filters) f.toJson()],
          },
        },
      if (orderBy != null)
        'orderBy': [
          {
            'field': {'fieldPath': orderBy},
            'direction': descending ? 'DESCENDING' : 'ASCENDING',
          },
        ],
      if (limit != null) 'limit': limit,
    };
    final body = jsonEncode({'structuredQuery': structuredQuery});
    // Keyed by the query itself, not just the collection: two different filters
    // over one collection are two different reads and must not overwrite each
    // other's cached answer.
    final read = await _cachedRead(_cacheKey('query', body), () async {
      final response = await _http.post(
        Uri.parse('$_documentsUrl:runQuery'),
        headers: await _headers(),
        body: body,
      );
      if (response.statusCode != 200) _throw(response);
      return response.body;
    });
    final rows = jsonDecode(read.payload) as List<dynamic>;
    return [
      for (final row in rows)
        if ((row as Map)['document'] != null)
          _decode(
              (row['document'] as Map).cast<String, dynamic>(), read.fromCache),
    ];
  }

  /// Polls [collectionPath] every [interval] and emits the full document list
  /// whenever any document's `updateTime` (or the document count) changes.
  ///
  /// Firestore's realtime `Listen` API is gRPC-only; polling is the honest REST
  /// equivalent and is adequate for team-tool sync loops. The first emission
  /// happens immediately on listen.
  ///
  /// Cancelling the subscription stops the loop promptly, even while it is
  /// waiting for [interval] between polls: the pending wait resolves early
  /// instead of letting the loop run a final poll after cancellation.
  Stream<List<Document>> pollCollection(
    String collectionPath, {
    Duration interval = const Duration(seconds: 30),
  }) {
    String fingerprint(List<Document> docs) => docs
        .map((d) => '${d.name}@${d.updateTime?.microsecondsSinceEpoch}')
        .join('|');
    // Completes as soon as the listener cancels, so the delay between polls
    // can return early instead of outliving the subscription. Using a
    // StreamController lets us observe cancellation independently of the
    // polling loop, which runs as a plain async function feeding the sink.
    final cancellation = Completer<void>();
    late final StreamController<List<Document>> controller;
    controller = StreamController<List<Document>>(
      onListen: () => _poll(
          collectionPath, interval, fingerprint, controller.sink, cancellation),
      onCancel: () {
        if (!cancellation.isCompleted) cancellation.complete();
      },
    );
    return controller.stream;
  }

  Future<void> _poll(
    String collectionPath,
    Duration interval,
    String Function(List<Document>) fingerprint,
    StreamSink<List<Document>> sink,
    Completer<void> cancellation,
  ) async {
    String? last;
    while (!cancellation.isCompleted) {
      List<Document>? docs;
      try {
        docs = await listDocuments(collectionPath);
      } catch (_) {
        // Transient failure (offline, auth refresh in flight): keep polling.
      }
      if (docs != null) {
        final current = fingerprint(docs);
        if (current != last) {
          last = current;
          if (!cancellation.isCompleted) sink.add(docs);
        }
      }
      if (cancellation.isCompleted) break;
      await Future.any([
        Future<void>.delayed(interval),
        cancellation.future,
      ]);
    }
    await sink.close();
  }

  void close() {
    _http.close();
  }
}
