import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'value_codec.dart';

/// A Firestore document: its path, decoded fields, and server timestamps.
class Document {
  const Document({
    required this.name,
    required this.fields,
    this.createTime,
    this.updateTime,
  });

  /// Full resource name, `projects/{p}/databases/{d}/documents/{path}`.
  final String name;

  /// Decoded field values (see [FirestoreValueCodec] for supported types).
  final Map<String, dynamic> fields;

  final DateTime? createTime;
  final DateTime? updateTime;

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
  })  : _idToken = idTokenProvider,
        _http = httpClient ?? http.Client();

  final String projectId;
  final String databaseId;
  final Future<String?> Function() _idToken;
  final http.Client _http;

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
  Future<Document?> getDocument(String path) async {
    final response = await _http.get(
      Uri.parse('$_documentsUrl/$path'),
      headers: await _headers(),
    );
    if (response.statusCode == 404) return null;
    if (response.statusCode != 200) _throw(response);
    return Document.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
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
    final response = await _http.post(
      uri,
      headers: await _headers(),
      body: jsonEncode({'fields': FirestoreValueCodec.encodeFields(data)}),
    );
    if (response.statusCode != 200) _throw(response);
    return Document.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  /// Writes the document at [path], creating or fully replacing it. With
  /// [updateMask] only the named fields are changed and the rest of the
  /// document is preserved (a merge/partial update).
  Future<Document> setDocument(
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
    return Document.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
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
  Future<void> commitUpdate(
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
  Future<void> deleteDocument(String path) async {
    final response = await _http.delete(
      Uri.parse('$_documentsUrl/$path'),
      headers: await _headers(),
    );
    if (response.statusCode != 200) _throw(response);
  }

  /// Lists every document in [collectionPath], following pagination.
  Future<List<Document>> listDocuments(
    String collectionPath, {
    int pageSize = 300,
  }) async {
    final results = <Document>[];
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
        results.add(Document.fromJson((doc as Map).cast<String, dynamic>()));
      }
      pageToken = json['nextPageToken'] as String?;
    } while (pageToken != null);
    return results;
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
    final response = await _http.post(
      Uri.parse('$_documentsUrl:runQuery'),
      headers: await _headers(),
      body: jsonEncode({'structuredQuery': structuredQuery}),
    );
    if (response.statusCode != 200) _throw(response);
    final rows = jsonDecode(response.body) as List<dynamic>;
    return [
      for (final row in rows)
        if ((row as Map)['document'] != null)
          Document.fromJson((row['document'] as Map).cast<String, dynamic>()),
    ];
  }

  /// Polls [collectionPath] every [interval] and emits the full document list
  /// whenever any document's `updateTime` (or the document count) changes.
  ///
  /// Firestore's realtime `Listen` API is gRPC-only; polling is the honest
  /// REST equivalent and is adequate for team-tool sync loops. The first
  /// emission happens immediately on listen.
  Stream<List<Document>> pollCollection(
    String collectionPath, {
    Duration interval = const Duration(seconds: 30),
  }) async* {
    String fingerprint(List<Document> docs) => docs
        .map((d) => '${d.name}@${d.updateTime?.microsecondsSinceEpoch}')
        .join('|');
    String? last;
    while (true) {
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
          yield docs;
        }
      }
      await Future<void>.delayed(interval);
    }
  }

  void close() {
    _http.close();
  }
}
