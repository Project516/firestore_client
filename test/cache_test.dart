import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import 'package:firestore_client/firestore_client.dart';

/// A client that answers through [handler] until [offline] is set, and then
/// fails the way a dead network does: no response at all.
class _SwitchableClient extends http.BaseClient {
  _SwitchableClient(this.handler);

  final Future<http.Response> Function(http.BaseRequest request) handler;
  bool offline = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (offline) {
      throw const SocketException('Failed host lookup');
    }
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
  group('cached reads', () {
    test('a document survives the network going away', () async {
      final client = _SwitchableClient(
        (request) async => http.Response(
          jsonEncode(_docJson('users/alice', {'name': 'Alice'})),
          200,
        ),
      );
      final cache = InMemoryFirestoreCache();
      final firestore = Firestore(
        projectId: 'demo',
        idTokenProvider: () async => 'tok',
        httpClient: client,
        cache: cache,
      );

      final fresh = await firestore.getDocument('users/alice');
      expect(fresh!.fields['name'], 'Alice');
      expect(fresh.fromCache, isFalse);

      client.offline = true;
      final cached = await firestore.getDocument('users/alice');

      expect(cached!.fields['name'], 'Alice');
      // The whole point: the caller can tell this is a snapshot.
      expect(cached.fromCache, isTrue);
    });

    test('an uncached read still fails offline', () async {
      final client =
          _SwitchableClient((request) async => http.Response('', 200))
            ..offline = true;
      final firestore = Firestore(
        projectId: 'demo',
        idTokenProvider: () async => 'tok',
        httpClient: client,
        cache: InMemoryFirestoreCache(),
      );

      // Nothing was ever cached for this path, so there is no better answer
      // than the failure. Returning null here would read as "no such document".
      await expectLater(
        firestore.getDocument('users/bob'),
        throwsA(isA<SocketException>()),
      );
    });

    test('a 403 is not papered over with stale data', () async {
      var deny = false;
      final client = _SwitchableClient((request) async {
        if (deny) {
          return http.Response(
            jsonEncode({
              'error': {'message': 'denied', 'status': 'PERMISSION_DENIED'},
            }),
            403,
          );
        }
        return http.Response(
          jsonEncode(_docJson('users/alice', {'name': 'Alice'})),
          200,
        );
      });
      final firestore = Firestore(
        projectId: 'demo',
        idTokenProvider: () async => 'tok',
        httpClient: client,
        cache: InMemoryFirestoreCache(),
      );
      await firestore.getDocument('users/alice');

      deny = true;

      // The server answered. Rules changed, or the token expired; serving the
      // cached copy would hand back a document the user is no longer allowed
      // to see.
      await expectLater(
        firestore.getDocument('users/alice'),
        throwsA(isA<FirestoreApiException>()),
      );
    });

    test('a 503 does fall back, because the server could not answer', () async {
      var down = false;
      final client = _SwitchableClient((request) async {
        if (down) return http.Response('{}', 503);
        return http.Response(
          jsonEncode(_docJson('users/alice', {'name': 'Alice'})),
          200,
        );
      });
      final firestore = Firestore(
        projectId: 'demo',
        idTokenProvider: () async => 'tok',
        httpClient: client,
        cache: InMemoryFirestoreCache(),
      );
      await firestore.getDocument('users/alice');

      down = true;
      final cached = await firestore.getDocument('users/alice');

      expect(cached!.fromCache, isTrue);
    });

    test('a deleted document drops its cached copy', () async {
      var deleted = false;
      final client = _SwitchableClient((request) async {
        if (deleted) return http.Response('{}', 404);
        return http.Response(
          jsonEncode(_docJson('users/alice', {'name': 'Alice'})),
          200,
        );
      });
      final cache = InMemoryFirestoreCache();
      final firestore = Firestore(
        projectId: 'demo',
        idTokenProvider: () async => 'tok',
        httpClient: client,
        cache: cache,
      );
      await firestore.getDocument('users/alice');
      expect(cache.length, 1);

      deleted = true;
      expect(await firestore.getDocument('users/alice'), isNull);
      // Keeping it would resurrect the document the next time the network fails.
      expect(cache.length, 0);

      client.offline = true;
      await expectLater(
        firestore.getDocument('users/alice'),
        throwsA(isA<SocketException>()),
      );
    });

    test('a list is cached whole and every row is marked stale', () async {
      final client = _SwitchableClient(
        (request) async => http.Response(
          jsonEncode({
            'documents': [
              _docJson('teams/254', {'nickname': 'Cheesy Poofs'}),
              _docJson('teams/3847', {'nickname': 'Example Team'}),
            ],
          }),
          200,
        ),
      );
      final firestore = Firestore(
        projectId: 'demo',
        idTokenProvider: () async => 'tok',
        httpClient: client,
        cache: InMemoryFirestoreCache(),
      );
      expect((await firestore.listDocuments('teams')).length, 2);

      client.offline = true;
      final cached = await firestore.listDocuments('teams');

      expect(cached.map((d) => d.id), ['254', '3847']);
      expect(cached.every((d) => d.fromCache), isTrue);
    });

    test('a partial paginated list is never cached', () async {
      var failSecondPage = false;
      final client = _SwitchableClient((request) async {
        final token = request.url.queryParameters['pageToken'];
        if (token == null) {
          return http.Response(
            jsonEncode({
              'documents': [
                _docJson('teams/254', {'n': 1})
              ],
              'nextPageToken': 'page2',
            }),
            200,
          );
        }
        if (failSecondPage) return http.Response('{}', 500);
        return http.Response(
          jsonEncode({
            'documents': [
              _docJson('teams/3847', {'n': 2})
            ],
          }),
          200,
        );
      });
      final cache = InMemoryFirestoreCache();
      final firestore = Firestore(
        projectId: 'demo',
        idTokenProvider: () async => 'tok',
        httpClient: client,
        cache: cache,
      );

      failSecondPage = true;
      // Nothing cached and the fetch was incomplete, so it fails rather than
      // caching a list that silently lost its tail.
      await expectLater(
        firestore.listDocuments('teams'),
        throwsA(isA<FirestoreApiException>()),
      );
      expect(cache.length, 0);

      failSecondPage = false;
      expect((await firestore.listDocuments('teams')).length, 2);
      expect(cache.length, 1);
    });

    test('two queries over one collection cache separately', () async {
      final client = _SwitchableClient((request) async {
        final body = jsonDecode(
          (request as http.Request).body,
        ) as Map<String, dynamic>;
        final where = jsonEncode(body['structuredQuery']['where']);
        final id = where.contains('254') ? 'teams/254' : 'teams/3847';
        return http.Response(
          jsonEncode([
            {
              'document': _docJson(id, {'n': 1})
            },
          ]),
          200,
        );
      });
      final firestore = Firestore(
        projectId: 'demo',
        idTokenProvider: () async => 'tok',
        httpClient: client,
        cache: InMemoryFirestoreCache(),
      );
      await firestore.runQuery(
        'teams',
        filters: const [FieldFilter('number', 'EQUAL', 254)],
      );
      await firestore.runQuery(
        'teams',
        filters: const [FieldFilter('number', 'EQUAL', 3847)],
      );

      client.offline = true;
      final first = await firestore.runQuery(
        'teams',
        filters: const [FieldFilter('number', 'EQUAL', 254)],
      );
      final second = await firestore.runQuery(
        'teams',
        filters: const [FieldFilter('number', 'EQUAL', 3847)],
      );

      // A key on the collection alone would have let the second query's answer
      // overwrite the first's.
      expect(first.single.id, '254');
      expect(second.single.id, '3847');
      expect(first.single.fromCache, isTrue);
    });

    test('no cache configured means no behaviour change', () async {
      final client = _SwitchableClient(
        (request) async => http.Response(
          jsonEncode(_docJson('users/alice', {'name': 'Alice'})),
          200,
        ),
      );
      final firestore = Firestore(
        projectId: 'demo',
        idTokenProvider: () async => 'tok',
        httpClient: client,
      );
      expect(firestore.isCaching, isFalse);
      final fresh = await firestore.getDocument('users/alice');
      expect(fresh!.fromCache, isFalse);

      client.offline = true;
      await expectLater(
        firestore.getDocument('users/alice'),
        throwsA(isA<SocketException>()),
      );
    });

    test('clearCache drops what a signed-out user could read', () async {
      final client = _SwitchableClient(
        (request) async => http.Response(
          jsonEncode(_docJson('users/alice', {'name': 'Alice'})),
          200,
        ),
      );
      final cache = InMemoryFirestoreCache();
      final firestore = Firestore(
        projectId: 'demo',
        idTokenProvider: () async => 'tok',
        httpClient: client,
        cache: cache,
      );
      await firestore.getDocument('users/alice');
      expect(cache.length, 1);

      await firestore.clearCache();

      expect(cache.length, 0);
    });
  });

  group('FileFirestoreCache', () {
    late Directory dir;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('firestore_cache_test');
    });

    tearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    test('a read survives a new client over the same directory', () async {
      final client = _SwitchableClient(
        (request) async => http.Response(
          jsonEncode(_docJson('users/alice', {'name': 'Alice'})),
          200,
        ),
      );
      final first = Firestore(
        projectId: 'demo',
        idTokenProvider: () async => 'tok',
        httpClient: client,
        cache: FileFirestoreCache(dir),
      );
      await first.getDocument('users/alice');

      // A relaunch: a brand new client, the same directory on disk, and no
      // network. This is the case the whole feature exists for.
      final offlineClient = _SwitchableClient(
        (request) async => http.Response('', 200),
      )..offline = true;
      final second = Firestore(
        projectId: 'demo',
        idTokenProvider: () async => 'tok',
        httpClient: offlineClient,
        cache: FileFirestoreCache(dir),
      );

      final cached = await second.getDocument('users/alice');

      expect(cached!.fields['name'], 'Alice');
      expect(cached.fromCache, isTrue);
    });

    test('a path with slashes does not become a directory tree', () async {
      final cache = FileFirestoreCache(dir);
      await cache.write('a/b/c', 'payload');

      expect(await cache.read('a/b/c'), 'payload');
      expect(
        dir.listSync().whereType<Directory>(),
        isEmpty,
        reason: 'the key was written as a nested path instead of one file',
      );
    });

    test('clear removes everything', () async {
      final cache = FileFirestoreCache(dir);
      await cache.write('one', '1');
      await cache.write('two', '2');

      await cache.clear();

      expect(await cache.read('one'), isNull);
      expect(await cache.read('two'), isNull);
    });

    test('a key longer than a filename survives a round trip', () async {
      final cache = FileFirestoreCache(dir);
      // The shape of a runQuery key: the whole encoded query body. Encoding that
      // into the filename produced a name past the 255-byte limit, so the write
      // failed and the cache silently never worked for queries.
      final key = 'firestore_client/v1/demo/(default)/query/'
          '${'{"structuredQuery":{"from":[{"collectionId":"teams"}]}}' * 12}';
      expect(key.length, greaterThan(400));

      await cache.write(key, 'payload');

      expect(await cache.read(key), 'payload');
    });

    test('two concurrent writes for one key do not interleave', () async {
      final cache = FileFirestoreCache(dir);
      // A shared temp path let both writers put bytes in one file, and the
      // rename then published something that decoded to neither value.
      final first = 'a' * 4000;
      final second = 'b' * 4000;

      await Future.wait<void>([
        cache.write('same-key', first),
        cache.write('same-key', second),
      ]);

      // Whichever landed last wins; what must never happen is a blend of the
      // two.
      expect(await cache.read('same-key'), anyOf(first, second));
    });

    test('clear removes a temp file left by a crashed write', () async {
      // A temp file is <digest>.fcache.<n>.tmp, so it does not end with the
      // entry extension. A process that dies between the write and the rename
      // used to leave it behind with nothing to ever collect it.
      final cache = FileFirestoreCache(dir);
      await cache.write('mine', 'payload');
      final orphan = File('${dir.path}/deadbeef.fcache.7.tmp')
        ..writeAsStringSync('half a payload');
      // A temp file belonging to the host, which must survive: matching a bare
      // '.tmp' would be the same mistake as deleting the whole directory.
      final foreignTemp = File('${dir.path}/host-upload.tmp')
        ..writeAsStringSync('not ours');

      await cache.clear();

      expect(orphan.existsSync(), isFalse);
      expect(foreignTemp.existsSync(), isTrue);
    });

    test('clear leaves files the cache did not write', () async {
      // clearCache() runs on sign-out, and a host may point the cache at a
      // directory that already holds its own state, including the persisted
      // session.
      final cache = FileFirestoreCache(dir);
      await cache.write('mine', 'payload');
      final foreign = File('${dir.path}/session.json')
        ..writeAsStringSync('{"refreshToken":"keep me"}');

      await cache.clear();

      expect(await cache.read('mine'), isNull);
      expect(foreign.existsSync(), isTrue);
      expect(foreign.readAsStringSync(), '{"refreshToken":"keep me"}');
      // The directory itself survives, so a held handle stays valid.
      expect(dir.existsSync(), isTrue);
    });
  });

  group('cache write failures', () {
    test('a cache that throws on write does not poison a good read', () async {
      // FirestoreCache is public, so a host implementation can throw. With the
      // write inside the request's try block, that threw into the catch, which
      // then served an older cached payload instead of the one the server had
      // just returned.
      final cache = _ThrowingWriteCache()
        ..entries['firestore_client/v1/demo/(default)/doc/users/alice'] =
            jsonEncode(_docJson('users/alice', {'name': 'Stale'}));
      final client = _SwitchableClient(
        (request) async => http.Response(
          jsonEncode(_docJson('users/alice', {'name': 'Fresh'})),
          200,
        ),
      );
      final firestore = Firestore(
        projectId: 'demo',
        idTokenProvider: () async => 'tok',
        httpClient: client,
        cache: cache,
      );

      final read = await firestore.getDocument('users/alice');

      expect(read!.fields['name'], 'Fresh');
      expect(read.fromCache, isFalse);
    });

    test('a 404 never stores the empty stand-in', () async {
      // The closure returns '' for a 404. Writing that, even for the moment
      // before it is removed, let a concurrent read fall back to '' and throw
      // FormatException out of jsonDecode.
      final cache = _RecordingCache();
      final client = _SwitchableClient(
        (request) async => http.Response('{}', 404),
      );
      final firestore = Firestore(
        projectId: 'demo',
        idTokenProvider: () async => 'tok',
        httpClient: client,
        cache: cache,
      );

      expect(await firestore.getDocument('users/ghost'), isNull);

      expect(cache.writes, isEmpty);
    });
  });
}

/// Throws from [write] but reads normally, standing in for a host cache whose
/// storage is full or read-only.
class _ThrowingWriteCache implements FirestoreCache {
  final Map<String, String> entries = <String, String>{};

  @override
  Future<String?> read(String key) async => entries[key];

  @override
  Future<void> write(String key, String value) async =>
      throw StateError('disk full');

  @override
  Future<void> remove(String key) async => entries.remove(key);

  @override
  Future<void> clear() async => entries.clear();
}

/// Records every write so a test can assert one never happened.
class _RecordingCache implements FirestoreCache {
  final Map<String, String> entries = <String, String>{};
  final List<String> writes = <String>[];

  @override
  Future<String?> read(String key) async => entries[key];

  @override
  Future<void> write(String key, String value) async {
    writes.add(key);
    entries[key] = value;
  }

  @override
  Future<void> remove(String key) async => entries.remove(key);

  @override
  Future<void> clear() async => entries.clear();
}
