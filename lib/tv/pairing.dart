import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'certificate.dart';
import 'proto.dart';

class PairingException implements Exception {
  const PairingException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The code didn't match. The session stays open, so the user can retype it.
class WrongPairingCodeException extends PairingException {
  const WrongPairingCodeException() : super("That code doesn't match the one on your TV.");
}

/// Pairs a [ClientIdentity] with a TV using the polo protocol on port 6467.
///
/// [start] makes the TV display a 6 character code; [finish] sends the secret
/// derived from that code. Once paired, the TV accepts the identity's
/// certificate on the remote control port.
class PairingSession {
  PairingSession._(this._socket, this._identity) {
    _socket.listen(
      _onData,
      onError: (Object error) => _fail(PairingException('Pairing connection failed: $error')),
      onDone: () => _fail(const PairingException('The TV closed the pairing connection.')),
      cancelOnError: true,
    );
    _socket.done.then((_) {}, onError: (_) {});
  }

  static const defaultPort = 6467;
  static const _timeout = Duration(seconds: 10);

  // OuterMessage fields (polo.proto).
  static const _protocolVersion = 1;
  static const _status = 2;
  static const _pairingRequest = 10;
  static const _pairingRequestAck = 11;
  static const _options = 20;
  static const _configuration = 30;
  static const _configurationAck = 31;
  static const _secret = 40;
  static const _secretAck = 41;

  static const _statusOk = 200;
  static const _encodingHexadecimal = 3;
  static const _roleInput = 1;
  static const _codeLength = 6;

  final SecureSocket _socket;
  final ClientIdentity _identity;
  final _decoder = FrameDecoder();
  Completer<void>? _pending;
  PairingException? _failure;
  bool _closed = false;

  /// Connects to the TV and asks it to show a pairing code.
  static Future<PairingSession> start({
    required String host,
    required ClientIdentity identity,
    required String clientName,
    int port = defaultPort,
  }) async {
    final SecureSocket socket;
    try {
      socket = await SecureSocket.connect(
        host,
        port,
        context: identity.createSecurityContext(),
        // The TV uses a self-signed certificate; pairing itself authenticates it.
        onBadCertificate: (_) => true,
        timeout: _timeout,
      ).timeout(_timeout);
    } on IOException {
      throw PairingException("Couldn't reach the TV at $host.");
    } on TimeoutException {
      throw PairingException("Couldn't reach the TV at $host.");
    }
    final session = PairingSession._(socket, identity);
    try {
      await session._request(
        _message((m) {
          m.message(
            _pairingRequest,
            ProtoWriter()
              ..string(1, 'atvremote') // service_name
              ..string(2, clientName),
          );
        }),
      );
    } catch (_) {
      session.close();
      rethrow;
    }
    return session;
  }

  /// Sends the secret for [code] and waits for the TV to accept it.
  ///
  /// Throws [WrongPairingCodeException] without contacting the TV if the code
  /// fails its check byte, so the user can retry in the same session.
  Future<void> finish(String code) async {
    final serverCertificate = _socket.peerCertificate;
    if (serverCertificate == null) {
      throw const PairingException('The TV did not present a certificate.');
    }
    final Uint8List? secret;
    try {
      secret = computePairingSecret(
        client: _identity.publicNumbers,
        server: RsaPublicNumbers.fromCertificateDer(serverCertificate.der),
        code: code.trim(),
      );
    } on FormatException {
      throw const WrongPairingCodeException();
    }
    if (secret == null) throw const WrongPairingCodeException();
    await _request(_message((m) => m.message(_secret, ProtoWriter()..bytes(1, secret!))));
    close();
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _socket.destroy();
  }

  Future<void> _request(Uint8List message) async {
    if (_failure case final failure?) throw failure;
    final pending = _pending = Completer<void>();
    _send(message);
    try {
      await pending.future.timeout(_timeout);
    } on TimeoutException {
      _fail(const PairingException("The TV didn't respond."));
      throw _failure!;
    } finally {
      if (identical(_pending, pending)) _pending = null;
    }
  }

  void _onData(Uint8List data) {
    try {
      for (final raw in _decoder.add(data)) {
        _handle(ProtoMessage.parse(raw));
      }
    } on FormatException catch (e) {
      _fail(PairingException('Unexpected data from the TV: ${e.message}'));
    }
  }

  void _handle(ProtoMessage message) {
    final status = message.integer(_status);
    if (status != _statusOk) {
      _fail(
        PairingException(switch (status) {
          402 => 'The TV rejected the code. Start pairing again.',
          401 => 'The TV rejected the pairing settings.',
          _ => 'The TV reported a pairing error ($status).',
        }),
      );
      return;
    }

    if (message.has(_pairingRequestAck)) {
      _send(
        _message((m) {
          m.message(
            _options,
            ProtoWriter()
              ..message(1, _hexEncoding()) // input_encodings
              ..varint(3, _roleInput),
          ); // preferred_role
        }),
      );
    } else if (message.has(_options)) {
      _send(
        _message((m) {
          m.message(
            _configuration,
            ProtoWriter()
              ..message(1, _hexEncoding()) // encoding
              ..varint(2, _roleInput),
          ); // client_role
        }),
      );
    } else if (message.has(_configurationAck) || message.has(_secretAck)) {
      final pending = _pending;
      if (pending != null && !pending.isCompleted) pending.complete();
    } else {
      _fail(const PairingException('Unexpected pairing message from the TV.'));
    }
  }

  void _send(Uint8List message) {
    if (!_closed) _socket.add(frame(message));
  }

  void _fail(PairingException failure) {
    _failure ??= failure;
    final pending = _pending;
    if (pending != null && !pending.isCompleted) pending.completeError(_failure!);
    close();
  }

  static ProtoWriter _hexEncoding() => ProtoWriter()
    ..varint(1, _encodingHexadecimal) // type
    ..varint(2, _codeLength); // symbol_length

  static Uint8List _message(void Function(ProtoWriter message) build) {
    final message = ProtoWriter()
      ..varint(_protocolVersion, 2)
      ..varint(_status, _statusOk);
    build(message);
    return message.toBytes();
  }
}
