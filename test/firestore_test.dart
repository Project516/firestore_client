import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

import 'package:firestore_client/firestore_client.dart';

Firestore _firestore(MockClient client, {String? token = 'tok'}) => Firestore(
      projectId: 'demo',
      idTokenProvider: () async => token,
      httpClient: client,
    );

Map<String, dynamic> _docJson(String path, Map<String, dynamic> fields) => {
      'name': 'projects/demo/databases/(default)/documents/$path',
      'fields': FirestoreValueCodec.encodeFields(fields),
      'createTime': '2026-07-08T10:00:00Z',
      'updateTime': '2026-07-08T11:00:00Z',
    };

void main() {
  group('Firestore', () {
    test('getDocument decodes fields and metadata', () async {
      final client = MockClient((request) async {
        expect(
          request.url.toString(),
          'https://firestore.googleapis.com/v1/projects/demo'
          '/databases/(default)/documents/users/alice',
        );
        expect(request.headers['Authorization'], 'Bearer tok');
        return http.Response(
          jsonEncode(_docJson('users/alice', {'name': 'Alice', 'score': 3})),
          200,
        );
      });
      final doc = await _firestore(client).getDocument('users/alice');
      expect(doc, isNotNull);
      expect(doc!.id, 'alice');
      expect(doc.path, 'users/alice');
      expect(doc.fields, {'name': 'Alice', 'score': 3});
      expect(doc.updateTime, DateTime.utc(2026, 7, 8, 11));
    });

    test('getDocument returns null on 404', () async {
      final client = MockClient((_) async => http.Response('missing', 404));
      expect(await _firestore(client).getDocument('users/nobody'), isNull);
    });

    test('errors surface the API message', () async {
      final client = MockClient(
        (_) async => http.Response(
          jsonEncode({
            'error': {'code': 403, 'message': 'Missing permissions.'},
          }),
          403,
        ),
      );
      await expectLater(
        _firestore(client).getDocument('users/alice'),
        throwsA(
          isA<FirestoreApiException>()
              .having((e) => e.statusCode, 'statusCode', 403)
              .having((e) => e.message, 'message', 'Missing permissions.'),
        ),
      );
    });

    test('setDocument sends an updateMask as repeated params', () async {
      late Uri captured;
      final client = MockClient((request) async {
        captured = request.url;
        expect(request.method, 'PATCH');
        return http.Response(jsonEncode(_docJson('users/alice', {})), 200);
      });
      await _firestore(client).setDocument(
        'users/alice',
        {'score': 4},
        updateMask: ['score', 'updated at'],
      );
      final params = captured.query.split('&');
      expect(params, contains('updateMask.fieldPaths=score'));
      expect(params, contains('updateMask.fieldPaths=updated+at'));
    });

    test('listDocuments follows pagination', () async {
      var call = 0;
      final client = MockClient((request) async {
        call++;
        if (call == 1) {
          expect(request.url.queryParameters['pageToken'], isNull);
          return http.Response(
            jsonEncode({
              'documents': [
                _docJson('users/a', {'n': 1})
              ],
              'nextPageToken': 'page2',
            }),
            200,
          );
        }
        expect(request.url.queryParameters['pageToken'], 'page2');
        return http.Response(
          jsonEncode({
            'documents': [
              _docJson('users/b', {'n': 2})
            ],
          }),
          200,
        );
      });
      final docs = await _firestore(client).listDocuments('users');
      expect(docs.map((d) => d.id), ['a', 'b']);
    });

    test('runQuery builds a composite AND filter and decodes rows', () async {
      final client = MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final query = body['structuredQuery'] as Map<String, dynamic>;
        expect(query['from'], [
          {'collectionId': 'entries'},
        ]);
        final where = query['where'] as Map<String, dynamic>;
        final composite = where['compositeFilter'] as Map<String, dynamic>;
        expect(composite['op'], 'AND');
        expect((composite['filters'] as List).length, 2);
        expect(query['limit'], 10);
        return http.Response(
          jsonEncode([
            {
              'document': _docJson('entries/e1', {'team': 1234})
            },
            {'readTime': '2026-07-08T11:00:00Z'},
          ]),
          200,
        );
      });
      final docs = await _firestore(client).runQuery(
        'entries',
        filters: const [
          FieldFilter('team', 'EQUAL', 1234),
          FieldFilter('match', 'GREATER_THAN', 10),
        ],
        limit: 10,
      );
      expect(docs.single.fields['team'], 1234);
    });

    test('commitUpdate sends field transforms and a precondition', () async {
      late Map<String, dynamic> body;
      final client = MockClient((request) async {
        expect(request.url.path, endsWith('documents:commit'));
        body = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response('{}', 200);
      });
      await _firestore(client).commitUpdate(
        'pickLists/l1',
        fields: {'updatedAt': '2026-07-08T12:00:00.000Z'},
        appendMissingElements: {
          'teamNumbers': [1234],
        },
        mustExist: true,
      );
      final write =
          ((body['writes'] as List).single as Map).cast<String, dynamic>();
      expect(
        (write['update'] as Map)['name'],
        'projects/demo/databases/(default)/documents/pickLists/l1',
      );
      expect((write['updateMask'] as Map)['fieldPaths'], ['updatedAt']);
      expect((write['currentDocument'] as Map)['exists'], isTrue);
      final transform = ((write['updateTransforms'] as List).single as Map)
          .cast<String, dynamic>();
      expect(transform['fieldPath'], 'teamNumbers');
      expect(
        ((transform['appendMissingElements'] as Map)['values'] as List).single,
        {'integerValue': '1234'},
      );
    });

    test('commitUpdate surfaces NOT_FOUND as isNotFound', () async {
      final client = MockClient(
        (_) async => http.Response(
          jsonEncode([
            {
              'error': {
                'code': 404,
                'message': 'No document to update',
                'status': 'NOT_FOUND',
              },
            },
          ]),
          400,
        ),
      );
      await expectLater(
        _firestore(client).commitUpdate(
          'pickLists/l1',
          fields: {'updatedAt': 'x'},
          mustExist: true,
        ),
        throwsA(
          isA<FirestoreApiException>()
              .having((e) => e.isNotFound, 'isNotFound', isTrue)
              .having((e) => e.status, 'status', 'NOT_FOUND'),
        ),
      );
    });

    test('unauthenticated requests omit the Authorization header', () async {
      final client = MockClient((request) async {
        expect(request.headers.containsKey('Authorization'), isFalse);
        return http.Response('missing', 404);
      });
      await _firestore(client, token: null).getDocument('users/alice');
    });
    test(
        'pollCollection emits the initial snapshot then suppresses unchanged '
        'snapshots', () async {
      var call = 0;
      final client = MockClient((_) async {
        call++;
        // The document is identical on every poll, so the fingerprint never
        // changes; only the first snapshot should be emitted, no matter how
        // many polls follow.
        return http.Response(
          jsonEncode({
            'documents': [
              {
                'name': 'projects/demo/databases/(default)/documents/users/a',
                'fields': {'n': FirestoreValueCodec.encode(1)},
                'createTime': '2026-07-08T10:00:00Z',
                'updateTime': '2026-07-08T11:00:00Z',
              },
            ],
          }),
          200,
        );
      });
      final stream = _firestore(client).pollCollection(
        'users',
        interval: const Duration(milliseconds: 50),
      );
      final emissions = <List<Document>>[];
      final sub = stream.listen(emissions.add);
      // Long enough for several polls, each returning the same document.
      await Future<void>.delayed(const Duration(milliseconds: 270));
      await sub.cancel();
      expect(emissions.length, 1);
      expect(call, greaterThanOrEqualTo(3));
      expect(emissions.single.single.fields['n'], 1);
    });

    test('pollCollection re-emits when a document changes', () async {
      var call = 0;
      final client = MockClient((_) async {
        call++;
        // The document's updateTime advances on every poll, so the fingerprint
        // changes and pollCollection re-emits each time.
        return http.Response(
          jsonEncode({
            'documents': [
              {
                'name': 'projects/demo/databases/(default)/documents/users/a',
                'fields': {'n': FirestoreValueCodec.encode(call)},
                'createTime': '2026-07-08T10:00:00Z',
                'updateTime': '2026-07-08T11:00:0${call}Z',
              },
            ],
          }),
          200,
        );
      });
      final stream = _firestore(client).pollCollection(
        'users',
        interval: const Duration(milliseconds: 50),
      );
      final emissions = <List<Document>>[];
      final sub = stream.listen(emissions.add);
      await Future<void>.delayed(const Duration(milliseconds: 270));
      await sub.cancel();
      expect(emissions.length, greaterThanOrEqualTo(2));
      expect(emissions.first.single.fields['n'], 1);
      final counts = emissions.map((e) => e.single.fields['n'] as int).toList();
      for (var i = 1; i < counts.length; i++) {
        expect(counts[i], greaterThan(counts[i - 1]));
      }
    });

    test('pollCollection stops polling after the subscription is cancelled',
        () async {
      var call = 0;
      final client = MockClient((_) async {
        call++;
        return http.Response(
          jsonEncode({
            'documents': [
              _docJson('users/a', {'n': call})
            ]
          }),
          200,
        );
      });
      final stream = _firestore(client).pollCollection(
        'users',
        interval: const Duration(milliseconds: 50),
      );
      final sub = stream.listen((_) {});
      // Let the first poll land, then cancel while it is waiting for the next.
      await Future<void>.delayed(const Duration(milliseconds: 80));
      final callsBeforeCancel = call;
      await sub.cancel();
      // Plenty of time for two more poll intervals to have fired if the loop
      // ignored cancellation.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(call, callsBeforeCancel);
    });
  });
}
