import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tv_remote/remote_controller.dart';
import 'package:tv_remote/tv/certificate.dart';
import 'package:tv_remote/tv/discovery.dart';
import 'package:tv_remote/tv/key_codes.dart';
import 'package:tv_remote/tv/pairing.dart';
import 'package:tv_remote/tv/remote_connection.dart';
import 'package:tv_remote/tv/tv_app.dart';
import 'package:tv_remote/voice_input.dart';

import 'support/fake_tv.dart';

const _host = '127.0.0.1';

class _MemoryStore implements SettingsStore {
  final values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String? value) async =>
      value == null ? values.remove(key) : values[key] = value;
}

/// A microphone that plays back what the test adds.
class _FakeMicrophone implements VoiceInput {
  bool allow = true;
  StreamController<Uint8List>? audio;
  int stops = 0;

  bool get recording => audio != null;

  void say(int bytes, [int value = 1]) => audio!.add(Uint8List(bytes)..fillRange(0, bytes, value));

  @override
  Future<bool> requestPermission() async => allow;

  @override
  Future<Stream<Uint8List>> start() async => (audio = StreamController()).stream;

  @override
  Future<void> stop() async {
    stops++;
    await audio?.close();
    audio = null;
  }
}

/// Flips the check byte so the code is guaranteed to be wrong.
String _mistype(String code) {
  final check = (int.parse(code.substring(0, 2), radix: 16) + 1) % 256;
  return check.toRadixString(16).padLeft(2, '0') + code.substring(2);
}

Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('Timed out waiting for condition');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  late ClientIdentity client;
  late ClientIdentity tvIdentity;
  late ClientIdentity stranger;
  late FakeTv tv;

  setUpAll(() async {
    (client, tvIdentity, stranger) = await (
      Isolate.run(ClientIdentity.generate),
      Isolate.run(() => ClientIdentity.generate(commonName: 'tv')),
      Isolate.run(ClientIdentity.generate),
    ).wait;
  });

  setUp(() async {
    tv = await FakeTv.start(tvIdentity: tvIdentity, client: client);
  });

  tearDown(() => tv.close());

  Future<void> pair() async {
    final session = await PairingSession.start(
      host: _host,
      identity: client,
      clientName: 'Test Remote',
      port: tv.pairingPort,
    );
    await session.finish(await tv.displayedCode);
  }

  test('reports that pairing is needed before the TV knows the client', () async {
    await expectLater(
      RemoteConnection.connect(host: _host, identity: client, port: tv.remotePort),
      throwsA(
        isA<RemoteConnectionException>().having(
          (e) => e.failure,
          'failure',
          RemoteFailure.needsPairing,
        ),
      ),
    );
  });

  test('reports that pairing is needed when the TV rejects the certificate', () async {
    tv.paired = true;
    await expectLater(
      RemoteConnection.connect(host: _host, identity: stranger, port: tv.remotePort),
      throwsA(
        isA<RemoteConnectionException>().having(
          (e) => e.failure,
          'failure',
          RemoteFailure.needsPairing,
        ),
      ),
    );
  });

  test('reports an unreachable TV', () async {
    final port = tv.remotePort;
    await tv.close();
    await expectLater(
      RemoteConnection.connect(host: _host, identity: client, port: port),
      throwsA(
        isA<RemoteConnectionException>().having(
          (e) => e.failure,
          'failure',
          RemoteFailure.unavailable,
        ),
      ),
    );
    tv = await FakeTv.start(tvIdentity: tvIdentity, client: client); // for tearDown
  });

  test('pairs using the code shown on the TV', () async {
    await pair();
    expect(tv.paired, isTrue);
    expect(tv.pairingClientName, 'Test Remote');
  });

  test('a mistyped code can be corrected in the same session', () async {
    final session = await PairingSession.start(
      host: _host,
      identity: client,
      clientName: 'Test Remote',
      port: tv.pairingPort,
    );
    final code = await tv.displayedCode;
    await expectLater(session.finish(_mistype(code)), throwsA(isA<WrongPairingCodeException>()));
    expect(tv.paired, isFalse);
    await session.finish(code.toLowerCase());
    expect(tv.paired, isTrue);
  });

  test('a code the TV rejects ends the session', () async {
    tv.rejectSecrets = true;
    final session = await PairingSession.start(
      host: _host,
      identity: client,
      clientName: 'Test Remote',
      port: tv.pairingPort,
    );
    await expectLater(
      session.finish(await tv.displayedCode),
      throwsA(
        isA<PairingException>().having((e) => e, 'type', isNot(isA<WrongPairingCodeException>())),
      ),
    );
    expect(tv.paired, isFalse);
  });

  test('after pairing, connects, reports TV state, sends keys and answers pings', () async {
    await pair();
    final connection = await RemoteConnection.connect(
      host: _host,
      identity: client,
      port: tv.remotePort,
    );
    addTearDown(connection.close);

    // PING | KEY | IME | VOICE | POWER | VOLUME | APP_LINK, limited to what the TV offered (622).
    expect(tv.activeFeatures, 622 & (1 | 2 | 4 | 8 | 32 | 64 | 512));
    expect(connection.status.value.isOn, isTrue);
    await _until(() => connection.status.value.volumeLevel != null);
    expect(connection.status.value.volumeLevel, 15);
    expect(connection.status.value.volumeMax, 100);
    expect(connection.status.value.muted, isFalse);

    final keys = tv.keys.take(3).toList();
    connection
      ..sendKey(RemoteKey.dpadUp)
      ..sendKey(RemoteKey.volumeMute)
      ..sendKey(RemoteKey.power);
    expect(await keys, [(19, 3), (164, 3), (26, 3)]);

    final pong = tv.pingResponses.first;
    tv.ping(42);
    expect(await pong, 42);
  });

  test('closes when the TV goes silent, but not while keys are being sent', () async {
    await pair();
    const idle = Duration(milliseconds: 400);
    final connection = await RemoteConnection.connect(
      host: _host,
      identity: client,
      port: tv.remotePort,
      idleTimeout: idle,
    );
    addTearDown(connection.close);

    // The fake TV never pings. Holding a key for twice the timeout keeps it open.
    for (var i = 0; i < 8; i++) {
      connection.sendKey(RemoteKey.dpadDown);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(connection.isClosed, isFalse);

    await connection.done.timeout(idle * 3);
    expect(connection.isClosed, isTrue);
  });

  test('opens streaming apps by their Android TV package', () async {
    await pair();
    final connection = await RemoteConnection.connect(
      host: _host,
      identity: client,
      port: tv.remotePort,
    );
    addTearDown(connection.close);

    expect(connection.supportsAppLinks, isTrue);
    final links = tv.appLinks.take(3).toList();
    for (final app in TvApp.values) {
      expect(connection.openLink(app.link), isTrue);
    }
    expect(await links, [
      'https://www.netflix.com/title',
      'https://www.youtube.com',
      'https://app.primevideo.com',
    ]);
  });

  test('does not send app launches to a TV without app-link support', () async {
    await pair();
    tv.supportedFeatures = 1 | 2 | 32 | 64; // no APP_LINK
    final connection = await RemoteConnection.connect(
      host: _host,
      identity: client,
      port: tv.remotePort,
    );
    addTearDown(connection.close);

    expect(connection.supportsAppLinks, isFalse);
    final links = <String>[];
    tv.appLinks.listen(links.add);
    expect(connection.openLink(TvApp.netflix.link), isFalse);

    // Keys still work, and the app link never reached the TV.
    final key = tv.keys.first;
    connection.sendKey(RemoteKey.home);
    expect(await key, (3, 3));
    expect(links, isEmpty);
    expect(connection.isClosed, isFalse);
  });

  test('reports when the TV is in standby', () async {
    await pair();
    tv.isOn = false;
    final connection = await RemoteConnection.connect(
      host: _host,
      identity: client,
      port: tv.remotePort,
    );
    addTearDown(connection.close);
    expect(connection.status.value.isOn, isFalse);
  });

  test('reports the app focused on the TV', () async {
    await pair();
    final connection = await RemoteConnection.connect(
      host: _host,
      identity: client,
      port: tv.remotePort,
    );
    addTearDown(connection.close);

    tv.reportApp('com.netflix.ninja');
    await _until(() => connection.focusedApp.value == 'com.netflix.ninja');
  });

  test('streams speech to voice search in 20 KiB messages', () async {
    await pair();
    final connection = await RemoteConnection.connect(
      host: _host,
      identity: client,
      port: tv.remotePort,
    );
    addTearDown(connection.close);

    expect(connection.supportsVoice, isTrue);
    final search = tv.keys.first;
    final session = await connection.startVoice();
    expect(await search, (84, 3));
    expect(session, isNotNull);
    await _until(() => tv.voiceBegins.isNotEmpty);
    expect(tv.voiceBegins, [session!.id]);

    session.add(Uint8List(12000)..fillRange(0, 12000, 1));
    session.add(Uint8List(12000)..fillRange(0, 12000, 2));
    await _until(() => tv.voicePayloads.isNotEmpty);
    // A full message goes as soon as there is one; the rest waits.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(tv.voicePayloads, hasLength(1));
    expect(tv.voicePayloads[0].$2, hasLength(20480));
    expect(tv.voicePayloads[0].$2.sublist(11990, 12010), [
      ...List.filled(10, 1),
      ...List.filled(10, 2),
    ]);

    session.end();
    await _until(() => tv.voiceEnds.isNotEmpty);
    expect(tv.voiceEnds, [session.id]);
    // The remainder goes padded with silence to a full message.
    expect(tv.voicePayloads, hasLength(2));
    final last = tv.voicePayloads[1].$2;
    expect(last, hasLength(20480));
    expect(last.sublist(0, 3520).every((b) => b == 2), isTrue);
    expect(last.sublist(3520).every((b) => b == 0), isTrue);
    await session.done;
  });

  test('a voice session is over when the TV leaves its voice search', () async {
    await pair();
    final connection = await RemoteConnection.connect(
      host: _host,
      identity: client,
      port: tv.remotePort,
    );
    addTearDown(connection.close);

    final session = (await connection.startVoice())!;
    await _until(() => connection.focusedApp.value == FakeTv.voiceApp);
    var done = false;
    session.done.then((_) => done = true);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(done, isFalse);

    // Having heard a search, the TV opens the results.
    tv.reportApp('com.google.android.youtube.tv');
    await session.done.timeout(const Duration(seconds: 5));
    expect(session.isEnded, isTrue);
  });

  test('does not start voice search on a TV without voice support', () async {
    await pair();
    tv.supportedFeatures = 622 & ~8;
    final connection = await RemoteConnection.connect(
      host: _host,
      identity: client,
      port: tv.remotePort,
    );
    addTearDown(connection.close);

    final keys = <(int, int)>[];
    tv.keys.listen(keys.add);
    expect(connection.supportsVoice, isFalse);
    expect(await connection.startVoice(), isNull);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(keys, isEmpty);
  });

  group('RemoteController', () {
    late RemoteController controller;
    late _MemoryStore store;
    late _FakeMicrophone microphone;

    setUp(() {
      store = _MemoryStore();
      microphone = _FakeMicrophone();
      controller = RemoteController(
        store: store,
        createIdentity: () async => client,
        remotePort: tv.remotePort,
        pairingPort: tv.pairingPort,
        voiceInput: microphone,
        appSettleDelay: const Duration(milliseconds: 150),
      );
    });

    tearDown(() => controller.dispose());

    test('pairs a newly chosen TV, then controls it', () async {
      await controller.load();
      expect(controller.status, ConnectionStatus.noDevice);

      await controller.selectDevice(const TvDevice(name: 'Fake TV', host: _host));
      await _until(() => controller.status == ConnectionStatus.needsPairing);

      await controller.startPairing();
      await controller.finishPairing(await tv.displayedCode);
      await _until(() => controller.status == ConnectionStatus.connected);
      expect(controller.tv.isOn, isTrue);

      final key = tv.keys.first;
      expect(controller.press(RemoteKey.home), isTrue);
      expect(await key, (3, 3));

      // The identity and TV are remembered for next launch.
      expect(store.values['client_certificate'], client.certificatePem);
      expect(store.values['device_host'], _host);
    });

    test('types into the text box focused on the TV', () async {
      tv.paired = true;
      await controller.selectDevice(const TvDevice(name: 'Fake TV', host: _host));
      await _until(() => controller.isConnected);
      expect(controller.canType, isFalse);

      tv.focusTextField('net');
      await _until(() => controller.canType);
      expect(controller.typedText, 'net');
      controller.type('netflix');
      await _until(() => tv.text == 'netflix');

      tv.leaveTextField();
      await _until(() => !controller.canType);

      // A new connection starts without a text box.
      tv.focusTextField();
      await _until(() => controller.canType);
      tv.dropConnections();
      await _until(() => !controller.isConnected);
      expect(controller.canType, isFalse);
    });

    test('reconnects to a saved TV on launch and after the connection drops', () async {
      tv.paired = true;
      store.values
        ..['device_name'] = 'Fake TV'
        ..['device_host'] = _host
        ..['client_certificate'] = client.certificatePem
        ..['client_private_key'] = client.privateKeyPem;

      await controller.load();
      await _until(() => controller.status == ConnectionStatus.connected);

      tv.dropConnections();
      await _until(() => controller.status == ConnectionStatus.disconnected);
      await _until(() => controller.status == ConnectionStatus.connected);

      final key = tv.keys.first;
      controller.press(RemoteKey.back);
      expect(await key, (4, 3));
    });

    test('disconnects in the background and reconnects in the foreground', () async {
      tv.paired = true;
      await controller.selectDevice(const TvDevice(name: 'Fake TV', host: _host));
      await _until(() => controller.status == ConnectionStatus.connected);

      controller.setForeground(false);
      expect(controller.status, ConnectionStatus.disconnected);
      expect(controller.press(RemoteKey.home), isFalse);

      controller.setForeground(true);
      await _until(() => controller.status == ConnectionStatus.connected);
    });

    test('app buttons send app links, or the TV key the user chose instead', () async {
      tv.paired = true;
      await controller.selectDevice(const TvDevice(name: 'Fake TV', host: _host));
      await _until(() => controller.status == ConnectionStatus.connected);

      final link = tv.appLinks.first;
      expect(controller.launchApp(TvApp.netflix), AppLaunchResult.sent);
      expect(await link, 'https://www.netflix.com/title');

      await controller.setAppKey(TvApp.netflix, 290);
      final key = tv.keys.first;
      expect(controller.launchApp(TvApp.netflix), AppLaunchResult.sent);
      expect(await key, (290, 3));
      expect(store.values['app_key_netflix'], '290');
    });

    test('explains when the TV refuses an app link, then reconnects', () async {
      tv.paired = true;
      tv.rejectLink = (_) => true;
      await controller.selectDevice(const TvDevice(name: 'Fake TV', host: _host));
      await _until(() => controller.status == ConnectionStatus.connected);

      expect(controller.launchApp(TvApp.netflix), AppLaunchResult.sent);
      await _until(() => controller.status == ConnectionStatus.disconnected);
      expect(controller.message, contains("couldn't open that app link"));
      await _until(() => controller.status == ConnectionStatus.connected);
    });

    test('voice search streams the microphone until the TV has heard a search', () async {
      tv.paired = true;
      await controller.selectDevice(const TvDevice(name: 'Fake TV', host: _host));
      await _until(() => controller.isConnected);

      final started = controller.startVoice();
      expect(controller.voice, VoiceState.starting);
      await _until(() => microphone.recording);
      // Speech from before the TV's session starts isn't lost.
      microphone.say(15000);
      expect(await started, VoiceStartResult.started);
      expect(controller.voice, VoiceState.listening);
      microphone.say(10000);
      await _until(() => tv.voicePayloads.length == 1);
      expect(tv.voicePayloads[0].$2.every((b) => b == 1), isTrue);

      tv.reportApp('com.google.android.youtube.tv');
      await _until(() => controller.voice == VoiceState.idle);
      expect(microphone.stops, 1);
      expect(microphone.recording, isFalse);
      // The TV ended the session itself, so the app doesn't end it again.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(tv.voiceEnds, isEmpty);
    });

    test('stopping voice search sends the rest of the speech and ends the session', () async {
      tv.paired = true;
      await controller.selectDevice(const TvDevice(name: 'Fake TV', host: _host));
      await _until(() => controller.isConnected);

      expect(await controller.startVoice(), VoiceStartResult.started);
      microphone.say(1000);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      controller.stopVoice();
      expect(controller.voice, VoiceState.idle);
      expect(microphone.stops, 1);
      await _until(() => tv.voiceEnds.isNotEmpty);
      expect(tv.voicePayloads, hasLength(1));
      expect(tv.voicePayloads[0].$2.sublist(0, 1000).every((b) => b == 1), isTrue);
    });

    test('voice search needs the microphone permission', () async {
      tv.paired = true;
      microphone.allow = false;
      await controller.selectDevice(const TvDevice(name: 'Fake TV', host: _host));
      await _until(() => controller.isConnected);

      final keys = <(int, int)>[];
      tv.keys.listen(keys.add);
      expect(await controller.startVoice(), VoiceStartResult.noPermission);
      expect(controller.voice, VoiceState.idle);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(keys, isEmpty);
    });

    test('voice search stops when the connection drops', () async {
      tv.paired = true;
      await controller.selectDevice(const TvDevice(name: 'Fake TV', host: _host));
      await _until(() => controller.isConnected);

      expect(await controller.startVoice(), VoiceStartResult.started);
      tv.dropConnections();
      await _until(() => controller.voice == VoiceState.idle);
      expect(microphone.recording, isFalse);
    });

    test('shows the open app once the TV settles on it, ignoring overlays', () async {
      tv.paired = true;
      await controller.selectDevice(const TvDevice(name: 'Fake TV', host: _host));
      await _until(() => controller.isConnected);
      expect(controller.openApp, isNull);

      tv.reportApp('com.netflix.ninja');
      await _until(() => controller.openApp != null);
      expect(controller.openApp!.name, 'Netflix');
      expect(controller.openApp!.playsMedia, isTrue);

      // Passing through another app while switching doesn't show it.
      final seen = <String?>[];
      controller.addListener(() => seen.add(controller.openApp?.name));
      tv.reportApp('com.google.android.youtube.tv');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      tv.reportApp('com.spocky.projengmenu');
      await _until(() => controller.openApp!.isHome);
      expect(seen, ['Home']);
      expect(controller.openApp!.playsMedia, isFalse);

      // The voice search screen is drawn over the app, not switched to.
      tv.reportApp(FakeTv.voiceApp);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(controller.openApp!.name, 'Home');

      tv.dropConnections();
      await _until(() => !controller.isConnected);
      expect(controller.openApp, isNull);
    });

    test('remembers the control mode', () async {
      await controller.load();
      controller.setMode(ControlMode.swipe);
      await Future<void>.delayed(Duration.zero);
      expect(store.values['control_mode'], 'swipe');

      final reloaded = RemoteController(store: store);
      addTearDown(reloaded.dispose);
      await reloaded.load();
      expect(reloaded.mode, ControlMode.swipe);
    });
  });
}
