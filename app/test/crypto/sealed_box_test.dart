import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:famchat/crypto/encoding.dart';
import 'package:famchat/crypto/keys.dart';
import 'package:famchat/crypto/sealed_box.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List hex(String s) =>
    Uint8List.fromList([for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)]);

void main() {
  late DeviceKeys me;
  late Uint8List myPub;

  setUpAll(() async {
    me = await DeviceKeys.generate();
    myPub = await me.encPub();
  });

  test('seal then open round-trips', () async {
    final sealed = await sealBox(myPub, utf8.encode('chat key'));
    expect(sealed.length, 32 + 24 + 8 + 16);
    expect(utf8.decode(await openBox(me.enc, sealed)), 'chat key');
  });

  test('every flipped byte fails with CryptoFailure', () async {
    final sealed = await sealBox(myPub, utf8.encode('chat key'));
    for (var i = 0; i < sealed.length; i++) {
      final t = Uint8List.fromList(sealed)..[i] ^= 1;
      await expectLater(openBox(me.enc, t), throwsA(isA<CryptoFailure>()), reason: 'byte $i');
    }
  });

  test('short input fails with CryptoFailure', () async {
    await expectLater(openBox(me.enc, Uint8List(71)), throwsA(isA<CryptoFailure>()));
  });

  test('wrong recipient fails', () async {
    final sealed = await sealBox(myPub, utf8.encode('chat key'));
    final other = await DeviceKeys.generate();
    await expectLater(openBox(other.enc, sealed), throwsA(isA<CryptoFailure>()));
  });

  test('low-order recipient key is refused', () async {
    for (final bad in [
      Uint8List(32),
      hex('e0eb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b800'),
    ]) {
      await expectLater(sealBox(bad, [1]), throwsA(isA<CryptoFailure>()));
    }
  });

  test('low-order ephemeral key in a box is refused on open', () async {
    final sealed = Uint8List(32 + 24 + 1 + 16); // all-zero ephPub
    await expectLater(openBox(me.enc, sealed), throwsA(isA<CryptoFailure>()));
  });

  test('fixed ephemeral and nonce give fixed output', () async {
    final eph = await X25519().newKeyPairFromSeed(List.filled(32, 4));
    final nonce = List.filled(24, 5);
    final a = await sealBox(myPub, [1, 2, 3], ephemeral: eph, nonce: nonce);
    final b = await sealBox(myPub, [1, 2, 3], ephemeral: eph, nonce: nonce);
    expect(a, b);
    expect(a.sublist(32, 56), nonce);
  });

  test('wrong-length recipient key is refused', () async {
    await expectLater(sealBox(Uint8List(31), [1]), throwsA(isA<CryptoFailure>()));
  });
}
