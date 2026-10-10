import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tv_remote/tv/proto.dart';

void main() {
  group('ProtoWriter', () {
    test('encodes a key press like the official protobuf library', () {
      // RemoteMessage{remote_key_inject{key_code: KEYCODE_DPAD_UP, direction: SHORT}}
      final message = ProtoWriter()
        ..message(
          10,
          ProtoWriter()
            ..varint(1, 19)
            ..varint(2, 3),
        );
      expect(message.toBytes(), [0x52, 0x04, 0x08, 0x13, 0x10, 0x03]);
    });

    test('encodes multi-byte varints and field numbers', () {
      // KEYCODE_VOLUME_MUTE = 164 needs two bytes; field 40 needs a two-byte tag.
      expect((ProtoWriter()..varint(1, 164)).toBytes(), [0x08, 0xA4, 0x01]);
      expect((ProtoWriter()..boolean(40, true)).toBytes(), [0xC0, 0x02, 0x01]);
    });

    test('encodes negative int32 values as ten bytes', () {
      final bytes = (ProtoWriter()..varint(1, -1)).toBytes();
      expect(bytes.length, 11);
      expect(ProtoMessage.parse(bytes).integer(1), -1);
    });
  });

  group('ProtoMessage', () {
    test('round-trips nested messages, strings and booleans', () {
      final bytes =
          (ProtoWriter()
                ..varint(1, 622)
                ..message(
                  2,
                  ProtoWriter()
                    ..string(1, 'Living Room TV')
                    ..boolean(8, true),
                ))
              .toBytes();
      final message = ProtoMessage.parse(bytes);
      expect(message.integer(1), 622);
      expect(message.message(2).string(1), 'Living Room TV');
      expect(message.message(2).boolean(8), isTrue);
    });

    test('reports absent fields as defaults', () {
      final message = ProtoMessage.parse(Uint8List(0));
      expect(message.has(1), isFalse);
      expect(message.integer(1), 0);
      expect(message.boolean(1), isFalse);
      expect(message.message(1).has(1), isFalse);
    });

    test('treats an empty nested message as present', () {
      // e.g. polo ConfigurationAck, which has no fields.
      final message = ProtoMessage.parse((ProtoWriter()..bytes(31, [])).toBytes());
      expect(message.has(31), isTrue);
    });

    test('skips fixed-width fields it does not use', () {
      final bytes = Uint8List.fromList([
        0x09, 1, 2, 3, 4, 5, 6, 7, 8, // field 1, fixed64
        0x15, 1, 2, 3, 4, // field 2, fixed32
        0x18, 0x07, // field 3, varint 7
      ]);
      expect(ProtoMessage.parse(bytes).integer(3), 7);
    });

    test('rejects truncated data', () {
      expect(
        () => ProtoMessage.parse(Uint8List.fromList([0x0A, 0x05, 0x01])),
        throwsFormatException,
      );
      expect(() => ProtoMessage.parse(Uint8List.fromList([0x08, 0x80])), throwsFormatException);
    });
  });

  group('FrameDecoder', () {
    test('splits merged frames and reassembles split ones', () {
      final first = Uint8List.fromList(List.filled(200, 1)); // two-byte length prefix
      final second = Uint8List.fromList([2, 2, 2]);
      final stream = [...frame(first), ...frame(second)];

      final decoder = FrameDecoder();
      final received = <Uint8List>[];
      // Feed one byte at a time, splitting even the length prefix.
      for (final byte in stream) {
        received.addAll(decoder.add([byte]));
      }
      expect(received, [first, second]);

      expect(FrameDecoder().add(stream), [first, second]);
    });

    test('rejects absurd lengths instead of buffering forever', () {
      final decoder = FrameDecoder();
      expect(() => decoder.add([0xFF, 0xFF, 0xFF, 0x7F]), throwsFormatException);
    });
  });
}
