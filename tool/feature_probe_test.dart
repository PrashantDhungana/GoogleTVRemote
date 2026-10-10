// Probes a real TV for protocol features the app doesn't use yet: device info,
// the app on screen, and whether it starts a voice session. Run with:
//   flutter test tool/feature_probe_test.dart
// Env: TV_HOST, and DIAG_DIR holding diag_identity.json (pairs first if it is
// missing, reading the code shown on the TV from $DIAG_DIR/code.txt).
// Side effect on the TV: the voice search screen opens briefly, then Back is sent.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tv_remote/tv/certificate.dart';
import 'package:tv_remote/tv/pairing.dart';
import 'package:tv_remote/tv/proto.dart';

final _host = Platform.environment['TV_HOST'] ?? '192.168.1.101';
final _dir = Platform.environment['DIAG_DIR']!;

void log(String s) =>
    stdout.writeln('PROBE ${DateTime.now().toIso8601String().substring(11, 23)} $s');

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

void main() {
  test('probe TV features', () async {
    final id = await _identity();
    final socket = await SecureSocket.connect(
      _host,
      6466,
      context: id.createSecurityContext(),
      onBadCertificate: (_) => true,
    );
    void send(ProtoWriter w) => socket.add(frame(w.toBytes()));
    final decoder = FrameDecoder();
    final started = Completer<void>();
    final voiceBegin = Completer<int>();
    // PING | KEY | IME | VOICE | POWER | VOLUME | APP_LINK
    const ours = 1 | 2 | 4 | 8 | 32 | 64 | 512;

    socket.listen((Uint8List data) {
      for (final raw in decoder.add(data)) {
        final m = ProtoMessage.parse(raw);
        if (m.has(1)) {
          final cfg = m.message(1);
          final supported = cfg.integer(1);
          final info = cfg.message(2);
          log(
            'configure: TV features=0b${supported.toRadixString(2)} '
            'voice=${supported & 8 != 0} model="${info.string(1)}" '
            'vendor="${info.string(2)}" app_version="${info.string(6)}" '
            'package="${info.string(5)}"',
          );
          send(
            ProtoWriter()..message(
              1,
              ProtoWriter()
                ..varint(1, ours & supported)
                ..message(
                  2,
                  ProtoWriter()
                    ..varint(3, 1)
                    ..string(4, '1')
                    ..string(5, 'atvremote')
                    ..string(6, '1.0.0'),
                ),
            ),
          );
        } else if (m.has(2)) {
          log('set_active: ${m.message(2).integer(1)}');
          send(ProtoWriter()..message(2, ProtoWriter()..varint(1, ours)));
        } else if (m.has(8)) {
          send(ProtoWriter()..message(9, ProtoWriter()..varint(1, m.message(8).integer(1))));
        } else if (m.has(40)) {
          log('start: on=${m.message(40).boolean(1)}');
          if (!started.isCompleted) started.complete();
        } else if (m.has(20)) {
          final app = m.message(20).message(1);
          log(
            'ime_key_inject: app_package="${app.string(12)}" label="${app.string(10)}" '
            'text_field=${m.message(20).has(2)}',
          );
        } else if (m.has(50)) {
          final v = m.message(50);
          log(
            'volume: ${v.integer(7)}/${v.integer(6)} muted=${v.boolean(8)} '
            'player_model="${v.string(3)}"',
          );
        } else if (m.has(30)) {
          final v = m.message(30);
          log('voice_begin: session=${v.integer(1)} package="${v.string(2)}"');
          if (!voiceBegin.isCompleted) voiceBegin.complete(v.integer(1));
        } else {
          log(
            'other message fields: ${[for (var f = 1; f < 100; f++)
              if (m.has(f)) f]}',
          );
        }
      }
    }, onDone: () => log('connection closed by TV'));

    await started.future.timeout(const Duration(seconds: 8));
    await Future<void>.delayed(const Duration(seconds: 3));

    log('sending KEYCODE_SEARCH');
    send(
      ProtoWriter()..message(
        10,
        ProtoWriter()
          ..varint(1, 84)
          ..varint(2, 3),
      ),
    );
    try {
      final session = await voiceBegin.future.timeout(const Duration(seconds: 4));
      send(ProtoWriter()..message(30, ProtoWriter()..varint(1, session)));
      // One chunk of silence (8 KiB, the smallest some TVs accept), then end.
      send(
        ProtoWriter()..message(
          31,
          ProtoWriter()
            ..varint(1, session)
            ..bytes(2, Uint8List(8 * 1024)),
        ),
      );
      send(ProtoWriter()..message(32, ProtoWriter()..varint(1, session)));
      log('VOICE SUPPORTED: session $session accepted');
    } on TimeoutException {
      log('VOICE: no voice_begin within 4 s');
    }
    await Future<void>.delayed(const Duration(seconds: 3));
    send(
      ProtoWriter()..message(
        10,
        ProtoWriter()
          ..varint(1, 4)
          ..varint(2, 3),
      ),
    ); // Back
    await Future<void>.delayed(const Duration(seconds: 2));
    socket.destroy();
  }, timeout: const Timeout(Duration(minutes: 6)));
}
