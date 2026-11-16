import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:famchat/crypto/encoding.dart';
import 'package:famchat/crypto/keys.dart';
import 'package:famchat/crypto/pairing.dart';
import 'package:famchat/crypto/sealed_box.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List bytes(int n, int seed) => Uint8List.fromList(List.generate(n, (i) => (i * 7 + seed) & 0xff));

void main() {
  test('no domain string is a prefix of another', () {
    expect(famchatDomains.toSet().length, famchatDomains.length);
    for (final a in famchatDomains) {
      for (final b in famchatDomains) {
        if (a != b) expect(b.startsWith(a), isFalse, reason: '$a is a prefix of $b');
      }
    }
    expect(famchatDomains, containsAll(['famchat-pair-keys-v1', 'famchat-pair-bundle-v1', 'famchat-wrap-v1', 'famchat-media-v1']));
  });

  group('keys MAC', () {
    final eph = bytes(32, 1), enc = bytes(32, 2), sign = bytes(32, 3);
    Future<Uint8List> mac({String secret = 'ABCDEFGH1234', List<int>? e, String name = 'Laptop', String platform = 'linux'}) =>
        pairKeysMac(secret: secret, ephPub: e ?? eph, encPub: enc, signPub: sign, deviceName: name, platform: platform);

    test('is 32 bytes, deterministic, and checks', () async {
      final m = await mac();
      expect(m, hasLength(32));
      expect(await mac(), m);
      expect(
        await checkPairKeysMac(
            secret: 'ABCDEFGH1234', ephPub: eph, encPub: enc, signPub: sign, deviceName: 'Laptop', platform: 'linux', mac: m),
        isTrue,
      );
    });

    test('is HMAC-SHA256 over the domain string and fields', () async {
      final msg = (ByteWriter('famchat-pair-keys-v1')
            ..bytes(eph)
            ..bytes(enc)
            ..bytes(sign)
            ..str('Laptop')
            ..str('linux'))
          .finish();
      final want = await Hmac.sha256().calculateMac(msg, secretKey: SecretKey(utf8.encode('ABCDEFGH1234')));
      expect(await mac(), want.bytes);
    });

    test('fails for other keys, name, platform or secret', () async {
      final m = await mac();
      Future<bool> check({String secret = 'ABCDEFGH1234', List<int>? e, List<int>? en, String name = 'Laptop', String platform = 'linux'}) =>
          checkPairKeysMac(
              secret: secret, ephPub: e ?? eph, encPub: en ?? enc, signPub: sign, deviceName: name, platform: platform, mac: m);
      expect(await check(secret: 'ABCDEFGH1235'), isFalse);
      expect(await check(e: bytes(32, 9)), isFalse);
      expect(await check(en: bytes(32, 9)), isFalse);
      expect(await check(name: 'Laptop2'), isFalse);
      expect(await check(platform: 'web'), isFalse);
      expect(
        await checkPairKeysMac(
            secret: 'ABCDEFGH1234', ephPub: eph, encPub: enc, signPub: sign, deviceName: 'Laptop', platform: 'linux', mac: m.sublist(1)),
        isFalse,
      );
    });
  });

  group('bundle box', () {
    test('bundle opens with the right eph and secret', () async {
      final eph = await X25519().newKeyPair();
      final pub = await publicKeyOf(eph);
      final sealed = await sealPairBundle(recipientEphPub: pub, secret: 'S3CRETS3CRET', plaintext: utf8.encode('hello'));
      expect(sealed.length, 32 + 24 + 5 + 16);
      expect(utf8.decode(await openPairBundle(eph: eph, secret: 'S3CRETS3CRET', sealed: sealed)), 'hello');
    });

    test('bundle from someone without the secret does not open', () async {
      final eph = await X25519().newKeyPair();
      final pub = await publicKeyOf(eph);
      final forged = await sealPairBundle(recipientEphPub: pub, secret: 'WRONGSECRET0', plaintext: utf8.encode('{}'));
      await expectLater(openPairBundle(eph: eph, secret: 'S3CRETS3CRET', sealed: forged), throwsA(isA<CryptoFailure>()));
      // A plain sealed box to the same key (no secret) doesn't open either.
      final plain = await sealBox(pub, utf8.encode('{}'));
      await expectLater(openPairBundle(eph: eph, secret: 'S3CRETS3CRET', sealed: plain), throwsA(isA<CryptoFailure>()));
    });

    test('tampered or truncated bundle fails', () async {
      final eph = await X25519().newKeyPair();
      final sealed = await sealPairBundle(recipientEphPub: await publicKeyOf(eph), secret: 'S', plaintext: [1, 2, 3]);
      final t = Uint8List.fromList(sealed)..[60] ^= 1;
      await expectLater(openPairBundle(eph: eph, secret: 'S', sealed: t), throwsA(isA<CryptoFailure>()));
      await expectLater(openPairBundle(eph: eph, secret: 'S', sealed: sealed.sublist(0, 40)), throwsA(isA<CryptoFailure>()));
    });

    test('plain sealed boxes are unchanged', () async {
      // The bound variant must not change sealBox's bytes (test vectors cover the exact format).
      final eph = await X25519().newKeyPair();
      final sealed = await sealBox(await publicKeyOf(eph), [9, 9]);
      expect(await openBox(eph, sealed), [9, 9]);
    });
  });
}
