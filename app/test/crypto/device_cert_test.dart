import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:famchat/crypto/device_cert.dart';
import 'package:famchat/crypto/encoding.dart';
import 'package:famchat/crypto/keys.dart';
import 'package:flutter_test/flutter_test.dart';

List<int> seed(int b) => List.filled(32, b);

void main() {
  late SimpleKeyPair identity;
  late DeviceKeys device;

  setUpAll(() async {
    identity = await newIdentityKey(seed: seed(1));
    device = DeviceKeys(await X25519().newKeyPairFromSeed(seed(2)), await Ed25519().newKeyPairFromSeed(seed(3)));
  });

  test('cert message layout', () async {
    final encPub = await device.encPub(), signPub = await device.signPub();
    final msg = deviceCertMessage(encPub, signPub);
    expect(msg.length, 86);
    expect(msg.sublist(0, 22), utf8.encode('famchat-device-cert-v1'));
    expect(msg.sublist(22, 54), encPub);
    expect(msg.sublist(54), signPub);
  });

  test('cert verifies', () async {
    final cert = await signDeviceCert(identity: identity, device: device);
    expect(cert.certSig.length, 64);
    expect(await verifyDeviceCert(cert), isTrue);
    expect(await verifyDeviceCert(DeviceCert.fromJson(cert.toJson())), isTrue);
  });

  test('flipped signature fails', () async {
    final cert = await signDeviceCert(identity: identity, device: device);
    final sig = Uint8List.fromList(cert.certSig)..[0] ^= 1;
    expect(await verifyDeviceCert(DeviceCert(cert.identityPub, cert.encPub, cert.signPub, sig)), isFalse);
  });

  test('cert from another identity fails', () async {
    final cert = await signDeviceCert(identity: identity, device: device);
    final other = await publicKeyOf(await newIdentityKey());
    expect(await verifyDeviceCert(DeviceCert(other, cert.encPub, cert.signPub, cert.certSig)), isFalse);
  });

  test('swapped enc and sign keys fail', () async {
    final cert = await signDeviceCert(identity: identity, device: device);
    expect(await verifyDeviceCert(DeviceCert(cert.identityPub, cert.signPub, cert.encPub, cert.certSig)), isFalse);
  });

  test('wrong-length fields fail fromJson with CryptoFailure', () async {
    final good = (await signDeviceCert(identity: identity, device: device)).toJson();
    for (final field in ['identityPub', 'encPub', 'signPub', 'certSig']) {
      final short = Map<String, Object?>.of(good)..[field] = b64url([1, 2, 3]);
      expect(() => DeviceCert.fromJson(short), throwsA(isA<CryptoFailure>()), reason: field);
      final missing = Map<String, Object?>.of(good)..remove(field);
      expect(() => DeviceCert.fromJson(missing), throwsA(isA<CryptoFailure>()), reason: field);
      final mistyped = Map<String, Object?>.of(good)..[field] = 7;
      expect(() => DeviceCert.fromJson(mistyped), throwsA(isA<CryptoFailure>()), reason: field);
    }
  });

  // The server test verifies this committed fixture; if the Dart cert format changes,
  // this fails until `dart run tool/gen_cert_fixture.dart` regenerates it.
  test('cert matches the server fixture', () async {
    final cert = await signDeviceCert(identity: identity, device: device);
    final fixture = jsonDecode(File('../server/test/fixtures/dart-device-cert.json').readAsStringSync());
    expect(fixture, cert.toJson());
  }, testOn: 'vm'); // reads a file, so it can't run in the browser
}
