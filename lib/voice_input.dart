import 'dart:async';
import 'dart:typed_data';

import 'package:record/record.dart';

/// Speech from the phone, abstracted so tests can run without a microphone.
abstract interface class VoiceInput {
  /// Asks for microphone access if needed. False if the user refused.
  Future<bool> requestPermission();

  /// Starts recording 16-bit little-endian PCM, mono, at 8 kHz.
  Future<Stream<Uint8List>> start();

  Future<void> stop();
}

class MicrophoneInput implements VoiceInput {
  // Created on first use, so that just constructing this touches no platform code.
  late final _recorder = AudioRecorder();

  /// Phones don't all record at 8 kHz, but 16 kHz (the usual speech
  /// recognition rate) works everywhere, so record that and halve it.
  static const _recordRate = 16000;

  @override
  Future<bool> requestPermission() => _recorder.hasPermission();

  @override
  Future<Stream<Uint8List>> start() async {
    final stream = await _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: _recordRate,
        numChannels: 1,
        androidConfig: AndroidRecordConfig(audioSource: AndroidAudioSource.voiceRecognition),
      ),
    );
    final halve = HalfRateConverter();
    return stream.map(halve.convert);
  }

  @override
  Future<void> stop() async {
    await _recorder.stop();
  }
}

/// Halves the sample rate of 16-bit little-endian mono PCM by averaging each
/// pair of samples, which also filters out most of what would alias.
/// Chunks may split samples and pairs; the remainder carries over.
class HalfRateConverter {
  final _carry = <int>[];

  Uint8List convert(Uint8List chunk) {
    final bytes = _carry.isEmpty ? chunk : Uint8List.fromList([..._carry, ...chunk]);
    final pairs = bytes.length ~/ 4;
    _carry
      ..clear()
      ..addAll(bytes.sublist(pairs * 4));
    final input = ByteData.sublistView(bytes);
    final output = ByteData(pairs * 2);
    for (var i = 0; i < pairs; i++) {
      final a = input.getInt16(i * 4, Endian.little);
      final b = input.getInt16(i * 4 + 2, Endian.little);
      output.setInt16(i * 2, (a + b) ~/ 2, Endian.little);
    }
    return output.buffer.asUint8List();
  }
}
