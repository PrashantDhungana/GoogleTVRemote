// Checks voice search on a real TV with the app's own code, streaming a WAV
// recording (16-bit PCM, mono, 8 kHz) the way the microphone does. Run with:
//   flutter test tool/voice_check_test.dart
// Env: TV_HOST, DIAG_DIR holding diag_identity.json (pairs first if it is missing,
// reading the code shown on the TV from $DIAG_DIR/code.txt), and WAV, the recording's path. Windows can make one:
//   SpeechSynthesizer.SetOutputToWaveFile(path, SpeechAudioFormatInfo(8000, Sixteen, Mono))
// The TV goes to its home screen, then searches for what the recording says.
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tv_remote/tv/certificate.dart';
import 'package:tv_remote/tv/key_codes.dart';
import 'package:tv_remote/tv/pairing.dart';
import 'package:tv_remote/tv/remote_connection.dart';

final _host = Platform.environment['TV_HOST'] ?? '192.168.1.101';
final _dir = Platform.environment['DIAG_DIR']!;

void log(String s) =>
    stdout.writeln('CHECK ${DateTime.now().toIso8601String().substring(11, 23)} $s');

Future<ClientIdentity> _identity() async {
  final file = File('$_dir/diag_identity.json');
  if (file.existsSync()) {
    final j = jsonDecode(file.readAsStringSync());
    return ClientIdentity(certificatePem: j['c'], privateKeyPem: j['k']);
  }
  final id = await Isolate.run(() => ClientIdentity.generate(commonName: 'atvremote'));
  final pairing = await PairingSession.start(
    host: _host,
    identity: id,
    clientName: 'TV Remote diagnostics',
  );
  log('CODE_SHOWN_ON_TV - waiting for $_dir/code.txt');
  final codeFile = File('$_dir/code.txt');
  while (!codeFile.existsSync()) {
    await Future<void>.delayed(const Duration(seconds: 1));
  }
  await pairing.finish(codeFile.readAsStringSync().trim());
  file.writeAsStringSync(jsonEncode({'c': id.certificatePem, 'k': id.privateKeyPem}));
  return id;
}

/// The samples of a PCM WAV file, wherever its data chunk starts.
Uint8List _wavSamples(Uint8List wav) {
  final data = ByteData.sublistView(wav);
  var offset = 12;
  while (offset + 8 <= wav.length) {
    final id = ascii.decode(wav.sublist(offset, offset + 4));
    final size = data.getUint32(offset + 4, Endian.little);
    if (id == 'data') return Uint8List.sublistView(wav, offset + 8, offset + 8 + size);
    offset += 8 + size + size % 2;
  }
  throw const FormatException('No data chunk');
}

void main() {
  test('voice search on a real TV', () async {
    final id = await _identity();
    final speech = _wavSamples(File(Platform.environment['WAV']!).readAsBytesSync());

    final connection = await RemoteConnection.connect(host: _host, identity: id);
    addTearDown(connection.close);
    connection.focusedApp.addListener(() => log('focused app: ${connection.focusedApp.value}'));
    log('voice supported: ${connection.supportsVoice}');
    connection.sendKey(RemoteKey.home);
    await Future<void>.delayed(const Duration(seconds: 2));

    final session = await connection.startVoice();
    expect(session, isNotNull, reason: 'the TV started no voice session');
    log('session ${session!.id} started');
    var finished = false;
    session.done.then((_) {
      finished = true;
      log('session over');
    });

    // Half a second of silence, the speech, then silence until the TV stops
    // listening, in 100 ms pieces like the microphone delivers.
    final audio = [...Uint8List(8000), ...speech, ...Uint8List(16000 * 10)];
    for (var i = 0; i < audio.length && !finished; i += 1600) {
      final end = i + 1600 < audio.length ? i + 1600 : audio.length;
      session.add(audio.sublist(i, end));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(finished, isTrue, reason: 'the TV kept listening');
    log('TV finished on its own; now showing ${connection.focusedApp.value}');
  }, timeout: const Timeout(Duration(minutes: 6)));
}
