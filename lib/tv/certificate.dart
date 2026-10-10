import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:basic_utils/basic_utils.dart';
import 'package:crypto/crypto.dart' show sha256;

/// The certificate and private key this app presents to the TV.
///
/// The TV remembers the certificate once paired, so the same identity must be
/// reused for every connection. Losing it means pairing again.
class ClientIdentity {
  const ClientIdentity({required this.certificatePem, required this.privateKeyPem});

  final String certificatePem;
  final String privateKeyPem;

  /// Generates a self-signed RSA certificate, like the official remote does.
  ///
  /// RSA key generation is CPU-heavy (seconds on a phone), so call this
  /// through `Isolate.run`.
  static ClientIdentity generate({String commonName = 'atvremote', int keySize = 2048}) {
    final keyPair = CryptoUtils.generateRSAKeyPair(keySize: keySize);
    final privateKey = keyPair.privateKey as RSAPrivateKey;
    final publicKey = keyPair.publicKey as RSAPublicKey;
    final csr = X509Utils.generateRsaCsrPem({'CN': commonName}, privateKey, publicKey);
    final serial = Random.secure().nextInt(1 << 31) + 1;
    final certificate = X509Utils.generateSelfSignedCertificate(
      privateKey,
      csr,
      365 * 10,
      serialNumber: '$serial',
      notBefore: DateTime.now().subtract(const Duration(days: 1)),
    );
    return ClientIdentity(
      certificatePem: certificate,
      privateKeyPem: CryptoUtils.encodeRSAPrivateKeyToPem(privateKey),
    );
  }

  SecurityContext createSecurityContext() => SecurityContext(withTrustedRoots: false)
    ..useCertificateChainBytes(utf8.encode(certificatePem))
    ..usePrivateKeyBytes(utf8.encode(privateKeyPem));

  RsaPublicNumbers get publicNumbers =>
      RsaPublicNumbers.fromCertificateDer(CryptoUtils.getBytesFromPEMString(certificatePem));
}

/// The modulus and exponent of a certificate's RSA public key.
class RsaPublicNumbers {
  const RsaPublicNumbers(this.modulus, this.exponent);

  final BigInt modulus;
  final BigInt exponent;

  /// Reads the RSA public key out of an X.509 certificate in DER form.
  factory RsaPublicNumbers.fromCertificateDer(Uint8List der) {
    final certificate = _Der(der).enter(_sequence);
    final tbs = certificate.enter(_sequence);
    var element = tbs.next();
    if (element.tag == _explicitVersion) element = tbs.next(); // now the serial number
    tbs
      ..next() // signature algorithm
      ..next() // issuer
      ..next() // validity
      ..next(); // subject
    final keyInfo = tbs.enter(_sequence);
    keyInfo.next(); // algorithm
    final bitString = keyInfo.next();
    if (bitString.tag != _bitString || der[bitString.start] != 0) {
      throw const FormatException('Certificate does not contain an RSA public key');
    }
    final rsaKey = _Der(der, bitString.start + 1, bitString.end).enter(_sequence);
    final modulus = rsaKey.next();
    final exponent = rsaKey.next();
    if (modulus.tag != _integer || exponent.tag != _integer) {
      throw const FormatException('Certificate does not contain an RSA public key');
    }
    return RsaPublicNumbers(_toBigInt(der, modulus), _toBigInt(der, exponent));
  }

  static const _integer = 0x02;
  static const _bitString = 0x03;
  static const _sequence = 0x30;
  static const _explicitVersion = 0xA0;

  static BigInt _toBigInt(Uint8List der, _DerElement element) {
    var value = BigInt.zero;
    for (var i = element.start; i < element.end; i++) {
      value = (value << 8) | BigInt.from(der[i]);
    }
    return value;
  }
}

/// Computes the secret sent to the TV to complete pairing.
///
/// [code] is the 6 hex digit code shown on the TV. Its first byte is a check
/// byte that must equal the first byte of the hash; the remaining two bytes
/// are a nonce that goes into the hash. Returns null when the check byte
/// doesn't match, meaning the code was mistyped.
Uint8List? computePairingSecret({
  required RsaPublicNumbers client,
  required RsaPublicNumbers server,
  required String code,
}) {
  if (!RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(code)) {
    throw const FormatException('Pairing code must be 6 hex characters');
  }
  final codeBytes = _hexToBytes(code);
  final digest = sha256.convert([
    ..._unsignedBytes(client.modulus),
    ..._unsignedBytes(client.exponent),
    ..._unsignedBytes(server.modulus),
    ..._unsignedBytes(server.exponent),
    ...codeBytes.sublist(1),
  ]);
  final secret = Uint8List.fromList(digest.bytes);
  return secret[0] == codeBytes[0] ? secret : null;
}

/// Big-endian bytes of [value] with no sign byte (e.g. 65537 -> 01 00 01).
Uint8List _unsignedBytes(BigInt value) {
  var hex = value.toRadixString(16);
  if (hex.length.isOdd) hex = '0$hex';
  return _hexToBytes(hex);
}

Uint8List _hexToBytes(String hex) => Uint8List.fromList([
  for (var i = 0; i < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16),
]);

typedef _DerElement = ({int tag, int start, int end});

/// Just enough of a DER reader to walk to a certificate's public key.
class _Der {
  _Der(this._bytes, [this._position = 0, int? end]) : _end = end ?? _bytes.length;

  final Uint8List _bytes;
  int _position;
  final int _end;

  /// Reads the next element and moves past it.
  _DerElement next() {
    if (_position + 2 > _end) throw const FormatException('Unexpected end of DER data');
    final tag = _bytes[_position++];
    var length = _bytes[_position++];
    if (length & 0x80 != 0) {
      final lengthBytes = length & 0x7F;
      if (lengthBytes > 4 || _position + lengthBytes > _end) {
        throw const FormatException('Invalid DER length');
      }
      length = 0;
      for (var i = 0; i < lengthBytes; i++) {
        length = (length << 8) | _bytes[_position++];
      }
    }
    final start = _position;
    _position += length;
    if (_position > _end) throw const FormatException('DER element extends past its parent');
    return (tag: tag, start: start, end: _position);
  }

  /// Reads the next element, which must have [tag], and returns a reader over its contents.
  _Der enter(int tag) {
    final element = next();
    if (element.tag != tag) {
      throw FormatException('Expected DER tag $tag, found ${element.tag}');
    }
    return _Der(_bytes, element.start, element.end);
  }
}
