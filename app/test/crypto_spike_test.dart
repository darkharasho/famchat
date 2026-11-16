import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:famchat/spikes/crypto_spike.dart';
import 'package:flutter_test/flutter_test.dart';

List<int> seed(int b) => List.filled(32, b);

void main() {
  late SimpleKeyPair identity, enc, sign;

  setUpAll(() async {
    identity = await Ed25519().newKeyPairFromSeed(seed(1));
    enc = await X25519().newKeyPairFromSeed(seed(2));
    sign = await Ed25519().newKeyPairFromSeed(seed(3));
  });

  test('cert message layout', () async {
    final encPub = (await enc.extractPublicKey()).bytes;
    final signPub = (await sign.extractPublicKey()).bytes;
    final msg = await deviceCertMessage(encPub, signPub);
    expect(msg.length, 86);
    expect(msg.sublist(0, 22), utf8.encode('famchat-device-cert-v1'));
    expect(msg.sublist(22, 54), encPub);
    expect(msg.sublist(54), signPub);
  });

  test('cert verifies', () async {
    final cert = await makeDeviceCert(identity: identity, enc: enc, sign: sign);
    final msg = await deviceCertMessage(b64urlDecode(cert.encPub), b64urlDecode(cert.signPub));
    final pub = SimplePublicKey(b64urlDecode(cert.identityPub), type: KeyPairType.ed25519);
    final sig = b64urlDecode(cert.certSig);
    expect(sig.length, 64);
    expect(await Ed25519().verify(msg, signature: Signature(sig, publicKey: pub)), isTrue);
    final bad = Uint8List.fromList(sig)..[0] ^= 1;
    expect(await Ed25519().verify(msg, signature: Signature(bad, publicKey: pub)), isFalse);
  });

  test('b64url has no padding', () {
    final s = b64url([1, 2]);
    expect(s, isNot(contains('=')));
    expect(b64urlDecode(s), [1, 2]);
    expect(b64urlDecode(b64url([0xfb, 0xff])), [0xfb, 0xff]);
  });

  test('sealed box round-trip', () async {
    final pub = (await enc.extractPublicKey()).bytes;
    final sealed = await sealBox(pub, utf8.encode('chat key'));
    expect(sealed.length, 32 + 24 + 8 + 16);
    expect(utf8.decode(await openBox(enc, sealed)), 'chat key');
  });

  test('sealed box tamper', () async {
    final pub = (await enc.extractPublicKey()).bytes;
    final sealed = await sealBox(pub, utf8.encode('chat key'));
    for (final i in [0, 40, 60, sealed.length - 1]) {
      final t = Uint8List.fromList(sealed)..[i] ^= 1;
      await expectLater(openBox(enc, t), throwsA(anything), reason: 'byte $i');
    }
  });

  group('envelope', () {
    final chatKey = List.generate(32, (i) => i);
    late List<int> signPub;
    setUpAll(() async => signPub = (await sign.extractPublicKey()).bytes);

    Future<Map<String, Object>> enc1() => encryptEnvelope(
          chatKey: chatKey, epoch: 3, chatId: 'C1', messageId: 'M1',
          senderDeviceId: 'D1', signKey: sign, plaintext: utf8.encode('{"kind":"text"}'));

    test('envelope round-trip', () async {
      final env = await enc1();
      expect(env['v'], 1);
      expect(env['epoch'], 3);
      expect(env.keys, containsAll(['nonce', 'ct', 'sig']));
      final pt = await decryptEnvelope(chatKey: chatKey, chatId: 'C1', messageId: 'M1',
          senderDeviceId: 'D1', senderSignPub: signPub, envelope: env);
      expect(utf8.decode(pt), '{"kind":"text"}');
    });

    test('envelope wrong aad fails', () async {
      final env = await enc1();
      await expectLater(
          decryptEnvelope(chatKey: chatKey, chatId: 'C1', messageId: 'M2',
              senderDeviceId: 'D1', senderSignPub: signPub, envelope: env),
          throwsA(anything));
    });

    test('envelope bad sig fails', () async {
      final env = Map<String, Object>.of(await enc1());
      final sig = b64urlDecode(env['sig'] as String)..[5] ^= 1;
      env['sig'] = b64url(sig);
      await expectLater(
          decryptEnvelope(chatKey: chatKey, chatId: 'C1', messageId: 'M1',
              senderDeviceId: 'D1', senderSignPub: signPub, envelope: env),
          throwsA(anything));
    });

    test('envelope throughput', () async {
      final body = List.filled(1024, 7);
      final sw = Stopwatch()..start();
      for (var i = 0; i < 100; i++) {
        final env = await encryptEnvelope(chatKey: chatKey, epoch: 1, chatId: 'C', messageId: 'M$i',
            senderDeviceId: 'D', signKey: sign, plaintext: body);
        await decryptEnvelope(chatKey: chatKey, chatId: 'C', messageId: 'M$i',
            senderDeviceId: 'D', senderSignPub: signPub, envelope: env);
      }
      sw.stop();
      // ignore: avoid_print
      print('SPIKE crypto-throughput ${sw.elapsedMilliseconds}ms/100');
      expect(sw.elapsed, lessThan(const Duration(seconds: 2)));
    });
  });

  // The server test verifies this committed fixture; if the Dart cert format changes,
  // this fails until `dart run tool/gen_cert_fixture.dart` regenerates it.
  test('cert matches the server fixture', () async {
    final cert = await makeDeviceCert(identity: identity, enc: enc, sign: sign);
    final fixture = jsonDecode(
        File('../server/test/fixtures/dart-device-cert.json').readAsStringSync()) as Map<String, dynamic>;
    expect(fixture, {
      'identityPub': cert.identityPub,
      'encPub': cert.encPub,
      'signPub': cert.signPub,
      'certSig': cert.certSig,
    });
  });
}
