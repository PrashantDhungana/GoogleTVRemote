import 'dart:convert';
import 'dart:typed_data';

/// Minimal protobuf wire-format support.
///
/// The Android TV Remote v2 protocol only uses a handful of small messages, so
/// this hand-rolled encoder/decoder avoids a protoc build step. Field numbers
/// come from polo.proto (pairing) and remotemessage.proto (remote control).
class ProtoWriter {
  final BytesBuilder _out = BytesBuilder(copy: false);

  void varint(int field, int value) {
    _tag(field, 0);
    _writeVarint(_out, value);
  }

  void boolean(int field, bool value) => varint(field, value ? 1 : 0);

  void bytes(int field, List<int> value) {
    _tag(field, 2);
    _writeVarint(_out, value.length);
    _out.add(value);
  }

  void string(int field, String value) => bytes(field, utf8.encode(value));

  void message(int field, ProtoWriter value) => bytes(field, value.toBytes());

  Uint8List toBytes() => _out.toBytes();

  void _tag(int field, int wireType) => _writeVarint(_out, (field << 3) | wireType);
}

/// A decoded protobuf message: field number -> values in the order received.
///
/// Varint fields hold [int]s, length-delimited fields hold [Uint8List]s that can
/// be read as strings or nested messages.
class ProtoMessage {
  ProtoMessage._(this._fields);

  final Map<int, List<Object>> _fields;

  factory ProtoMessage.parse(Uint8List data) {
    final fields = <int, List<Object>>{};
    final reader = _Reader(data);
    try {
      while (!reader.atEnd) {
        final tag = reader.varint();
        final field = tag >> 3;
        final Object value = switch (tag & 0x7) {
          0 => reader.varint(),
          1 => reader.take(8),
          2 => reader.take(reader.varint()),
          5 => reader.take(4),
          final wireType => throw FormatException('Unsupported wire type $wireType'),
        };
        fields.putIfAbsent(field, () => []).add(value);
      }
    } on _Incomplete {
      throw const FormatException('Truncated varint');
    }
    return ProtoMessage._(fields);
  }

  bool has(int field) => _fields.containsKey(field);

  int integer(int field) => _last(field) as int? ?? 0;

  bool boolean(int field) => integer(field) != 0;

  Uint8List bytes(int field) => _last(field) as Uint8List? ?? Uint8List(0);

  String string(int field) => utf8.decode(bytes(field), allowMalformed: true);

  /// Returns the nested message, or an empty one if the field is absent.
  ProtoMessage message(int field) => ProtoMessage.parse(bytes(field));

  Object? _last(int field) => _fields[field]?.last;
}

/// Prefixes [message] with its varint-encoded length, as the TV expects.
Uint8List frame(Uint8List message) {
  final out = BytesBuilder(copy: false);
  _writeVarint(out, message.length);
  out.add(message);
  return out.toBytes();
}

/// Reassembles varint-length-prefixed messages from a byte stream that may
/// split or merge them arbitrarily.
class FrameDecoder {
  static const _maxMessageLength = 1 << 20;

  Uint8List _buffer = Uint8List(0);

  /// Adds [chunk] and returns every message it completed.
  List<Uint8List> add(List<int> chunk) {
    _buffer = Uint8List.fromList([..._buffer, ...chunk]);
    final messages = <Uint8List>[];
    var offset = 0;
    while (offset < _buffer.length) {
      final reader = _Reader(_buffer, offset);
      final int length;
      try {
        length = reader.varint();
      } on _Incomplete {
        break;
      }
      if (length > _maxMessageLength) {
        throw FormatException('Message length $length is too large');
      }
      if (reader.position + length > _buffer.length) break;
      messages.add(Uint8List.sublistView(_buffer, reader.position, reader.position + length));
      offset = reader.position + length;
    }
    _buffer = Uint8List.fromList(_buffer.sublist(offset));
    return messages;
  }
}

void _writeVarint(BytesBuilder out, int value) {
  // `>>>` treats negative values as unsigned 64-bit, matching protobuf int32/int64.
  var v = value;
  while (v & ~0x7F != 0) {
    out.addByte((v & 0x7F) | 0x80);
    v = v >>> 7;
  }
  out.addByte(v);
}

class _Incomplete implements Exception {}

class _Reader {
  _Reader(this._data, [this.position = 0]);

  final Uint8List _data;
  int position;

  bool get atEnd => position >= _data.length;

  int varint() {
    var result = 0;
    for (var shift = 0; shift < 64; shift += 7) {
      if (position >= _data.length) throw _Incomplete();
      final byte = _data[position++];
      result |= (byte & 0x7F) << shift;
      if (byte & 0x80 == 0) return result;
    }
    throw const FormatException('Varint is too long');
  }

  Uint8List take(int length) {
    if (position + length > _data.length) {
      throw const FormatException('Field extends past end of message');
    }
    final bytes = Uint8List.sublistView(_data, position, position + length);
    position += length;
    return bytes;
  }
}
