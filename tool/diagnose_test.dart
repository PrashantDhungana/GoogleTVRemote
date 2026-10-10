// Diagnostic for opening apps on a real TV. Run with:
//   flutter test tool/diagnose_test.dart
// Pairs this computer (code read from $DIAG_DIR/code.txt), then reports what the
// TV advertises and how it reacts to each kind of app launch.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tv_remote/tv/certificate.dart';
import 'package:tv_remote/tv/pairing.dart';
import 'package:tv_remote/tv/proto.dart';
import 'package:tv_remote/tv/remote_connection.dart';

final _host = Platform.environment['TV_HOST'] ?? '192.168.1.101';
final _dir = Platform.environment['DIAG_DIR']!;

void log(String s) =>
    stdout.writeln('DIAG ${DateTime.now().toIso8601String().substring(11, 19)} $s');

Future<ClientIdentity> _identity() async {
  final f = File('$_dir/diag_identity.json');
  if (f.existsSync()) {
    final j = jsonDecode(f.readAsStringSync());
    return ClientIdentity(certificatePem: j['c'], privateKeyPem: j['k']);
  }
  final id = await Isolate.run(() => ClientIdentity.generate(commonName: 'atvremote'));
  f.writeAsStringSync(jsonEncode({'c': id.certificatePem, 'k': id.privateKeyPem}));
  return id;
}

/// A bare session that logs everything and lets us choose the features we claim.
class Session {
  Session(this.socket, this.features);
  final SecureSocket socket;
  final int features;
  final decoder = FrameDecoder();
  final ready = Completer<void>();
  bool closed = false;
  int? tvFeatures;
  String? model, vendor, version;

  static Future<Session> open(ClientIdentity id, int features) async {
    final s = await SecureSocket.connect(
      _host,
      6466,
      context: id.createSecurityContext(),
      onBadCertificate: (_) => true,
    );
    final session = Session(s, features);
    s.listen(
      session._onData,
      onDone: () => session.closed = true,
      onError: (_) => session.closed = true,
    );
    await session.ready.future.timeout(const Duration(seconds: 8));
    return session;
  }

  void send(ProtoWriter w) {
    if (!closed) socket.add(frame(w.toBytes()));
  }

  void _onData(Uint8List data) {
    for (final raw in decoder.add(data)) {
      final m = ProtoMessage.parse(raw);
      if (m.has(1)) {
        final c = m.message(1);
        tvFeatures = c.integer(1);
        final info = c.message(2);
        model = info.string(1);
        vendor = info.string(2);
        version = info.string(6);
        send(
          ProtoWriter()..message(
            1,
            ProtoWriter()
              ..varint(1, features & tvFeatures!)
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
        send(
          ProtoWriter()..message(2, ProtoWriter()..varint(1, features & (tvFeatures ?? features))),
        );
      } else if (m.has(8)) {
        send(ProtoWriter()..message(9, ProtoWriter()..varint(1, m.message(8).integer(1))));
      } else if (m.has(40)) {
        if (!ready.isCompleted) ready.complete();
      } else if (m.has(3)) {
        log('  TV sent remote_error: ${m.message(3).boolean(1)} raw=${raw.length}B');
      } else if (m.has(20)) {
        log('  TV current app: ${m.message(20).message(1).string(12)}');
      }
    }
  }

  void key(int code) => send(
    ProtoWriter()..message(
      10,
      ProtoWriter()
        ..varint(1, code)
        ..varint(2, 3),
    ),
  );
  void link(String l) => send(ProtoWriter()..message(90, ProtoWriter()..string(1, l)));
  void close() => socket.destroy();
}

void main() {
  test('diagnose', () async {
    final id = await _identity();
    try {
      (await RemoteConnection.connect(host: _host, identity: id)).close();
      log('already paired');
    } on RemoteConnectionException catch (e) {
      if (e.failure != RemoteFailure.needsPairing) rethrow;
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
      log('PAIRED');
    }

    // All features: PING KEY IME VOICE POWER VOLUME APP_LINK.
    final s = await Session.open(id, 1 | 2 | 4 | 32 | 64 | 512);
    final f = s.tvFeatures!;
    log('TV: vendor="${s.vendor}" model="${s.model}" remote-service="${s.version}"');
    log('TV features=$f  APP_LINK=${f & 512 != 0} IME=${f & 4 != 0} VOICE=${f & 8 != 0}');
    await Future<void>.delayed(const Duration(seconds: 3)); // collect current-app info
    s.close();

    final custom = Platform.environment['LINKS'];
    final links = custom != null
        ? custom.split('|')
        : [
            'market://launch?id=com.netflix.ninja',
            'https://www.netflix.com/title',
            'https://www.youtube.com',
            'https://app.primevideo.com',
          ];
    for (final l in links) {
      final t = await Session.open(id, 1 | 2 | 4 | 32 | 64 | 512);
      t.key(3); // Home first, so we can see whether the app opens
      await Future<void>.delayed(const Duration(seconds: 3));
      log('SENDING $l');
      t.link(l);
      await Future<void>.delayed(const Duration(seconds: 6));
      log('  -> connection ${t.closed ? "DROPPED by TV" : "still open"}');
      t.close();
    }
  }, timeout: const Timeout(Duration(minutes: 20)));
}
