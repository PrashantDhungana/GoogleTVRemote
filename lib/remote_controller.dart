import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'tv/certificate.dart';
import 'tv/discovery.dart';
import 'tv/key_codes.dart';
import 'tv/pairing.dart';
import 'tv/remote_connection.dart';
import 'tv/text_input.dart';
import 'tv/tv_app.dart';
import 'voice_input.dart';

enum ConnectionStatus { noDevice, preparing, connecting, connected, disconnected, needsPairing }

enum ControlMode { dpad, swipe }

/// [needsSetup]: the app button hasn't been matched to one of the TV's app keys yet.
enum AppLaunchResult { sent, notConnected, needsSetup }

enum VoiceState { idle, starting, listening }

enum VoiceStartResult {
  started,
  cancelled,
  notConnected,
  unsupported,
  noPermission,
  noMicrophone,
  noResponse,
}

/// Key-value persistence, abstracted so tests can run without platform channels.
abstract interface class SettingsStore {
  Future<String?> read(String key);
  Future<void> write(String key, String? value);
}

class SharedPreferencesStore implements SettingsStore {
  final _prefs = SharedPreferencesAsync();

  @override
  Future<String?> read(String key) => _prefs.getString(key);

  @override
  Future<void> write(String key, String? value) =>
      value == null ? _prefs.remove(key) : _prefs.setString(key, value);
}

/// App state: which TV is selected, the connection to it, and the remote's settings.
class RemoteController extends ChangeNotifier {
  RemoteController({
    SettingsStore? store,
    Future<ClientIdentity> Function()? createIdentity,
    this.remotePort = RemoteConnection.defaultPort,
    this.pairingPort = PairingSession.defaultPort,
    VoiceInput? voiceInput,
    this.appSettleDelay = const Duration(seconds: 1),
  }) : _store = store ?? SharedPreferencesStore(),
       _createIdentity = createIdentity ?? _generateIdentity,
       _voiceInput = voiceInput ?? MicrophoneInput();

  /// Shown on the TV while pairing.
  static const clientName = 'TV Remote';

  /// Voice search stops listening after this long, if the TV hasn't already.
  static const maxListening = Duration(seconds: 15);

  static const _initialRetryDelay = Duration(seconds: 1);
  static const _maxRetryDelay = Duration(seconds: 30);

  static const _certificateKey = 'client_certificate';
  static const _privateKeyKey = 'client_private_key';
  static const _deviceNameKey = 'device_name';
  static const _deviceHostKey = 'device_host';
  static const _savedDevicesKey = 'saved_tvs';
  static const _modeKey = 'control_mode';
  static const _volumeKeysKey = 'volume_keys';
  static const _mediaControlsKey = 'media_controls';
  static String _appKeyKey(TvApp app) => 'app_key_${app.name}';

  /// Stored instead of a key code when an app button should use an app link.
  static const appLinkChoice = 0;

  final SettingsStore _store;
  final Future<ClientIdentity> Function() _createIdentity;
  final int remotePort;
  final int pairingPort;
  final VoiceInput _voiceInput;

  /// The TV passes through other apps while switching, so a reported app is
  /// only shown once it has stayed this long.
  final Duration appSettleDelay;

  TvDevice? _device;
  final List<TvDevice> _savedDevices = [];
  ConnectionStatus _status = ConnectionStatus.noDevice;
  String? _message;
  ControlMode _mode = ControlMode.dpad;
  bool _volumeKeys = true;
  bool _mediaControls = false;
  TvStatus _tv = const TvStatus();
  final Map<TvApp, int> _appKeys = {};
  OpenApp? _openApp;
  Timer? _appTimer;
  VoiceState _voice = VoiceState.idle;
  VoiceSession? _voiceSession;
  StreamSubscription<Uint8List>? _microphone;
  Timer? _voiceTimer;
  int _voiceAttempt = 0;

  Future<ClientIdentity>? _identity;
  RemoteConnection? _connection;
  TextSync? _textSync;
  PairingSession? _pairing;
  Timer? _retryTimer;
  Duration _retryDelay = _initialRetryDelay;
  bool _foreground = true;
  bool _disposed = false;

  /// Incremented to invalidate in-flight connection and pairing attempts.
  int _connectAttempt = 0;
  int _pairingAttempt = 0;

  TvDevice? get device => _device;

  /// Every TV chosen so far, in the order they were added.
  List<TvDevice> get savedDevices => List.unmodifiable(_savedDevices);

  ConnectionStatus get status => _status;
  ControlMode get mode => _mode;
  TvStatus get tv => _tv;
  bool get isConnected => _status == ConnectionStatus.connected;

  /// Whether the phone's volume buttons control the TV while the app is open.
  bool get volumeKeysEnabled => _volumeKeys;

  /// Whether the play/pause, rewind, fast-forward, previous and next buttons show.
  bool get mediaControlsEnabled => _mediaControls;

  /// The app open on the TV, once the TV has reported one and settled on it.
  OpenApp? get openApp => _openApp;

  VoiceState get voice => _voice;

  /// Detail about the last failure, if any.
  String? get message => _message;

  /// Whether a text box on the TV is waiting for the phone's keyboard.
  bool get canType => _textSync?.active ?? false;

  /// The text in the TV's text box, including typing still on its way.
  String get typedText => _textSync?.text ?? '';

  /// Makes the TV's focused text box read [text].
  void type(String text) => _textSync?.setText(text);

  Future<void> load() async {
    _mode = ControlMode.values.asNameMap()[await _store.read(_modeKey)] ?? ControlMode.dpad;
    _volumeKeys = await _store.read(_volumeKeysKey) != 'false';
    _mediaControls = await _store.read(_mediaControlsKey) == 'true';
    for (final app in TvApp.values) {
      final code = int.tryParse(await _store.read(_appKeyKey(app)) ?? '');
      if (code != null) _appKeys[app] = code;
    }
    final name = await _store.read(_deviceNameKey);
    final host = await _store.read(_deviceHostKey);
    _savedDevices.addAll(_decodeDevices(await _store.read(_savedDevicesKey)));
    if (host != null) {
      _device = _savedDevices.where((d) => d.host == host).firstOrNull;
      if (_device == null) {
        // Saved before several TVs were remembered.
        _device = TvDevice(name: name ?? host, host: host);
        _savedDevices.add(_device!);
        await _saveDevices();
      }
      _setStatus(ConnectionStatus.disconnected);
      unawaited(connect());
    } else {
      _notify();
    }
  }

  /// Switches to [device], remembering it. A TV that was already saved keeps
  /// the name the user gave it, and takes [device]'s address if it moved.
  Future<void> selectDevice(TvDevice device) async {
    final index = _savedIndex(device);
    if (index >= 0) {
      device = _savedDevices[index].copyWith(host: device.host);
      _savedDevices[index] = device;
    } else {
      _savedDevices.add(device);
    }
    await _saveDevices();
    final busy = const {
      ConnectionStatus.connected,
      ConnectionStatus.connecting,
      ConnectionStatus.preparing,
    }.contains(_status);
    if (device.host == _device?.host && busy) {
      // Already this TV; just pick up a new name.
      _device = device;
      _notify();
      return;
    }
    _cancelPairing();
    _disconnect();
    _device = device;
    _tv = const TvStatus();
    _retryDelay = _initialRetryDelay;
    _setStatus(ConnectionStatus.disconnected);
    await _writeCurrentDevice();
    await connect();
  }

  /// The saved TV that [device] is: the same address, or the same TV seen at a new one.
  TvDevice? savedMatch(TvDevice device) {
    final index = _savedIndex(device);
    return index < 0 ? null : _savedDevices[index];
  }

  int _savedIndex(TvDevice device) {
    final byHost = _savedDevices.indexWhere((d) => d.host == device.host);
    if (byHost >= 0 || device.serviceName == null) return byHost;
    return _savedDevices.indexWhere((d) => d.serviceName == device.serviceName);
  }

  /// Notes that a saved TV is now at [host], as discovery saw it.
  Future<void> updateAddress(TvDevice saved, String host) async {
    final index = _savedDevices.indexWhere((d) => d.host == saved.host);
    if (index < 0 || saved.host == host || _savedDevices.any((d) => d.host == host)) return;
    final moved = _savedDevices[index].copyWith(host: host);
    _savedDevices[index] = moved;
    await _saveDevices();
    if (_device?.host == saved.host) {
      _device = moved;
      await _writeCurrentDevice();
      if (_status != ConnectionStatus.connected) retry();
    }
    _notify();
  }

  Future<void> renameDevice(TvDevice device, String name) async {
    name = name.trim();
    final index = _savedDevices.indexWhere((d) => d.host == device.host);
    if (name.isEmpty || index < 0) return;
    final renamed = _savedDevices[index].copyWith(name: name);
    _savedDevices[index] = renamed;
    if (_device?.host == device.host) _device = renamed;
    _notify();
    await _saveDevices();
    if (_device == renamed) await _writeCurrentDevice();
  }

  /// Forgets a saved TV. Forgetting the current one leaves no TV chosen.
  Future<void> forgetDevice(TvDevice device) async {
    _savedDevices.removeWhere((d) => d.host == device.host);
    if (_device?.host == device.host) {
      _cancelPairing();
      _disconnect();
      _device = null;
      _tv = const TvStatus();
      _setStatus(ConnectionStatus.noDevice);
      await _writeCurrentDevice();
    } else {
      _notify();
    }
    await _saveDevices();
  }

  Future<void> _writeCurrentDevice() async {
    await _store.write(_deviceNameKey, _device?.name);
    await _store.write(_deviceHostKey, _device?.host);
  }

  Future<void> _saveDevices() => _store.write(
    _savedDevicesKey,
    jsonEncode([for (final device in _savedDevices) device.toJson()]),
  );

  static List<TvDevice> _decodeDevices(String? json) {
    if (json == null) return const [];
    try {
      return [for (final item in jsonDecode(json) as List<Object?>) ?TvDevice.fromJson(item)];
    } on FormatException {
      return const [];
    } on TypeError {
      return const [];
    }
  }

  void setVolumeKeysEnabled(bool enabled) {
    if (enabled == _volumeKeys) return;
    _volumeKeys = enabled;
    _notify();
    _store.write(_volumeKeysKey, '$enabled');
  }

  void setMediaControlsEnabled(bool enabled) {
    if (enabled == _mediaControls) return;
    _mediaControls = enabled;
    _notify();
    _store.write(_mediaControlsKey, '$enabled');
  }

  void setMode(ControlMode mode) {
    if (mode == _mode) return;
    _mode = mode;
    _notify();
    _store.write(_modeKey, mode.name);
  }

  /// Called with the app's lifecycle: the connection is only kept while visible.
  void setForeground(bool foreground) {
    if (foreground == _foreground) return;
    _foreground = foreground;
    if (foreground) {
      _retryDelay = _initialRetryDelay;
      if (_status == ConnectionStatus.disconnected) connect();
    } else if (_status != ConnectionStatus.needsPairing && _status != ConnectionStatus.noDevice) {
      _disconnect();
      _setStatus(ConnectionStatus.disconnected);
    }
  }

  /// Sends [key] to the TV. Returns false (and tries to reconnect) when not connected.
  bool press(RemoteKey key, [KeyDirection direction = KeyDirection.short]) {
    final connection = _usableConnection();
    connection?.sendKey(key, direction);
    return connection != null;
  }

  /// Opens [app] on the TV, trying to reconnect when not connected.
  ///
  /// Sends the app's link, unless the user matched it to one of the TV's app
  /// keys instead (see [setAppKey]) for TVs that don't accept app links.
  AppLaunchResult launchApp(TvApp app) {
    final connection = _usableConnection();
    if (connection == null) return AppLaunchResult.notConnected;
    final code = _appKeys[app] ?? appLinkChoice;
    if (code == appLinkChoice) {
      return connection.openLink(app.link) ? AppLaunchResult.sent : AppLaunchResult.needsSetup;
    }
    connection.sendKeyCode(code);
    return AppLaunchResult.sent;
  }

  /// The key code (or [appLinkChoice]) each app button sends.
  Map<TvApp, int> get appKeys => Map.unmodifiable(_appKeys);

  /// Whether the connected TV accepts app links, offered as one of the setup choices.
  bool get supportsAppLinks => _connection?.supportsAppLinks ?? false;

  Future<void> setAppKey(TvApp app, int? code) async {
    if (code == null) {
      _appKeys.remove(app);
    } else {
      _appKeys[app] = code;
    }
    _notify();
    await _store.write(_appKeyKey(app), code?.toString());
  }

  /// Sends a raw key code, for trying out app keys. Returns false when not connected.
  bool pressCode(int code) {
    final connection = _usableConnection();
    connection?.sendKeyCode(code);
    return connection != null;
  }

  /// Sends [app]'s app link if the TV supports them, for trying it out.
  bool tryAppLink(TvApp app) => _usableConnection()?.openLink(app.link) ?? false;

  RemoteConnection? _usableConnection() {
    final connection = _connection;
    if (connection == null || connection.isClosed) {
      if (_status == ConnectionStatus.disconnected) retry();
      return null;
    }
    return connection;
  }

  /// Records the phone's microphone and streams it to the TV's voice search,
  /// until the TV has heard a search (it decides when the speaker is done),
  /// [stopVoice] is called, or [maxListening] passes.
  Future<VoiceStartResult> startVoice() async {
    if (_voice != VoiceState.idle) return VoiceStartResult.started;
    if (_usableConnection() == null) return VoiceStartResult.notConnected;
    if (!_connection!.supportsVoice) return VoiceStartResult.unsupported;
    final attempt = ++_voiceAttempt;
    _setVoice(VoiceState.starting);

    final allowed = await _voiceInput.requestPermission().catchError((_) => false);
    if (attempt != _voiceAttempt) return VoiceStartResult.cancelled;
    final connection = _usableConnection();
    if (!allowed || connection == null) {
      stopVoice();
      return allowed ? VoiceStartResult.notConnected : VoiceStartResult.noPermission;
    }

    // Record straight away, so nothing said while the TV opens its voice
    // screen is lost; it's held until the TV's session starts.
    final Stream<Uint8List> audio;
    try {
      audio = await _voiceInput.start();
    } catch (_) {
      if (attempt == _voiceAttempt) stopVoice();
      return VoiceStartResult.noMicrophone;
    }
    if (attempt != _voiceAttempt) {
      _voiceInput.stop().catchError((_) {});
      return VoiceStartResult.cancelled;
    }
    final early = BytesBuilder();
    VoiceSession? session;
    _microphone = audio.listen((samples) {
      final current = session;
      current == null ? early.add(samples) : current.add(samples);
    });

    session = await connection.startVoice();
    if (attempt != _voiceAttempt) {
      session?.end();
      return VoiceStartResult.cancelled;
    }
    if (session == null) {
      stopVoice();
      return VoiceStartResult.noResponse;
    }
    _voiceSession = session;
    session.add(early.takeBytes());
    _voiceTimer = Timer(maxListening, stopVoice);
    session.done.then((_) {
      if (identical(_voiceSession, session)) stopVoice();
    });
    _setVoice(VoiceState.listening);
    return VoiceStartResult.started;
  }

  /// Stops listening; the TV searches for what it heard so far.
  void stopVoice() {
    _voiceAttempt++;
    _voiceTimer?.cancel();
    _voiceSession?.end();
    _voiceSession = null;
    final microphone = _microphone;
    _microphone = null;
    if (microphone != null) {
      microphone.cancel();
      _voiceInput.stop().catchError((_) {});
    }
    _setVoice(VoiceState.idle);
  }

  void _setVoice(VoiceState voice) {
    if (voice == _voice) return;
    _voice = voice;
    _notify();
  }

  void retry() {
    _retryDelay = _initialRetryDelay;
    connect();
  }

  Future<void> connect() async {
    final device = _device;
    if (device == null || !_foreground || _pairing != null) return;
    if (_status
        case ConnectionStatus.preparing ||
            ConnectionStatus.connecting ||
            ConnectionStatus.connected) {
      return;
    }
    _retryTimer?.cancel();
    final attempt = ++_connectAttempt;
    _setStatus(ConnectionStatus.connecting);
    try {
      final identity = await _ensureIdentity();
      if (attempt != _connectAttempt) return;
      _setStatus(ConnectionStatus.connecting);
      final connection = await RemoteConnection.connect(
        host: device.host,
        identity: identity,
        port: remotePort,
      );
      if (attempt != _connectAttempt || _disposed) {
        connection.close();
        return;
      }
      _attach(connection);
    } on RemoteConnectionException catch (e) {
      if (attempt != _connectAttempt) return;
      if (e.failure == RemoteFailure.needsPairing) {
        _setStatus(ConnectionStatus.needsPairing, e.message);
      } else {
        _setStatus(ConnectionStatus.disconnected, e.message);
        _scheduleRetry();
      }
    } catch (e) {
      if (attempt != _connectAttempt) return;
      _setStatus(ConnectionStatus.disconnected, 'Something went wrong: $e');
    }
  }

  /// Connects to the TV's pairing service, which makes the TV show a code.
  Future<void> startPairing() async {
    final device = _device;
    if (device == null) throw const PairingException('Choose a TV first.');
    _cancelPairing();
    _disconnect();
    _setStatus(ConnectionStatus.needsPairing);
    final attempt = _pairingAttempt;
    final identity = await _ensureIdentity();
    if (attempt != _pairingAttempt) throw const PairingException('Pairing was cancelled.');
    if (_status == ConnectionStatus.preparing) _setStatus(ConnectionStatus.needsPairing);
    final session = await PairingSession.start(
      host: device.host,
      identity: identity,
      clientName: clientName,
      port: pairingPort,
    );
    if (attempt != _pairingAttempt || _disposed) {
      session.close();
      throw const PairingException('Pairing was cancelled.');
    }
    _pairing = session;
  }

  /// Completes pairing with the [code] shown on the TV, then connects.
  ///
  /// A [WrongPairingCodeException] leaves the session open for another try;
  /// any other [PairingException] means pairing must be started again.
  Future<void> finishPairing(String code) async {
    final session = _pairing;
    if (session == null) throw const PairingException('Pairing has ended. Start again.');
    try {
      await session.finish(code);
    } on WrongPairingCodeException {
      rethrow;
    } catch (_) {
      if (identical(_pairing, session)) _pairing = null;
      rethrow;
    }
    if (!identical(_pairing, session)) return;
    _pairing = null;
    _retryDelay = _initialRetryDelay;
    _setStatus(ConnectionStatus.disconnected);
    unawaited(connect());
  }

  void cancelPairing() => _cancelPairing();

  void _cancelPairing() {
    _pairingAttempt++;
    _pairing?.close();
    _pairing = null;
  }

  Future<ClientIdentity> _ensureIdentity() => _identity ??= _loadIdentity().catchError((Object e) {
    _identity = null;
    throw e;
  });

  Future<ClientIdentity> _loadIdentity() async {
    final certificate = await _store.read(_certificateKey);
    final privateKey = await _store.read(_privateKeyKey);
    if (certificate != null && privateKey != null) {
      return ClientIdentity(certificatePem: certificate, privateKeyPem: privateKey);
    }
    _setStatus(ConnectionStatus.preparing);
    final identity = await _createIdentity();
    await _store.write(_certificateKey, identity.certificatePem);
    await _store.write(_privateKeyKey, identity.privateKeyPem);
    return identity;
  }

  static Future<ClientIdentity> _generateIdentity() => Isolate.run(ClientIdentity.generate);

  void _attach(RemoteConnection connection) {
    _connection = connection;
    _retryDelay = _initialRetryDelay;
    _tv = connection.status.value;
    connection.status.addListener(() {
      if (!identical(_connection, connection)) return;
      _tv = connection.status.value;
      _notify();
    });
    _textSync = TextSync(connection)..addListener(_notify);
    connection.focusedApp.addListener(() {
      final package = connection.focusedApp.value;
      if (!identical(_connection, connection) || package == null) return;
      if (OpenApp.overlays.contains(package)) return;
      _appTimer?.cancel();
      _appTimer = Timer(appSettleDelay, () {
        if (!identical(_connection, connection) || OpenApp(package) == _openApp) return;
        _openApp = OpenApp(package);
        _notify();
      });
    });
    var rejectedLink = false;
    connection.errors.listen((_) => rejectedLink = true);
    _setStatus(ConnectionStatus.connected);
    connection.done.then((_) {
      if (!identical(_connection, connection)) return;
      _connection = null;
      _dropConnectionState();
      _setStatus(
        ConnectionStatus.disconnected,
        rejectedLink ? "Your TV couldn't open that app link." : 'Lost connection to the TV.',
      );
      _scheduleRetry();
    });
  }

  void _scheduleRetry() {
    _retryTimer?.cancel();
    if (!_foreground || _device == null || _disposed) return;
    final delay = _retryDelay;
    _retryDelay = Duration(
      milliseconds: min(delay.inMilliseconds * 2, _maxRetryDelay.inMilliseconds),
    );
    _retryTimer = Timer(delay, connect);
  }

  void _disconnect() {
    _connectAttempt++;
    _retryTimer?.cancel();
    final connection = _connection;
    _connection = null;
    _dropConnectionState();
    connection?.close();
  }

  /// Forgets what was learned from, or started on, a connection that is going away.
  void _dropConnectionState() {
    _textSync?.dispose();
    _textSync = null;
    _appTimer?.cancel();
    _openApp = null;
    if (_voice != VoiceState.idle) stopVoice();
  }

  void _setStatus(ConnectionStatus status, [String? message]) {
    _status = status;
    _message = message;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelPairing();
    _disconnect();
    super.dispose();
  }
}
