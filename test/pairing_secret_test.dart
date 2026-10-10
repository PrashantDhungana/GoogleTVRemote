import 'dart:io';

import 'package:basic_utils/basic_utils.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tv_remote/tv/certificate.dart';

RsaPublicNumbers _numbers(String fixture) => RsaPublicNumbers.fromCertificateDer(
  CryptoUtils.getBytesFromPEMString(File('test/fixtures/$fixture').readAsStringSync()),
);

String _hex(List<int> bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  // Expected values were computed independently with Node's crypto module,
  // following androidtvremote2's pairing.py.
  const expectedSecret = 'f11566286b5db5d3ce5735aad27c32271b329d26583564ce0d62ed608addafe2';

  final client = _numbers('client_certificate.pem');
  final tv = _numbers('tv_certificate.pem');

  test('reads the RSA public key from a certificate', () {
    expect(client.exponent, BigInt.from(65537));
    expect(client.modulus.bitLength, 2048);
    expect(tv.modulus, isNot(client.modulus));
  });

  test('computes the secret for the code shown on the TV', () {
    final secret = computePairingSecret(client: client, server: tv, code: 'F1BEEF');
    expect(_hex(secret!), expectedSecret);
  });

  test('accepts lowercase codes', () {
    final secret = computePairingSecret(client: client, server: tv, code: 'f1beef');
    expect(_hex(secret!), expectedSecret);
  });

  test('rejects a code whose check byte does not match', () {
    expect(computePairingSecret(client: client, server: tv, code: 'F2BEEF'), isNull);
  });

  test('rejects malformed codes', () {
    expect(
      () => computePairingSecret(client: client, server: tv, code: 'F1BEE'),
      throwsFormatException,
    );
    expect(
      () => computePairingSecret(client: client, server: tv, code: 'F1BEEG'),
      throwsFormatException,
    );
  });
}
