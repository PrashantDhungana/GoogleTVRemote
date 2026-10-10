import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:tv_remote/tv/certificate.dart';
import 'package:tv_remote/tv/proto.dart';

/// A stand-in for a TV's remote service, speaking the pairing (polo) and
/// remote protocols over real TLS sockets on localhost.
///
/// Like a real TV, the remote port only works for a client that has paired.
/// The TLS layer trusts only [client]'s certificate, so any other identity is
/// rejected during the handshake.
class FakeTv {
  FakeTv._(this._tvIdentity, this._pairingServer, this._remoteServer) {
    // Handshake failures (e.g. an untrusted client certificate) surface as
    // errors on the server stream; the server keeps accepting connections.
    _pairingServer.listen(_servePairing, onError: (_) {});
    _remoteServer.listen(_serveRemote, onError: (_) {});
  }

  static Future<FakeTv> start({
    required ClientIdentity tvIdentity,
    required ClientIdentity client,
  }) async {
    SecurityContext context() =>
        tvIdentity.createSecurityContext()
          ..setTrustedCertificatesBytes(utf8.encode(client.certificatePem));
    final pairing = await SecureServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
      context(),
      requireClientCertificate: true,
    );
    final remote = await SecureServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
      context(),
      requireClientCertificate: true,
    );
    return FakeTv._(tvIdentity, pairing, remote);
  }

  final ClientIdentity _tvIdentity;
  final SecureServerSocket _pairingServer;
  final SecureServerSocket _remoteServer;
  final _remoteClients = <SecureSocket>[];
  final _keys = StreamController<(int code, int direction)>.broadcast();
  final _pings = StreamController<int>.broadcast();
  final _appLinks = StreamController<String>.broadcast();
  Completer<String> _code = Completer();

  int get pairingPort => _pairingServer.port;
  int get remotePort => _remoteServer.port;

  bool paired = false;
  bool rejectSecrets = false;
  bool isOn = true;

  /// Feature flags advertised in remote_configure. 622 includes APP_LINK (512).
  int supportedFeatures = 622;

  /// Links to answer like a TV that can't open them: an error, then disconnecting.
  bool Function(String link) rejectLink = (link) => link.startsWith('android-app:');
  String? pairingClientName;
  int? activeFeatures;

  /// The focused text box, which the client types into once it enabled IME.
  /// Behaves like a TCL Google TV: edits must carry the latest field counter,
  /// an empty range inserts at the cursor a character at a time, and a range
  /// is replaced in one step.
  String? text;
  int textCursor = 0;
  int _fieldCounter = 100;

  /// Edits rejected because their field counter was out of date.
  int staleEdits = 0;

  /// The voice search app, which a TCL Google TV names in remote_voice_begin
  /// and then reports as focused while listening.
  static const voiceApp = 'com.google.android.katniss';
  int _voiceSessions = 0;

  /// Voice sessions the client echoed back to start streaming.
  final voiceBegins = <int>[];

  /// Audio messages received, as (session id, samples).
  final voicePayloads = <(int session, Uint8List samples)>[];

  /// Sessions the client ended.
  final voiceEnds = <int>[];

  /// Completes with the code the TV "displays" once pairing is configured.
  Future<String> get displayedCode => _code.future;

  /// Key presses received, as (Android key code, RemoteDirection).
  Stream<(int code, int direction)> get keys => _keys.stream;

  /// Values of ping responses received.
  Stream<int> get pingResponses => _pings.stream;

  /// App links the client asked the TV to open.
  Stream<String> get appLinks => _appLinks.stream;

  void ping(int value) => _broadcast(
    ProtoWriter()..message(
      8,
      ProtoWriter()
        ..varint(1, value)
        ..varint(2, 0),
    ),
  );

  /// Focuses a text box holding [value], as when the user selects one on the TV.
  void focusTextField([String value = '']) {
    text = value;
    textCursor = value.length;
    _fieldCounter += 3;
    _broadcast(
      ProtoWriter()..message(
        20,
        ProtoWriter()
          ..message(1, ProtoWriter()..string(12, 'com.android.tv.settings'))
          ..message(2, _textFieldStatus()),
      ),
    );
    _broadcast(
      ProtoWriter()..message(
        21,
        ProtoWriter()
          ..varint(1, 1)
          ..varint(2, 0),
      ),
    );
  }

  /// Leaves the text box, as when the user presses Back on the TV.
  void leaveTextField() {
    text = null;
    _broadcast(
      ProtoWriter()..message(
        21,
        ProtoWriter()
          ..varint(1, 0)
          ..varint(2, 0),
      ),
    );
    _broadcast(
      ProtoWriter()..message(
        20,
        ProtoWriter()..message(1, ProtoWriter()..string(12, 'com.android.tv.settings')),
      ),
    );
  }

  /// Reports [package] as the focused app, as the TV does whenever focus moves.
  void reportApp(String package) => _broadcast(
    ProtoWriter()..message(20, ProtoWriter()..message(1, ProtoWriter()..string(12, package))),
  );

  void _startVoice() {
    _voiceSessions++;
    _broadcast(
      ProtoWriter()..message(
        30,
        ProtoWriter()
          ..varint(1, _voiceSessions)
          ..string(2, voiceApp),
      ),
    );
    reportApp(voiceApp);
  }

  /// Changes the text box on the TV's side, e.g. with the TV's own keyboard.
  void typeOnTv(String value) {
    text = value;
    textCursor = value.length;
    _reportText();
  }

  ProtoWriter _textFieldStatus() => ProtoWriter()
    ..varint(1, _fieldCounter)
    ..string(2, text!)
    ..varint(3, textCursor)
    ..varint(4, textCursor)
    ..varint(5, 1);

  void _reportText() {
    _fieldCounter++;
    _broadcast(ProtoWriter()..message(22, ProtoWriter()..message(2, _textFieldStatus())));
  }

  void _applyEdit(ProtoMessage edit) {
    final current = text;
    if (current == null) return;
    if (edit.integer(2) != _fieldCounter) {
      staleEdits++;
      return;
    }
    final change = edit.message(3).message(2);
    final start = change.integer(1);
    final end = change.integer(2);
    final value = change.string(3);
    if (start == end) {
      for (final rune in value.runes) {
        final char = String.fromCharCode(rune);
        text = text!.substring(0, textCursor) + char + text!.substring(textCursor);
        textCursor += char.length;
        _reportText();
      }
    } else {
      final from = start.clamp(0, current.length);
      final to = end.clamp(from, current.length);
      text = current.substring(0, from) + value + current.substring(to);
      textCursor = from + value.length;
      _reportText();
    }
  }

  /// Simulates the TV dropping off the network.
  void dropConnections() {
    final sockets = [..._remoteClients];
    _remoteClients.clear();
    for (final socket in sockets) {
      socket.destroy();
    }
  }

  Future<void> close() async {
    dropConnections();
    await _pairingServer.close();
    await _remoteServer.close();
    await _keys.close();
    await _pings.close();
    await _appLinks.close();
  }

  void _servePairing(SecureSocket socket) {
    final decoder = FrameDecoder();
    Uint8List? expectedSecret;
    void reply(void Function(ProtoWriter message) build, {int status = 200}) {
      final message = ProtoWriter()
        ..varint(1, 2)
        ..varint(2, status);
      build(message);
      socket.add(frame(message.toBytes()));
    }

    socket.listen((data) {
      for (final raw in decoder.add(data)) {
        final message = ProtoMessage.parse(raw);
        if (message.has(10)) {
          pairingClientName = message.message(10).string(2);
          reply((m) => m.message(11, ProtoWriter()..string(1, 'Fake TV')));
        } else if (message.has(20)) {
          reply(
            (m) => m.message(
              20,
              ProtoWriter()
                ..message(
                  1,
                  ProtoWriter()
                    ..varint(1, 3)
                    ..varint(2, 6),
                )
                ..varint(3, 1),
            ),
          );
        } else if (message.has(30)) {
          // The client's certificate comes from the TLS session, as on a real TV.
          final client = RsaPublicNumbers.fromCertificateDer(socket.peerCertificate!.der);
          final nonce = [Random().nextInt(256), Random().nextInt(256)];
          expectedSecret = _hash(client, _tvIdentity.publicNumbers, nonce);
          _code = Completer()..complete(_toHex([expectedSecret![0], ...nonce]));
          reply((m) => m.bytes(31, []));
        } else if (message.has(40)) {
          final secret = message.message(40).bytes(1);
          if (!rejectSecrets && _toHex(secret) == _toHex(expectedSecret ?? [])) {
            paired = true;
            reply((m) => m.message(41, ProtoWriter()..bytes(1, secret)));
          } else {
            reply((_) {}, status: 402);
          }
          socket.close();
        }
      }
    }, onError: (_) {});
  }

  void _serveRemote(SecureSocket socket) {
    if (!paired) {
      socket.destroy();
      return;
    }
    _remoteClients.add(socket);
    final decoder = FrameDecoder();
    void send(ProtoWriter message) => socket.add(frame(message.toBytes()));

    socket.listen(
      (data) {
        for (final raw in decoder.add(data)) {
          final message = ProtoMessage.parse(raw);
          if (message.has(1)) {
            // Client's reply to remote_configure.
            send(ProtoWriter()..message(2, ProtoWriter()));
          } else if (message.has(2)) {
            activeFeatures = message.message(2).integer(1);
            send(ProtoWriter()..message(40, ProtoWriter()..boolean(1, isOn)));
            send(
              ProtoWriter()..message(
                50,
                ProtoWriter()
                  ..varint(6, 100)
                  ..varint(7, 15)
                  ..boolean(8, false),
              ),
            );
          } else if (message.has(9)) {
            _pings.add(message.message(9).integer(1));
          } else if (message.has(10)) {
            final key = message.message(10);
            _keys.add((key.integer(1), key.integer(2)));
            // Search opens voice search, which streams from the client once VOICE is on.
            if (key.integer(1) == 84 && (activeFeatures ?? 0) & 8 != 0) _startVoice();
          } else if (message.has(30)) {
            voiceBegins.add(message.message(30).integer(1));
          } else if (message.has(31)) {
            final payload = message.message(31);
            voicePayloads.add((payload.integer(1), payload.bytes(2)));
          } else if (message.has(32)) {
            voiceEnds.add(message.message(32).integer(1));
          } else if (message.has(21)) {
            _applyEdit(message.message(21));
          } else if (message.has(90)) {
            final link = message.message(90).string(1);
            _appLinks.add(link);
            if (rejectLink(link)) {
              send(ProtoWriter()..message(3, ProtoWriter()..boolean(1, true)));
              socket.destroy();
            }
          }
        }
      },
      onError: (_) {},
      onDone: () => _remoteClients.remove(socket),
    );

    send(
      ProtoWriter()..message(
        1,
        ProtoWriter()
          ..varint(1, supportedFeatures)
          ..message(
            2,
            ProtoWriter()
              ..string(1, 'Fake TV')
              ..string(2, 'Test'),
          ),
      ),
    );
  }

  void _broadcast(ProtoWriter message) {
    for (final socket in [..._remoteClients]) {
      socket.add(frame(message.toBytes()));
    }
  }

  // Written independently of computePairingSecret, from androidtvremote2's pairing.py.
  static Uint8List _hash(RsaPublicNumbers client, RsaPublicNumbers tv, List<int> nonce) {
    List<int> bytes(String hex) => [
      for (var i = 0; i < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16),
    ];
    final digest = sha256.convert([
      ...bytes(client.modulus.toRadixString(16)),
      ...bytes('0${client.exponent.toRadixString(16)}'),
      ...bytes(tv.modulus.toRadixString(16)),
      ...bytes('0${tv.exponent.toRadixString(16)}'),
      ...nonce,
    ]);
    return Uint8List.fromList(digest.bytes);
  }

  static String _toHex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join().toUpperCase();
}
