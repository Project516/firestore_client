import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import 'package:firestore_client/firestore_client.dart';

// #5 phase 2: a write made on venue wifi that drops has to survive and land
// later, in the order it was made, and a write the server *refuses* must not sit
// in the queue forever blocking everything behind it.
class _Client extends http.BaseClient {
  _Client(this.handler);

  final Future<http.Response> Function(http.BaseRequest request) handler;
  bool offline = false;
  final List<String> sent = <String>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (offline) throw const SocketException('Failed host lookup');
    sent.add('${request.method} ${request.url.path}');
    final response = await handler(request);
    return http.StreamedResponse(
      Stream<List<int>>.value(response.bodyBytes),
      response.statusCode,
      headers: response.headers,
      request: request,
    );
  }
}

Map<String, dynamic> _docJson(String path, Map<String, dynamic> fields) => {
      'name': 'projects/demo/databases/(default)/documents/$path',
      'fields': FirestoreValueCodec.encodeFields(fields),
      'updateTime': '2026-08-05T11:00:00Z',
    };

void main() {
  Firestore firestoreWith(
    _Client client, {
    FirestoreWriteQueue? queue,
    FirestoreCache? cache,
  }) =>
      Firestore(
        projectId: 'demo',
        idTokenProvider: () async => 'tok',
        httpClient: client,
        writeQueue: queue,
        cache: cache,
      );

  group('queued writes', () {
    test('a write made offline is kept and replayed', () async {
      final client = _Client(
        (request) async =>
            http.Response(jsonEncode(_docJson('teams/254', {'n': 1})), 200),
      );
      final queue = InMemoryWriteQueue();
      final firestore = firestoreWith(client, queue: queue);

      client.offline = true;
      final local = await firestore.setDocument('teams/254', {'nickname': 'X'});

      // The caller's own value, flagged, because the server has not seen it.
      expect(local.fields['nickname'], 'X');
      expect(local.fromCache, isTrue);
      expect(await firestore.pendingWriteCount, 1);

      client.offline = false;
      final result = await firestore.flushWrites();

      expect(result.replayed, 1);
      expect(result.isDrained, isTrue);
      expect(await firestore.pendingWriteCount, 0);
      expect(client.sent, [
        'PATCH /v1/projects/demo/databases/(default)'
            '/documents/teams/254'
      ]);
    });

    test('writes replay in the order they were made', () async {
      final client = _Client(
        (request) async =>
            http.Response(jsonEncode(_docJson('teams/254', {'n': 1})), 200),
      );
      final firestore = firestoreWith(client, queue: InMemoryWriteQueue());

      client.offline = true;
      await firestore.setDocument('teams/254', {'step': 1});
      await firestore.setDocument('teams/118', {'step': 2});
      await firestore.deleteDocument('teams/254');

      client.offline = false;
      final result = await firestore.flushWrites();

      expect(result.replayed, 3);
      // The delete must land after the write to the same document, or the
      // document comes back.
      expect(client.sent, <String>[
        'PATCH /v1/projects/demo/databases/(default)/documents/teams/254',
        'PATCH /v1/projects/demo/databases/(default)/documents/teams/118',
        'DELETE /v1/projects/demo/databases/(default)/documents/teams/254',
      ]);
    });

    test('a refused write is dropped and reported, not retried forever',
        () async {
      var deny = true;
      final client = _Client((request) async {
        if (deny) {
          return http.Response(
            jsonEncode({
              'error': {'message': 'denied', 'status': 'PERMISSION_DENIED'},
            }),
            403,
          );
        }
        return http.Response(jsonEncode(_docJson('teams/254', {'n': 1})), 200);
      });
      final firestore = firestoreWith(client, queue: InMemoryWriteQueue());

      client.offline = true;
      await firestore.setDocument('teams/254', {'a': 1});
      client.offline = false;

      final result = await firestore.flushWrites();

      // Kept in the queue it would block every later write behind it, forever.
      expect(result.replayed, 0);
      expect(result.pending, 0);
      expect(result.rejected, hasLength(1));
      expect(result.rejected.single.error, isA<FirestoreApiException>());
      expect(result.rejected.single.write.path, 'teams/254');
      expect(await firestore.pendingWriteCount, 0);

      deny = false;
    });

    test('the flush stops at the first unreachable write', () async {
      var failSecond = false;
      final client = _Client((request) async {
        if (failSecond && request.url.path.endsWith('118')) {
          return http.Response('{}', 503);
        }
        return http.Response(jsonEncode(_docJson('teams/254', {'n': 1})), 200);
      });
      final firestore = firestoreWith(client, queue: InMemoryWriteQueue());

      client.offline = true;
      await firestore.setDocument('teams/254', {'step': 1});
      await firestore.setDocument('teams/118', {'step': 2});
      await firestore.setDocument('teams/2056', {'step': 3});
      client.offline = false;
      failSecond = true;

      final result = await firestore.flushWrites();

      // The third is not attempted: sending it before the second lands would
      // reorder them.
      expect(result.replayed, 1);
      expect(result.pending, 2);
      expect(result.isDrained, isFalse);
      expect(client.sent.where((s) => s.endsWith('2056')), isEmpty);
    });

    test('a refused write does not block the ones behind it', () async {
      final client = _Client((request) async {
        if (request.url.path.endsWith('118')) {
          return http.Response(
            jsonEncode({
              'error': {'message': 'nope', 'status': 'PERMISSION_DENIED'},
            }),
            403,
          );
        }
        return http.Response(jsonEncode(_docJson('teams/254', {'n': 1})), 200);
      });
      final firestore = firestoreWith(client, queue: InMemoryWriteQueue());

      client.offline = true;
      await firestore.setDocument('teams/254', {'step': 1});
      await firestore.setDocument('teams/118', {'step': 2});
      await firestore.setDocument('teams/2056', {'step': 3});
      client.offline = false;

      final result = await firestore.flushWrites();

      expect(result.replayed, 2);
      expect(result.rejected, hasLength(1));
      expect(result.isDrained, isTrue);
    });

    test('a queued commit keeps its array transforms', () async {
      final client = _Client((request) async => http.Response('{}', 200));
      final firestore = firestoreWith(client, queue: InMemoryWriteQueue());

      client.offline = true;
      await firestore.commitUpdate(
        'events/2026txdri1',
        appendMissingElements: <String, List<Object?>>{
          'scouts': <Object?>['alex'],
        },
      );
      client.offline = false;

      final result = await firestore.flushWrites();

      expect(result.replayed, 1);
      // The transform is why a queued commit is safer than a queued set: the
      // server merges it, so two clients draining after an outage do not
      // overwrite each other.
      expect(client.sent.single, endsWith('/documents:commit'));
    });

    test('a create with no id is never queued', () async {
      final client = _Client((request) async => http.Response('{}', 200))
        ..offline = true;
      final firestore = firestoreWith(client, queue: InMemoryWriteQueue());

      // The id would come from the server, so there is no path to queue against
      // and no honest document to hand back.
      await expectLater(
        firestore.createDocument('teams', {'n': 1}),
        throwsA(isA<SocketException>()),
      );
      expect(await firestore.pendingWriteCount, 0);
    });

    test('a create with an explicit id is queued and replays as a set',
        () async {
      final client = _Client(
        (request) async =>
            http.Response(jsonEncode(_docJson('teams/254', {'n': 1})), 200),
      );
      final firestore = firestoreWith(client, queue: InMemoryWriteQueue());

      client.offline = true;
      final local = await firestore.createDocument(
        'teams',
        {'nickname': 'X'},
        id: '254',
      );
      expect(local.path, 'teams/254');
      expect(local.fromCache, isTrue);

      client.offline = false;
      await firestore.flushWrites();

      // A set, not a create: a second flush after a partial success would fail
      // on the create endpoint, and a set is what the caller meant anyway.
      expect(client.sent.single, startsWith('PATCH '));
    });

    test('an offline delete drops the cached copy immediately', () async {
      final cache = InMemoryFirestoreCache();
      final client = _Client(
        (request) async =>
            http.Response(jsonEncode(_docJson('teams/254', {'n': 1})), 200),
      );
      final firestore = firestoreWith(
        client,
        queue: InMemoryWriteQueue(),
        cache: cache,
      );
      await firestore.getDocument('teams/254');
      expect(cache.length, 1);

      client.offline = true;
      await firestore.deleteDocument('teams/254');

      // Otherwise the next offline read serves a document the caller has
      // already deleted. It throws rather than returning null, which is the
      // read path's own rule: nothing cached is no answer, not "no document".
      expect(cache.length, 0);
      await expectLater(
        firestore.getDocument('teams/254'),
        throwsA(isA<SocketException>()),
      );
    });

    test('with no queue configured a failed write still throws', () async {
      final client = _Client((request) async => http.Response('{}', 200))
        ..offline = true;
      final firestore = firestoreWith(client);

      expect(firestore.isQueueingWrites, isFalse);
      await expectLater(
        firestore.setDocument('teams/254', {'a': 1}),
        throwsA(isA<SocketException>()),
      );
      expect(await firestore.pendingWriteCount, 0);
    });

    test('flushing an empty queue is a no-op', () async {
      final client = _Client((request) async => http.Response('{}', 200));
      final firestore = firestoreWith(client, queue: InMemoryWriteQueue());

      final result = await firestore.flushWrites();

      expect(result.replayed, 0);
      expect(result.isDrained, isTrue);
      expect(client.sent, isEmpty);
    });
  });

  group('StringBackedWriteQueue', () {
    test('a queued write survives a new client over the same storage',
        () async {
      String? stored;
      FirestoreWriteQueue queue() => StringBackedWriteQueue(
            read: () async => stored,
            write: (value) async => stored = value,
          );
      final offline = _Client((request) async => http.Response('{}', 200))
        ..offline = true;
      await firestoreWith(offline, queue: queue()).setDocument(
        'teams/254',
        {'nickname': 'X', 'rank': 3},
      );

      // A relaunch: a new client over the same storage.
      final online = _Client(
        (request) async =>
            http.Response(jsonEncode(_docJson('teams/254', {'n': 1})), 200),
      );
      final second = firestoreWith(online, queue: queue());

      expect(await second.pendingWriteCount, 1);
      final result = await second.flushWrites();

      expect(result.replayed, 1);
      expect(online.sent.single, contains('/documents/teams/254'));
    });

    test('a corrupt or unreadable queue reads as empty', () async {
      final queue = StringBackedWriteQueue(
        read: () async => 'not json at all',
        write: (_) async {},
      );

      // There is nothing to recover, and failing every write because the queue
      // file is damaged would be worse than losing the queue.
      expect(await queue.load(), isEmpty);
    });

    test('an entry this version cannot read is skipped, not fatal', () async {
      final queue = StringBackedWriteQueue(
        read: () async => jsonEncode(<Object>[
          {'sequence': 1, 'kind': 'set', 'path': 'teams/254'},
          {'sequence': 2, 'kind': 'somethingNewer', 'path': 'teams/118'},
          {'sequence': 3, 'kind': 'delete', 'path': 'teams/2056'},
        ]),
        write: (_) async {},
      );

      final writes = await queue.load();

      expect(writes.map((w) => w.path), <String>['teams/254', 'teams/2056']);
    });
  });
}
