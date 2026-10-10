import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'certificate.dart';
import 'key_codes.dart';
import 'proto.dart';

enum RemoteFailure {
  /// The TV doesn't recognise our certificate.
  needsPairing,

  /// The TV couldn't be reached or the connection dropped.
  unavailable,
}

class RemoteConnectionException implements Exception {
  const RemoteConnectionException(this.failure, this.message);

  final RemoteFailure failure;
  final String message;

  @override
  String toString() => message;
}

/// What the TV reports about itself while connected.
@immutable
class TvStatus {
  const TvStatus({this.isOn, this.volumeLevel, this.volumeMax, this.muted});

  final bool? isOn;
  final int? volumeLevel;
  final int? volumeMax;
  final bool? muted;

  TvStatus copyWith({bool? isOn, int? volumeLevel, int? volumeMax, bool? muted}) => TvStatus(
    isOn: isOn ?? this.isOn,
    volumeLevel: volumeLevel ?? this.volumeLevel,
    volumeMax: volumeMax ?? this.volumeMax,
    muted: muted ?? this.muted,
  );
}

/// The text box focused on the TV, while the TV hands typing to the phone.
@immutable
class TvTextField {
  const TvTextField({required this.text, required this.cursor});

  final String text;

  /// Where the TV inserts typed text, as a UTF-16 index into [text].
  final int cursor;

  @override
  bool operator ==(Object other) =>
      other is TvTextField && other.text == text && other.cursor == cursor;

  @override
  int get hashCode => Object.hash(text, cursor);
}

/// A paired connection to the TV's remote control service on port 6466.
class RemoteConnection {
  RemoteConnection._(this._socket, this._idleTimeout) {
    _socket.listen(_onData, onError: (_) => close(), onDone: close, cancelOnError: true);
    _socket.done.then((_) {}, onError: (_) {});
    _resetWatchdog();
  }

  static const defaultPort = 6466;
  static const _timeout = Duration(seconds: 8);

  /// The TV pings every 5 seconds when idle; silence for this long means it's gone.
  static const defaultIdleTimeout = Duration(seconds: 16);

  // RemoteMessage fields (remotemessage.proto).
  static const _remoteConfigure = 1;
  static const _remoteError = 3;
  static const _remoteSetActive = 2;
  static const _remotePingRequest = 8;
  static const _remotePingResponse = 9;
  static const _remoteKeyInject = 10;
  static const _remoteImeKeyInject = 20;
  static const _remoteImeBatchEdit = 21;
  static const _remoteImeShowRequest = 22;
  static const _remoteVoiceBegin = 30;
  static const _remoteVoicePayload = 31;
  static const _remoteVoiceEnd = 32;
  static const _remoteStart = 40;
  static const _remoteSetVolumeLevel = 50;
  static const _remoteAppLinkLaunchRequest = 90;

  // Feature flags we support, from androidtvremote2:
  // PING | KEY | IME | VOICE | POWER | VOLUME | APP_LINK.
  // With IME on, the TV shows "Use the keyboard on your mobile device" in text
  // boxes and reports them to us instead of opening its on-screen keyboard. It
  // also reports which app is open. With VOICE on, the Search key starts a
  // voice session that we stream speech into.
  static const _features = 1 | 2 | _imeFeature | _voiceFeature | 32 | 64 | _appLinkFeature;
  static const _imeFeature = 4;
  static const _voiceFeature = 8;
  static const _appLinkFeature = 512;

  final SecureSocket _socket;
  final Duration _idleTimeout;
  final _decoder = FrameDecoder();
  final _ready = Completer<void>();
  final _done = Completer<void>();
  final ValueNotifier<TvStatus> status = ValueNotifier(const TvStatus());

  /// The TV's focused text box, or null when none is waiting for typing.
  final ValueNotifier<TvTextField?> textField = ValueNotifier(null);

  /// The package of the app the TV last reported as focused, e.g.
  /// `com.netflix.ninja`. It briefly reports overlays, such as the voice search
  /// screen, and passes through other apps while switching.
  final ValueNotifier<String?> focusedApp = ValueNotifier(null);
  final _errors = StreamController<void>.broadcast(sync: true);

  /// Fires when the TV rejects a request, e.g. a link it can't open. The TV
  /// usually closes the connection right after.
  Stream<void> get errors => _errors.stream;
  Timer? _watchdog;
  bool _receivedAny = false;
  bool _closed = false;
  int _activeFeatures = _features;

  // Edits must carry the TV's latest counters, or the TV ignores them. The
  // field counter changes with every edit the TV applies.
  int _imeCounter = 0;
  int _fieldCounter = 0;

  Completer<(int id, String app)?>? _voiceBegin;
  VoiceSession? _voice;

  /// Completes when the connection closes, for any reason.
  Future<void> get done => _done.future;

  bool get isClosed => _closed;

  /// Whether the TV accepts requests to open apps. TVs that don't advertise
  /// this drop the connection if asked anyway.
  bool get supportsAppLinks => _activeFeatures & _appLinkFeature != 0;

  /// Whether the TV accepts speech for its voice search.
  bool get supportsVoice => _activeFeatures & _voiceFeature != 0;

  /// Connects and completes once the TV is ready to receive keys.
  static Future<RemoteConnection> connect({
    required String host,
    required ClientIdentity identity,
    int port = defaultPort,
    Duration idleTimeout = defaultIdleTimeout,
  }) async {
    final SecureSocket socket;
    try {
      socket = await SecureSocket.connect(
        host,
        port,
        context: identity.createSecurityContext(),
        // The TV's certificate is self-signed; trust was established by pairing.
        onBadCertificate: (_) => true,
        timeout: _timeout,
      ).timeout(_timeout);
    } on TlsException {
      throw const RemoteConnectionException(
        RemoteFailure.needsPairing,
        'The TV needs to be paired.',
      );
    } on IOException {
      throw RemoteConnectionException(RemoteFailure.unavailable, "Couldn't reach the TV at $host.");
    } on TimeoutException {
      throw RemoteConnectionException(RemoteFailure.unavailable, "Couldn't reach the TV at $host.");
    }

    final connection = RemoteConnection._(socket, idleTimeout);
    try {
      await Future.any([connection._ready.future, connection.done]).timeout(_timeout);
    } on TimeoutException {
      connection.close();
      throw const RemoteConnectionException(RemoteFailure.unavailable, "The TV didn't respond.");
    }
    if (connection.isClosed) {
      // With TLS 1.3 the TV rejects an unknown certificate after the handshake,
      // which shows up as the connection closing before the TV says anything.
      throw connection._receivedAny
          ? const RemoteConnectionException(
              RemoteFailure.unavailable,
              'The TV closed the connection.',
            )
          : const RemoteConnectionException(
              RemoteFailure.needsPairing,
              'The TV needs to be paired.',
            );
    }
    return connection;
  }

  void sendKey(RemoteKey key, [KeyDirection direction = KeyDirection.short]) =>
      sendKeyCode(key.code, direction);

  /// Sends any Android key code, including ones without a [RemoteKey].
  void sendKeyCode(int code, [KeyDirection direction = KeyDirection.short]) {
    _send(
      ProtoWriter()..message(
        _remoteKeyInject,
        ProtoWriter()
          ..varint(1, code)
          ..varint(2, direction.value),
      ),
    );
  }

  /// Replaces the UTF-16 range [start]..[end] of the focused text box with
  /// [text]. An empty range inserts at the TV's cursor, wherever [start] is.
  /// Does nothing when no text box is focused.
  void replaceText(int start, int end, String text) {
    if (textField.value == null) return;
    _send(
      ProtoWriter()..message(
        _remoteImeBatchEdit,
        ProtoWriter()
          ..varint(1, _imeCounter)
          ..varint(2, _fieldCounter)
          ..message(
            3,
            ProtoWriter() // edit_info
              ..varint(1, 1) // insert
              ..message(
                2,
                ProtoWriter() // text_field_status
                  ..varint(1, start)
                  ..varint(2, end)
                  ..string(3, text),
              ),
          ),
      ),
    );
  }

  /// Asks the TV to open [link], which an installed app must be registered for.
  /// Returns false, without sending, if the TV doesn't accept links at all.
  bool openLink(String link) {
    if (!supportsAppLinks) return false;
    _send(ProtoWriter()..message(_remoteAppLinkLaunchRequest, ProtoWriter()..string(1, link)));
    return true;
  }

  /// Opens voice search on the TV and starts a session to stream speech into.
  ///
  /// Returns null, after sending nothing or only the Search key, if the TV
  /// doesn't take voice, a session is already open, or the TV didn't start one.
  Future<VoiceSession?> startVoice({Duration timeout = const Duration(seconds: 3)}) async {
    if (!supportsVoice || _closed || _voiceBegin != null || _voice?.isEnded == false) return null;
    final begin = _voiceBegin = Completer<(int, String)?>();
    sendKey(RemoteKey.search);
    try {
      final started = await Future.any([begin.future, done.then((_) => null)]).timeout(timeout);
      if (started == null || _closed) return null;
      final (id, app) = started;
      // The TV waits for its session id to be echoed back before taking audio.
      _send(ProtoWriter()..message(_remoteVoiceBegin, ProtoWriter()..varint(1, id)));
      // The TV may have reported its voice app already, in the same burst.
      return _voice = VoiceSession._(this, id, app).._onFocusedApp(focusedApp.value);
    } on TimeoutException {
      return null;
    } finally {
      _voiceBegin = null;
    }
  }

  void _onData(Uint8List data) {
    try {
      for (final raw in _decoder.add(data)) {
        _receivedAny = true;
        _resetWatchdog();
        _handle(ProtoMessage.parse(raw));
      }
    } on FormatException {
      close();
    }
  }

  void _handle(ProtoMessage message) {
    if (message.has(_remoteConfigure)) {
      final supported = message.message(_remoteConfigure).integer(1);
      _activeFeatures = _features & supported;
      _send(
        ProtoWriter()..message(
          _remoteConfigure,
          ProtoWriter()
            ..varint(1, _activeFeatures) // code1
            ..message(
              2,
              ProtoWriter() // device_info
                ..varint(3, 1)
                ..string(4, '1')
                ..string(5, 'atvremote') // package_name
                ..string(6, '1.0.0'),
            ),
        ),
      ); // app_version
    } else if (message.has(_remoteSetActive)) {
      _send(ProtoWriter()..message(_remoteSetActive, ProtoWriter()..varint(1, _activeFeatures)));
    } else if (message.has(_remotePingRequest)) {
      final value = message.message(_remotePingRequest).integer(1);
      _send(ProtoWriter()..message(_remotePingResponse, ProtoWriter()..varint(1, value)));
    } else if (message.has(_remoteStart)) {
      status.value = status.value.copyWith(isOn: message.message(_remoteStart).boolean(1));
      if (!_ready.isCompleted) _ready.complete();
    } else if (message.has(_remoteImeKeyInject)) {
      // Sent when focus moves; it includes the text box if one has focus.
      final inject = message.message(_remoteImeKeyInject);
      final app = inject.message(1).string(12);
      if (app.isNotEmpty) {
        focusedApp.value = app;
        _voice?._onFocusedApp(app);
      }
      _setTextField(inject.has(2) ? inject.message(2) : null);
    } else if (message.has(_remoteImeShowRequest)) {
      // Sent after each change to the text box, by us or on the TV.
      final show = message.message(_remoteImeShowRequest);
      if (show.has(1)) _imeCounter = show.integer(1);
      _setTextField(show.message(2));
    } else if (message.has(_remoteImeBatchEdit)) {
      final edit = message.message(_remoteImeBatchEdit);
      _imeCounter = edit.integer(1);
      // A zero counter means the TV closed the text box (e.g. Back was pressed).
      if (_imeCounter == 0) _setTextField(null);
    } else if (message.has(_remoteVoiceBegin)) {
      final begin = _voiceBegin;
      if (begin != null && !begin.isCompleted) {
        final voice = message.message(_remoteVoiceBegin);
        // Also names the TV's voice search app, e.g. com.google.android.katniss.
        begin.complete((voice.integer(1), voice.string(2)));
      }
    } else if (message.has(_remoteVoiceEnd) || message.has(_remoteVoicePayload)) {
      // The TV gave up listening (it sends a payload message when it times out).
      _voice?._finish();
    } else if (message.has(_remoteError)) {
      _errors.add(null);
    } else if (message.has(_remoteSetVolumeLevel)) {
      final volume = message.message(_remoteSetVolumeLevel);
      status.value = status.value.copyWith(
        volumeMax: volume.integer(6),
        volumeLevel: volume.integer(7),
        muted: volume.boolean(8),
      );
    }
  }

  /// Reads a RemoteTextFieldStatus: counter, value, selection start and end.
  void _setTextField(ProtoMessage? status) {
    if (status == null) {
      textField.value = null;
      return;
    }
    _fieldCounter = status.integer(1);
    final text = status.string(2);
    textField.value = TvTextField(text: text, cursor: status.integer(4).clamp(0, text.length));
  }

  void _send(ProtoWriter message) {
    if (_closed) return;
    _socket.add(frame(message.toBytes()));
    // The TV only pings while idle, so our own traffic also counts as activity.
    _resetWatchdog();
  }

  void _resetWatchdog() {
    _watchdog?.cancel();
    _watchdog = Timer(_idleTimeout, close);
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _watchdog?.cancel();
    _socket.destroy();
    _errors.close();
    textField.value = null;
    _voice?._finish();
    if (!_done.isCompleted) _done.complete();
  }
}

/// Speech streamed into the TV's voice search, as 16-bit little-endian PCM,
/// mono, at [sampleRate].
///
/// The TV decides when the speaker has finished, searches, and closes its voice
/// screen; [done] completes then, or when [end] is called or the connection drops.
class VoiceSession {
  VoiceSession._(this._connection, this.id, this._voiceApp);

  static const sampleRate = 8000;

  /// Audio goes in messages of exactly this size. A TCL TV ignored speech sent
  /// in 8 KiB messages (the smallest an Nvidia Shield accepts) and recognised
  /// it in 20 KiB ones, the size androidtvremote2 sends.
  static const messageSize = 20 * 1024;

  final RemoteConnection _connection;
  final int id;
  final _pending = BytesBuilder();
  final _done = Completer<void>();
  final String _voiceApp;
  bool _listening = false;
  bool _ended = false;

  /// Completes when the session is over, for any reason.
  Future<void> get done => _done.future;

  bool get isEnded => _ended;

  /// Queues [samples], sending each full message as it fills up.
  void add(List<int> samples) {
    if (_ended) return;
    _pending.add(samples);
    while (_pending.length >= messageSize) {
      final bytes = _pending.takeBytes();
      _sendAudio(Uint8List.sublistView(bytes, 0, messageSize));
      _pending.add(Uint8List.sublistView(bytes, messageSize));
    }
  }

  /// Sends what's queued, padded with silence to a full message, and ends the
  /// session. The TV then searches for what it heard.
  void end() {
    if (_ended) return;
    if (_pending.isNotEmpty) _sendAudio(Uint8List(messageSize)..setAll(0, _pending.takeBytes()));
    _connection._send(
      ProtoWriter()..message(RemoteConnection._remoteVoiceEnd, ProtoWriter()..varint(1, id)),
    );
    _finish();
  }

  void _sendAudio(Uint8List samples) => _connection._send(
    ProtoWriter()..message(
      RemoteConnection._remoteVoicePayload,
      ProtoWriter()
        ..varint(1, id)
        ..bytes(2, samples),
    ),
  );

  /// The TV reports its voice app as focused while listening, then the app it
  /// opens (or returns to) once it's done. Other apps can be reported before
  /// the voice app shows up.
  void _onFocusedApp(String? app) {
    if (app == _voiceApp) {
      _listening = true;
    } else if (_listening) {
      _finish();
    }
  }

  void _finish() {
    _ended = true;
    _pending.clear();
    if (!_done.isCompleted) _done.complete();
  }
}
