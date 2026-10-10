import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tv_remote/main.dart';
import 'package:tv_remote/remote_controller.dart';
import 'package:tv_remote/tv/certificate.dart';
import 'package:tv_remote/tv/discovery.dart';
import 'package:tv_remote/tv/key_codes.dart';
import 'package:tv_remote/tv/pairing.dart';
import 'package:tv_remote/tv/tv_app.dart';
import 'package:tv_remote/ui/dpad.dart';
import 'package:tv_remote/ui/media_controls.dart';
import 'package:tv_remote/ui/now_playing_pill.dart';
import 'package:tv_remote/ui/swipe_pad.dart';

class _MemoryStore implements SettingsStore {
  final values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String? value) async =>
      value == null ? values.remove(key) : values[key] = value;
}

/// A controller that is "connected" without a TV and records key presses.
class _FakeController extends RemoteController {
  _FakeController({this.fakeStatus = ConnectionStatus.connected}) : super(store: _MemoryStore());

  ConnectionStatus fakeStatus;
  final pressed = <RemoteKey>[];
  final launched = <TvApp>[];
  final pressedCodes = <int>[];
  AppLaunchResult launchResult = AppLaunchResult.sent;
  final pairingResults = Queue<Object?>();
  final codes = <String>[];
  bool fakeCanType = false;
  String fakeTypedText = '';
  final typed = <String>[];
  OpenApp? fakeOpenApp;
  VoiceState fakeVoice = VoiceState.idle;
  VoiceStartResult voiceResult = VoiceStartResult.started;
  int voiceStops = 0;

  @override
  OpenApp? get openApp => fakeOpenApp;

  @override
  VoiceState get voice => fakeVoice;

  @override
  Future<VoiceStartResult> startVoice() async {
    if (voiceResult == VoiceStartResult.started) {
      fakeVoice = VoiceState.listening;
      notifyListeners();
    }
    return voiceResult;
  }

  @override
  void stopVoice() {
    voiceStops++;
    fakeVoice = VoiceState.idle;
    notifyListeners();
  }

  /// Simulates the TV focusing (or leaving) a text box.
  void setTextBox(String? text) {
    fakeCanType = text != null;
    fakeTypedText = text ?? '';
    notifyListeners();
  }

  @override
  bool get canType => fakeCanType;

  @override
  String get typedText => fakeTypedText;

  @override
  void type(String text) {
    typed.add(text);
    fakeTypedText = text;
  }

  @override
  TvDevice? get device => const TvDevice(name: 'Living Room TV', host: '192.168.1.20');

  @override
  ConnectionStatus get status => fakeStatus;

  @override
  bool get isConnected => fakeStatus == ConnectionStatus.connected;

  @override
  bool press(RemoteKey key, [KeyDirection direction = KeyDirection.short]) {
    pressed.add(key);
    return true;
  }

  @override
  AppLaunchResult launchApp(TvApp app) {
    launched.add(app);
    return launchResult;
  }

  @override
  bool pressCode(int code) {
    pressedCodes.add(code);
    return true;
  }

  @override
  Future<void> startPairing() async {}

  @override
  Future<void> finishPairing(String code) async {
    codes.add(code);
    if (pairingResults.removeFirst() case final Exception error) throw error;
    fakeStatus = ConnectionStatus.connected;
    notifyListeners();
  }
}

const _phoneChannel = MethodChannel('tv_remote/phone');

/// Answers the app's calls to the phone's native side, as Android would.
List<MethodCall> _mockPhone(WidgetTester tester, {bool Function()? castOpens}) {
  final calls = <MethodCall>[];
  final messenger = tester.binding.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(_phoneChannel, (call) async {
    calls.add(call);
    return call.method == 'openScreenCast' ? (castOpens?.call() ?? true) : null;
  });
  addTearDown(() => messenger.setMockMethodCallHandler(_phoneChannel, null));
  return calls;
}

bool? _lastCapture(List<MethodCall> calls) =>
    calls.lastWhere((call) => call.method == 'captureVolumeButtons').arguments as bool?;

Future<void> _pressPhoneVolume(WidgetTester tester, String button) =>
    tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      _phoneChannel.name,
      _phoneChannel.codec.encodeMethodCall(MethodCall('volumeButton', button)),
      (_) {},
    );

void main() {
  testWidgets('first launch asks the user to choose a TV', (tester) async {
    // Key generation never finishes, so no real network connection is attempted.
    final controller = RemoteController(
      store: _MemoryStore(),
      createIdentity: () => Completer<ClientIdentity>().future,
    );
    await controller.load();
    await tester.pumpWidget(TvRemoteApp(controller: controller));
    // The sheet's "Looking for TVs" spinner animates while scanning, so don't settle.
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('Choose a TV'), findsOneWidget);
    expect(find.text('Or enter its IP address'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '192.168.1.20');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    // Not pumpAndSettle: the "connecting" spinner animates indefinitely.
    await tester.pump(const Duration(seconds: 1));

    expect(controller.device, const TvDevice(name: '192.168.1.20', host: '192.168.1.20'));
    expect(controller.status, ConnectionStatus.preparing);
    expect(find.text('Choose a TV'), findsNothing);
    expect(find.text('Setting up a secure connection…'), findsOneWidget);
    controller.dispose();
  });

  testWidgets('D-pad zones and buttons send the right keys', (tester) async {
    final controller = _FakeController();
    await tester.pumpWidget(TvRemoteApp(controller: controller));
    await tester.pumpAndSettle();

    final pad = tester.getRect(find.byType(DPad));
    final reach = pad.width * 0.35;
    await tester.tapAt(pad.center + Offset(0, -reach));
    await tester.tapAt(pad.center + Offset(0, reach));
    await tester.tapAt(pad.center + Offset(-reach, 0));
    await tester.tapAt(pad.center + Offset(reach, 0));
    await tester.tapAt(pad.center);
    expect(controller.pressed, [
      RemoteKey.dpadUp,
      RemoteKey.dpadDown,
      RemoteKey.dpadLeft,
      RemoteKey.dpadRight,
      RemoteKey.dpadCenter,
    ]);

    controller.pressed.clear();
    for (final label in ['Power', 'Back', 'Home', 'Mute', 'Volume down', 'Volume up']) {
      await tester.tap(find.bySemanticsLabel(label));
    }
    expect(controller.pressed, [
      RemoteKey.power,
      RemoteKey.back,
      RemoteKey.home,
      RemoteKey.volumeMute,
      RemoteKey.volumeDown,
      RemoteKey.volumeUp,
    ]);
  });

  testWidgets('app buttons open Netflix, YouTube and Prime Video', (tester) async {
    final controller = _FakeController();
    await tester.pumpWidget(TvRemoteApp(controller: controller));
    await tester.pumpAndSettle();

    for (final label in ['Open Netflix', 'Open YouTube', 'Open Prime Video']) {
      await tester.tap(find.bySemanticsLabel(label));
    }
    expect(controller.launched, [TvApp.netflix, TvApp.youtube, TvApp.primeVideo]);
    expect(controller.pressed, isEmpty);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('an app button that is not set up opens the key finder', (tester) async {
    final controller = _FakeController()..launchResult = AppLaunchResult.needsSetup;
    await tester.pumpWidget(TvRemoteApp(controller: controller));
    await tester.pumpAndSettle();

    await tester.tap(find.bySemanticsLabel('Open Netflix'));
    await tester.pumpAndSettle();
    expect(find.text('Set up the Netflix button'), findsOneWidget);

    // "Use" only becomes available for the key that was just tried.
    final firstKey = find.ancestor(of: find.text('Video app 1'), matching: find.byType(ListTile));
    await tester.tap(find.descendant(of: firstKey, matching: find.text('Try')));
    await tester.pump();
    expect(controller.pressedCodes, [289]);
    await tester.tap(find.descendant(of: firstKey, matching: find.text('Use')));
    await tester.pumpAndSettle();

    expect(controller.appKeys[TvApp.netflix], 289);
    expect(find.text('Netflix button is set up.'), findsOneWidget);
  });

  testWidgets('fits on a small phone in both modes, with a status banner', (tester) async {
    tester.view
      ..physicalSize = const Size(360 * 3, 640 * 3)
      ..devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final controller = _FakeController(fakeStatus: ConnectionStatus.disconnected);
    await tester.pumpWidget(TvRemoteApp(controller: controller));
    await tester.pumpAndSettle();

    // Layout overflows would have been reported as exceptions.
    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byType(DPad)).width, greaterThan(100));

    controller.setMode(ControlMode.swipe);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byType(SwipePad)).height, greaterThan(100));
  });

  testWidgets('the now-playing pill shows the open app, and plays/pauses media apps on tap', (
    tester,
  ) async {
    final controller = _FakeController()..fakeOpenApp = const OpenApp('com.netflix.ninja');
    await tester.pumpWidget(TvRemoteApp(controller: controller));
    // Not pumpAndSettle: the wave animates while a media app is open.
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('Netflix'), findsOneWidget);
    expect(find.byType(SiriWave), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Now playing: Netflix'));
    expect(controller.pressed, [RemoteKey.mediaPlayPause]);

    controller
      ..fakeOpenApp = const OpenApp('com.spocky.projengmenu')
      ..notifyListeners();
    await tester.pumpAndSettle();
    expect(find.text('Home'), findsOneWidget);
    expect(find.byType(SiriWave), findsNothing);

    // Nothing to play or pause on the home screen.
    controller.pressed.clear();
    await tester.tap(find.text('Home'));
    expect(controller.pressed, isEmpty);
  });

  testWidgets('the wave holds still when the phone asks for fewer animations', (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(
      disableAnimations: true,
    );
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    final controller = _FakeController()..fakeOpenApp = const OpenApp('com.netflix.ninja');
    await tester.pumpWidget(TvRemoteApp(controller: controller));
    // Would time out if the wave kept moving.
    await tester.pumpAndSettle();
    expect(find.byType(SiriWave), findsOneWidget);
  });

  testWidgets('control mode is chosen from the more-options menu', (tester) async {
    final controller = _FakeController();
    await tester.pumpWidget(TvRemoteApp(controller: controller));
    await tester.pumpAndSettle();
    expect(find.text('Swipe'), findsNothing);

    await tester.tap(find.byTooltip('More options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Swipe'));
    await tester.pumpAndSettle();
    expect(controller.mode, ControlMode.swipe);
    expect(find.byType(SwipePad), findsOneWidget);

    await tester.tap(find.byTooltip('More options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('D-pad'));
    await tester.pumpAndSettle();
    expect(controller.mode, ControlMode.dpad);
    expect(find.byType(DPad), findsOneWidget);
  });

  testWidgets('the mic button starts and stops voice search', (tester) async {
    final controller = _FakeController();
    await tester.pumpWidget(TvRemoteApp(controller: controller));
    await tester.pumpAndSettle();

    await tester.tap(find.bySemanticsLabel('Voice search'));
    await tester.pumpAndSettle();
    expect(controller.voice, VoiceState.listening);
    expect(find.textContaining('Listening'), findsOneWidget);

    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(controller.voiceStops, 1);
    expect(find.textContaining('Listening'), findsNothing);

    // Tapping the mic again while listening also stops.
    await tester.tap(find.bySemanticsLabel('Voice search'));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Stop voice search'));
    await tester.pumpAndSettle();
    expect(controller.voiceStops, 2);

    controller.voiceResult = VoiceStartResult.noPermission;
    await tester.tap(find.bySemanticsLabel('Voice search'));
    await tester.pumpAndSettle();
    expect(find.textContaining('needs the microphone'), findsOneWidget);
  });

  testWidgets('fits on a small phone while listening, with media keys', (tester) async {
    tester.view
      ..physicalSize = const Size(360 * 3, 640 * 3)
      ..devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final controller = _FakeController()
      ..fakeOpenApp = const OpenApp('com.google.android.youtube.tv')
      ..fakeVoice = VoiceState.listening;
    await tester.pumpWidget(TvRemoteApp(controller: controller));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byType(DPad)).width, greaterThan(100));
  });

  testWidgets('holding a direction repeats it', (tester) async {
    final controller = _FakeController();
    await tester.pumpWidget(TvRemoteApp(controller: controller));
    await tester.pumpAndSettle();

    final pad = tester.getRect(find.byType(DPad));
    final gesture = await tester.startGesture(pad.center + Offset(pad.width * 0.35, 0));
    await tester.pump(const Duration(milliseconds: 300));
    expect(controller.pressed, [RemoteKey.dpadRight]);
    await tester.pump(const Duration(milliseconds: 400));
    expect(controller.pressed.length, greaterThan(2));
    await gesture.up();

    final count = controller.pressed.length;
    await tester.pump(const Duration(seconds: 1));
    expect(controller.pressed.length, count);
  });

  testWidgets('swipe mode: swipes move once, held drags repeat, taps select', (tester) async {
    final controller = _FakeController();
    await tester.pumpWidget(TvRemoteApp(controller: controller));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('More options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Swipe'));
    await tester.pumpAndSettle();
    expect(find.byType(SwipePad), findsOneWidget);
    expect(find.byType(DPad), findsNothing);
    expect(controller.mode, ControlMode.swipe);

    final center = tester.getCenter(find.byType(SwipePad));
    // A quick swipe moves once, however far it goes.
    await tester.dragFrom(center, const Offset(200, 0));
    await tester.pumpAndSettle();
    expect(controller.pressed, [RemoteKey.dpadRight]);

    controller.pressed.clear();
    await tester.dragFrom(center, const Offset(0, -100));
    await tester.pumpAndSettle();
    expect(controller.pressed, [RemoteKey.dpadUp]);

    // A slow, held drag keeps stepping: one move, then one per 80 px after
    // the repeat delay.
    controller.pressed.clear();
    await tester.timedDragFrom(center, const Offset(400, 0), const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(controller.pressed, List.filled(4, RemoteKey.dpadRight));

    controller.pressed.clear();
    await tester.flingFrom(center, const Offset(-30, 0), 1000);
    await tester.pumpAndSettle();
    expect(controller.pressed, [RemoteKey.dpadLeft]);

    controller.pressed.clear();
    await tester.tapAt(center);
    await tester.pumpAndSettle();
    expect(controller.pressed, [RemoteKey.dpadCenter]);
  });

  testWidgets('typing opens when the TV focuses a text box, and closes when it leaves', (
    tester,
  ) async {
    final controller = _FakeController();
    await tester.pumpWidget(TvRemoteApp(controller: controller));
    await tester.pumpAndSettle();

    // Without a text box on the TV, the keyboard button explains what to do.
    await tester.tap(find.bySemanticsLabel('Keyboard'));
    await tester.pumpAndSettle();
    expect(find.text('Select a text box on the TV first, then type here.'), findsOneWidget);
    expect(find.text('Type on the TV'), findsNothing);

    controller.setTextBox('Living');
    await tester.pumpAndSettle();
    expect(find.text('Type on the TV'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Living'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'Living room');
    expect(controller.typed, ['Living room']);

    // Text changed on the TV shows up on the phone.
    controller.setTextBox('Kitchen');
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'Kitchen'), findsOneWidget);

    await tester.tap(find.byTooltip('Clear'));
    expect(controller.typed.last, '');

    controller.setTextBox(null);
    await tester.pumpAndSettle();
    expect(find.text('Type on the TV'), findsNothing);
  });

  testWidgets('the keyboard button reopens typing after it was closed', (tester) async {
    final controller = _FakeController();
    await tester.pumpWidget(TvRemoteApp(controller: controller));
    await tester.pumpAndSettle();
    controller.setTextBox('');
    await tester.pumpAndSettle();

    await tester.tapAt(const Offset(20, 20)); // outside the sheet
    await tester.pumpAndSettle();
    expect(find.text('Type on the TV'), findsNothing);

    await tester.tap(find.bySemanticsLabel('Keyboard'));
    await tester.pumpAndSettle();
    expect(find.text('Type on the TV'), findsOneWidget);
  });

  testWidgets('pairing dialog lets the user fix a mistyped code', (tester) async {
    final controller = _FakeController(fakeStatus: ConnectionStatus.needsPairing);
    controller.pairingResults.addAll([const WrongPairingCodeException(), null]);
    await tester.pumpWidget(TvRemoteApp(controller: controller));
    await tester.pumpAndSettle();

    expect(find.text('Pair with Living Room TV'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'ab12c9');
    await tester.pumpAndSettle();
    expect(find.text("That code doesn't match the one on your TV."), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'AB12C3');
    await tester.pumpAndSettle();
    expect(controller.codes, ['AB12C9', 'AB12C3']);
    expect(find.text('Pair with Living Room TV'), findsNothing);
    expect(find.text('Connected'), findsOneWidget);
  });

  testWidgets('phone volume buttons control the TV only while connected and turned on', (
    tester,
  ) async {
    final calls = _mockPhone(tester);
    final controller = _FakeController();
    await tester.pumpWidget(TvRemoteApp(controller: controller));
    await tester.pumpAndSettle();
    expect(_lastCapture(calls), isTrue);

    await _pressPhoneVolume(tester, 'up');
    await _pressPhoneVolume(tester, 'down');
    expect(controller.pressed, [RemoteKey.volumeUp, RemoteKey.volumeDown]);

    // Not connected: the buttons change the phone's own volume again.
    controller
      ..fakeStatus = ConnectionStatus.disconnected
      ..notifyListeners();
    await tester.pump();
    expect(_lastCapture(calls), isFalse);

    controller
      ..fakeStatus = ConnectionStatus.connected
      ..notifyListeners();
    await tester.pump();
    expect(_lastCapture(calls), isTrue);

    // Turned off in Settings.
    await tester.tap(find.byTooltip('More options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Phone volume buttons'));
    await tester.pumpAndSettle();
    expect(controller.volumeKeysEnabled, isFalse);
    expect(_lastCapture(calls), isFalse);
  });

  testWidgets('media controls are off until turned on under Advanced settings', (tester) async {
    _mockPhone(tester);
    final controller = _FakeController();
    await tester.pumpWidget(TvRemoteApp(controller: controller));
    await tester.pumpAndSettle();
    expect(find.byType(MediaControls), findsNothing);

    await tester.tap(find.byTooltip('More options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('Advanced'), findsOneWidget);
    await tester.tap(find.text('Media controls'));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(find.byType(MediaControls), findsOneWidget);
    for (final label in ['Previous', 'Rewind', 'Play or pause', 'Fast-forward', 'Next']) {
      await tester.tap(find.bySemanticsLabel(label));
    }
    expect(controller.pressed, [
      RemoteKey.mediaPrevious,
      RemoteKey.mediaRewind,
      RemoteKey.mediaPlayPause,
      RemoteKey.mediaFastForward,
      RemoteKey.mediaNext,
    ]);
  });

  testWidgets('fits on a small phone with media controls, while listening', (tester) async {
    tester.view
      ..physicalSize = const Size(360 * 3, 640 * 3)
      ..devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    _mockPhone(tester);
    final controller = _FakeController()
      ..setMediaControlsEnabled(true)
      ..fakeVoice = VoiceState.listening;
    await tester.pumpWidget(TvRemoteApp(controller: controller));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(MediaControls), findsOneWidget);
    expect(tester.getSize(find.byType(DPad)).width, greaterThan(100));

    controller.setMode(ControlMode.swipe);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets("the cast button opens the phone's screen casting, or explains how", (tester) async {
    var castOpens = true;
    final calls = _mockPhone(tester, castOpens: () => castOpens);
    final controller = _FakeController();
    await tester.pumpWidget(TvRemoteApp(controller: controller));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Cast screen'));
    await tester.pumpAndSettle();
    expect(calls.where((call) => call.method == 'openScreenCast'), hasLength(1));
    expect(find.text('Cast your screen'), findsNothing);

    castOpens = false;
    await tester.tap(find.byTooltip('Cast screen'));
    await tester.pumpAndSettle();
    expect(find.text('Cast your screen'), findsOneWidget);
    expect(find.textContaining('Choose Living Room TV'), findsOneWidget);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.text('Cast your screen'), findsNothing);
  });

  testWidgets('the TV picker switches between, renames and removes saved TVs', (tester) async {
    tester.view
      ..physicalSize = const Size(412 * 3, 915 * 3)
      ..devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    _mockPhone(tester);
    // The sheet's search spinner never stops in tests, so wait instead of settling.
    Future<void> settle() async {
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
    }

    final store = _MemoryStore()
      ..values['saved_tvs'] =
          '[{"name":"Living room","host":"192.168.1.101"},{"name":"Bedroom","host":"192.168.1.102"}]'
      ..values['device_host'] = '192.168.1.101';
    // No identity can be made, so nothing touches the network.
    final controller = RemoteController(
      store: store,
      createIdentity: () async => throw StateError('offline'),
    );
    addTearDown(controller.dispose);
    await controller.load();
    await tester.pumpWidget(TvRemoteApp(controller: controller));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Living room'));
    await settle();
    expect(find.text('Your TVs'), findsOneWidget);
    expect(find.text('192.168.1.101 · In use'), findsOneWidget);

    // Rename the bedroom TV.
    await tester.tap(find.byTooltip('Options for Bedroom'));
    await settle();
    await tester.tap(find.text('Rename'));
    await settle();
    await tester.enterText(
      find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField)),
      'Guest room',
    );
    await tester.tap(find.text('Save'));
    await settle();
    expect(find.text('Guest room'), findsOneWidget);
    expect(controller.savedDevices.last.name, 'Guest room');

    // Switch to it.
    await tester.tap(find.text('Guest room'));
    await settle();
    expect(find.text('Choose a TV'), findsNothing);
    expect(controller.device?.host, '192.168.1.102');
    expect(find.text('Guest room'), findsOneWidget); // in the top bar

    // Remove the living room TV.
    await tester.tap(find.text('Guest room'));
    await settle();
    await tester.tap(find.byTooltip('Options for Living room'));
    await settle();
    await tester.tap(find.text('Remove'));
    await settle();
    expect(find.text('Living room'), findsNothing);
    expect(controller.savedDevices.map((d) => d.name), ['Guest room']);
    expect(controller.device?.name, 'Guest room');
  });
}
