// Writes server/test/fixtures/dart-device-cert.json from fixed seeds so the server
// test can check that a Dart-made device certificate passes verifyDeviceCert.
// Run from app/: dart run tool/gen_cert_fixture.dart
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:famchat/spikes/crypto_spike.dart';

Future<void> main() async {
  final identity = await Ed25519().newKeyPairFromSeed(List.filled(32, 0x01));
  final enc = await X25519().newKeyPairFromSeed(List.filled(32, 0x02));
  final sign = await Ed25519().newKeyPairFromSeed(List.filled(32, 0x03));
  final cert = await makeDeviceCert(identity: identity, enc: enc, sign: sign);
  final out = File('../server/test/fixtures/dart-device-cert.json');
  await out.create(recursive: true);
  await out.writeAsString('${const JsonEncoder.withIndent('  ').convert({
        'identityPub': cert.identityPub,
        'encPub': cert.encPub,
        'signPub': cert.signPub,
        'certSig': cert.certSig,
      })}\n');
  stdout.writeln('wrote ${out.path}');
}
