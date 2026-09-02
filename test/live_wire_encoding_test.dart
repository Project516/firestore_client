import 'dart:convert';
import 'dart:io';

import 'package:firestore_client/firestore_client.dart';
import 'package:test/test.dart';

/// The Firestore REST wire encoding, read from a live database rather than
/// written from memory. See `test/fixtures/README.md` for what was captured
/// verbatim (the encoding) and what was substituted (leaf names, because the
/// real document names a scout and this repository is public).
///
/// The hand-written cases in `value_codec_test.dart` cover each type in
/// isolation and are correct. What they cannot show is how the encodings nest
/// in a document the app actually stores, which is where a decoder that looks
/// right in isolation goes wrong.
Map<String, dynamic> _document() => (jsonDecode(
            File('test/fixtures/scout_entry_document.json').readAsStringSync())
        as Map)
    .cast<String, dynamic>();

void main() {
  group('captured Firestore wire encoding', () {
    test('Document.fromJson decodes a real document end to end', () {
      final doc = Document.fromJson(_document());

      expect(doc.id, '000ebdb1-7c61-4ff0-8568-a087f38c9e67');
      expect(doc.name, endsWith('/scoutEntries/${doc.id}'));
      expect(doc.createTime, isNotNull);
      expect(doc.updateTime, isNotNull);
      expect(doc.createTime!.isUtc, isTrue);
      expect(doc.fromCache, isFalse);
    });

    test('an integerValue arrives as a string and decodes to int', () {
      // The one most likely to be written wrong from memory: Firestore sends
      // integers as JSON strings so they survive 64-bit range.
      final raw = (_document()['fields'] as Map)['teamNumber'] as Map;
      expect(raw['integerValue'], '4414');
      expect(raw['integerValue'], isA<String>());

      final doc = Document.fromJson(_document());
      expect(doc.fields['teamNumber'], 4414);
      expect(doc.fields['teamNumber'], isA<int>());
    });

    test('an integral doubleValue arrives as a bare number', () {
      // Not a string, and not an integerValue either, even though the value
      // has no fractional part. A decoder that only handled the string forms
      // would drop it.
      final values = ((_document()['fields'] as Map)['fieldValues']
          as Map)['mapValue'] as Map;
      final raw = (values['fields'] as Map)['scoringEff'] as Map;
      expect(raw['doubleValue'], 96);
      expect(raw['doubleValue'], isA<num>());
      expect(raw['doubleValue'], isNot(isA<String>()));

      final doc = Document.fromJson(_document());
      final decoded = doc.fields['fieldValues'] as Map<String, dynamic>;
      expect(decoded['scoringEff'], 96.0);
      expect(decoded['scoringEff'], isA<double>());
    });

    test('an empty map has no fields key at all', () {
      // Firestore sends `{"mapValue": {}}`, not `{"mapValue": {"fields": {}}}`.
      // Reading `fields` without a default throws on a real payload.
      final byPhase =
          ((_document()['fields'] as Map)['byPhase'] as Map)['mapValue'] as Map;
      final auton =
          ((byPhase['fields'] as Map)['auton'] as Map)['mapValue'] as Map;
      final counters =
          ((auton['fields'] as Map)['counters'] as Map)['mapValue'] as Map;
      expect(counters.containsKey('fields'), isFalse);
      expect(counters, isEmpty);

      final doc = Document.fromJson(_document());
      final phases = doc.fields['byPhase'] as Map<String, dynamic>;
      final decodedAuton = phases['auton'] as Map<String, dynamic>;
      expect(decodedAuton['counters'], isA<Map>());
      expect(decodedAuton['counters'], isEmpty);
    });

    test('nested maps decode all the way down', () {
      final doc = Document.fromJson(_document());
      final phases = doc.fields['byPhase'] as Map<String, dynamic>;

      expect(phases.keys, containsAll(['auton', 'teleop']));
      final teleop = phases['teleop'] as Map<String, dynamic>;
      expect(teleop['score'], 12);
      expect(teleop['penalties'], 0);
      expect(teleop['notes'], '');
    });

    test('booleans and timestamps decode from a real document', () {
      final doc = Document.fromJson(_document());
      final values = doc.fields['fieldValues'] as Map<String, dynamic>;

      expect(values['tRpasser'], isTrue);
      expect(values['ryCard'], isFalse);

      final ts = doc.fields['updatedAtTs'] as DateTime;
      expect(ts.isUtc, isTrue);
      expect(ts.year, 2026);
      expect(ts.microsecond, 827);
    });

    test('a real document survives an encode/decode round trip', () {
      final original = Document.fromJson(_document());
      final reEncoded = FirestoreValueCodec.encodeFields(original.fields);
      final restored = FirestoreValueCodec.decodeFields(reEncoded);

      expect(restored['teamNumber'], original.fields['teamNumber']);
      expect(restored['updatedAtTs'], original.fields['updatedAtTs']);
      expect(restored['byPhase'], original.fields['byPhase']);
      expect(restored['fieldValues'], original.fields['fieldValues']);
    });

    test('re-encoding an empty map is accepted on the way back in', () {
      // The round trip is not byte-identical: Firestore omits `fields` for an
      // empty map and the encoder emits it. Both decode to the same value,
      // which is what has to hold.
      final original = Document.fromJson(_document());
      final reEncoded = FirestoreValueCodec.encodeFields(original.fields);
      final byPhase = (reEncoded['byPhase'] as Map)['mapValue'] as Map;
      final auton =
          ((byPhase['fields'] as Map)['auton'] as Map)['mapValue'] as Map;
      final counters =
          ((auton['fields'] as Map)['counters'] as Map)['mapValue'] as Map;

      expect(counters.containsKey('fields'), isTrue);
      expect(counters['fields'], isEmpty);
      expect(
        FirestoreValueCodec.decode({'mapValue': counters}),
        isEmpty,
      );
    });
  });
}
