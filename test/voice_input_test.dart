import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tv_remote/voice_input.dart';

Uint8List _pcm(List<int> samples) {
  final data = ByteData(samples.length * 2);
  for (var i = 0; i < samples.length; i++) {
    data.setInt16(i * 2, samples[i], Endian.little);
  }
  return data.buffer.asUint8List();
}

List<int> _samples(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  return [for (var i = 0; i + 1 < bytes.length; i += 2) data.getInt16(i, Endian.little)];
}

void main() {
  test('halves the sample rate by averaging pairs of samples', () {
    final converter = HalfRateConverter();
    expect(_samples(converter.convert(_pcm([100, 200, -32768, -32768, 32767, 32765]))), [
      150,
      -32768,
      32766,
    ]);
  });

  test('carries samples and bytes split across chunks', () {
    final converter = HalfRateConverter();
    final all = _pcm([10, 20, 30, 40, 50, 60, -70, -80]);
    final output = <int>[];
    // Split mid-sample and mid-pair.
    for (final (start, end) in [(0, 3), (3, 7), (7, 9), (9, 16)]) {
      output.addAll(_samples(converter.convert(Uint8List.sublistView(all, start, end))));
    }
    expect(output, [15, 35, 55, -75]);
  });
}
