// Writes server/test/fixtures/dart-device-cert.json from fixed seeds so the server
// test can check that a Dart-made device certificate passes verifyDeviceCert.
// Run from app/: dart run tool/gen_cert_fixture.dart
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:famchat/crypto/device_cert.dart';
import 'package:famchat/crypto/keys.dart';

Future<void> main() async {
  final identity = await newIdentityKey(seed: List.filled(32, 0x01));
  final device = DeviceKeys(
    await X25519().newKeyPairFromSeed(List.filled(32, 0x02)),
    await Ed25519().newKeyPairFromSeed(List.filled(32, 0x03)),
  );
  final cert = await signDeviceCert(identity: identity, device: device);
  final out = File('../server/test/fixtures/dart-device-cert.json');
  await out.create(recursive: true);
  await out.writeAsString('${const JsonEncoder.withIndent('  ').convert(cert.toJson())}\n');
  stdout.writeln('wrote ${out.path}');
}
