// Checks typing on a real TV with the app's own code. Run with:
//   flutter test tool/typing_check_test.dart
// Env: TV_HOST, and DIAG_DIR holding diag_identity.json (pairs first if it is
// missing, reading the code shown on the TV from $DIAG_DIR/code.txt).
// Select a text box on the TV that uses the TV's keyboard (e.g. Settings >
// Network > Add new network) within a minute of starting.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:tv_remote/tv/certificate.dart';
import 'package:tv_remote/tv/pairing.dart';
import 'package:tv_remote/tv/remote_connection.dart';
import 'package:tv_remote/tv/text_input.dart';

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

Future<void> _until(bool Function() condition, Duration timeout) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) throw TimeoutException('Timed out', timeout);
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  test('typing on a real TV', () async {
    final connection = await RemoteConnection.connect(host: _host, identity: await _identity());
    final sync = TextSync(connection);
    connection.textField.addListener(() => log('TV: ${connection.textField.value?.text}'));
    log('connected; select a text box on the TV');
    await _until(() => sync.active, const Duration(minutes: 1));
    await Future<void>.delayed(const Duration(seconds: 1));

    Future<void> expectTv(String text) async {
      await _until(() => connection.textField.value?.text == text, const Duration(seconds: 5));
      log('OK "$text"');
    }

    var typed = '';
    for (final char in 'living room'.split('')) {
      sync.setText(typed += char); // as fast as possible, like a paste
    }
    await expectTv('living room');
    sync.setText('living rm');
    await expectTv('living rm');
    sync.setText('Living rm');
    await expectTv('Living rm');
    sync.setText('Livng rm'); // delete in the middle
    await expectTv('Livng rm');
    sync.setText('Living rm'); // insert away from the cursor
    await expectTv('Living rm');
    sync.setText('');
    await expectTv('');
    log('ALL OK');
    sync.dispose();
    connection.close();
  }, timeout: const Timeout(Duration(minutes: 3)));
}
