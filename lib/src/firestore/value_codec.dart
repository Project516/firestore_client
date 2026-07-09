import 'dart:convert';
import 'dart:typed_data';

/// A Firestore GeoPoint value.
class GeoPoint {
  const GeoPoint(this.latitude, this.longitude);

  final double latitude;
  final double longitude;

  @override
  bool operator ==(Object other) =>
      other is GeoPoint &&
      other.latitude == latitude &&
      other.longitude == longitude;

  @override
  int get hashCode => Object.hash(latitude, longitude);

  @override
  String toString() => 'GeoPoint($latitude, $longitude)';
}

/// A reference to another Firestore document, held as its full resource name
/// (`projects/{p}/databases/{d}/documents/{path}`).
class DocumentRef {
  const DocumentRef(this.name);

  final String name;

  /// The path below `/documents/`, e.g. `users/alice`.
  String get path {
    final i = name.indexOf('/documents/');
    return i < 0 ? name : name.substring(i + '/documents/'.length);
  }

  @override
  bool operator ==(Object other) => other is DocumentRef && other.name == name;

  @override
  int get hashCode => name.hashCode;

  @override
  String toString() => 'DocumentRef($name)';
}

/// Encodes and decodes between plain Dart values and the Firestore REST
/// `Value` JSON representation.
///
/// Supported Dart types: `null`, `bool`, `int`, `double`, `String`,
/// `DateTime` (stored as `timestampValue`, always UTC), `Uint8List`
/// (`bytesValue`), [GeoPoint], [DocumentRef], `List`, and
/// `Map<String, dynamic>`.
class FirestoreValueCodec {
  const FirestoreValueCodec._();

  /// Encodes a Dart value to a Firestore REST `Value` JSON object.
  static Map<String, dynamic> encode(Object? value) {
    if (value == null) return {'nullValue': null};
    if (value is bool) return {'booleanValue': value};
    // int before double: `is double` is false for int on the VM but the
    // integerValue wire form is a string either way.
    if (value is int) return {'integerValue': value.toString()};
    if (value is double) return {'doubleValue': value};
    if (value is String) return {'stringValue': value};
    if (value is DateTime) {
      return {'timestampValue': value.toUtc().toIso8601String()};
    }
    if (value is Uint8List) return {'bytesValue': base64Encode(value)};
    if (value is GeoPoint) {
      return {
        'geoPointValue': {
          'latitude': value.latitude,
          'longitude': value.longitude,
        },
      };
    }
    if (value is DocumentRef) return {'referenceValue': value.name};
    if (value is List) {
      return {
        'arrayValue': {
          'values': [for (final v in value) encode(v)],
        },
      };
    }
    if (value is Map) {
      return {
        'mapValue': {
          'fields': {
            for (final e in value.entries) e.key as String: encode(e.value),
          },
        },
      };
    }
    throw ArgumentError.value(
      value,
      'value',
      'Unsupported Firestore value type ${value.runtimeType}',
    );
  }

  /// Encodes a Dart map to a Firestore REST `fields` object.
  static Map<String, dynamic> encodeFields(Map<String, dynamic> data) => {
        for (final e in data.entries) e.key: encode(e.value),
      };

  /// Decodes a Firestore REST `Value` JSON object to a Dart value.
  static Object? decode(Map<String, dynamic> value) {
    if (value.containsKey('nullValue')) return null;
    if (value.containsKey('booleanValue')) return value['booleanValue'] as bool;
    if (value.containsKey('integerValue')) {
      return int.parse(value['integerValue'] as String);
    }
    if (value.containsKey('doubleValue')) {
      return (value['doubleValue'] as num).toDouble();
    }
    if (value.containsKey('stringValue')) return value['stringValue'] as String;
    if (value.containsKey('timestampValue')) {
      return DateTime.parse(value['timestampValue'] as String).toUtc();
    }
    if (value.containsKey('bytesValue')) {
      return base64Decode(value['bytesValue'] as String);
    }
    if (value.containsKey('geoPointValue')) {
      final g = value['geoPointValue'] as Map;
      return GeoPoint(
        (g['latitude'] as num? ?? 0).toDouble(),
        (g['longitude'] as num? ?? 0).toDouble(),
      );
    }
    if (value.containsKey('referenceValue')) {
      return DocumentRef(value['referenceValue'] as String);
    }
    if (value.containsKey('arrayValue')) {
      final values = (value['arrayValue'] as Map)['values'] as List? ?? [];
      return [
        for (final v in values) decode((v as Map).cast<String, dynamic>()),
      ];
    }
    if (value.containsKey('mapValue')) {
      final fields = (value['mapValue'] as Map)['fields'] as Map? ?? {};
      return {
        for (final e in fields.entries)
          e.key as String: decode((e.value as Map).cast<String, dynamic>()),
      };
    }
    throw FormatException('Unknown Firestore value: ${value.keys.join(', ')}');
  }

  /// Decodes a Firestore REST `fields` object to a Dart map.
  static Map<String, dynamic> decodeFields(Map<String, dynamic>? fields) => {
        if (fields != null)
          for (final e in fields.entries)
            e.key: decode((e.value as Map).cast<String, dynamic>()),
      };
}
