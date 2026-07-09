import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:firestore_client/firestore_client.dart';

void main() {
  group('FirestoreValueCodec', () {
    test('round-trips every supported type', () {
      final data = <String, dynamic>{
        'null': null,
        'bool': true,
        'int': 42,
        'double': 3.5,
        'string': 'hello',
        'timestamp': DateTime.utc(2026, 7, 8, 12, 30),
        'bytes': Uint8List.fromList([1, 2, 3]),
        'geo': const GeoPoint(29.7, -95.4),
        'ref': const DocumentRef(
          'projects/p/databases/(default)/documents/users/alice',
        ),
        'list': [1, 'two', false],
        'map': {
          'nested': {'deep': 7},
        },
      };
      final decoded = FirestoreValueCodec.decodeFields(
        FirestoreValueCodec.encodeFields(data),
      );
      expect(decoded['null'], isNull);
      expect(decoded['bool'], true);
      expect(decoded['int'], 42);
      expect(decoded['double'], 3.5);
      expect(decoded['string'], 'hello');
      expect(decoded['timestamp'], DateTime.utc(2026, 7, 8, 12, 30));
      expect(decoded['bytes'], [1, 2, 3]);
      expect(decoded['geo'], const GeoPoint(29.7, -95.4));
      expect(
        (decoded['ref'] as DocumentRef).path,
        'users/alice',
      );
      expect(decoded['list'], [1, 'two', false]);
      expect((decoded['map'] as Map)['nested'], {'deep': 7});
    });

    test('integers use the string wire form', () {
      expect(FirestoreValueCodec.encode(7), {'integerValue': '7'});
      expect(FirestoreValueCodec.decode({'integerValue': '7'}), 7);
    });

    test('timestamps are normalized to UTC', () {
      final local = DateTime(2026, 7, 8, 12);
      final encoded = FirestoreValueCodec.encode(local);
      final decoded =
          FirestoreValueCodec.decode(encoded.cast<String, dynamic>());
      expect((decoded as DateTime).isUtc, isTrue);
      expect(decoded, local.toUtc());
    });

    test('rejects unsupported types', () {
      expect(
        () => FirestoreValueCodec.encode(const Duration(seconds: 1)),
        throwsArgumentError,
      );
    });

    test('rejects unknown wire values', () {
      expect(
        () => FirestoreValueCodec.decode({'weirdValue': 1}),
        throwsFormatException,
      );
    });
  });
}
