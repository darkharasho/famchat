import 'package:famchat/crypto/encoding.dart';
import 'package:famchat/crypto/keys.dart';
import 'package:famchat/crypto/sealed_box.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('device keys round-trip through storage', () async {
    final keys = await DeviceKeys.generate();
    final stored = await keys.toStorage();
    expect(stored.keys, containsAll(['encSeed', 'signSeed']));
    final restored = await DeviceKeys.fromStorage(stored);
    expect(await restored.encPub(), await keys.encPub());
    expect(await restored.signPub(), await keys.signPub());
    final sealed = await sealBox(await keys.encPub(), [7, 7, 7]);
    expect(await openBox(restored.enc, sealed), [7, 7, 7]);
  });

  test('fromStorage with a bad seed throws CryptoFailure', () async {
    await expectLater(DeviceKeys.fromStorage({'encSeed': 'AA', 'signSeed': 'AA'}),
        throwsA(isA<CryptoFailure>()));
    await expectLater(DeviceKeys.fromStorage({}), throwsA(isA<CryptoFailure>()));
  });

  test('seeded identity key is deterministic', () async {
    final k = await newIdentityKey(seed: List.filled(32, 1));
    expect(b64url(await publicKeyOf(k)), 'iojj3XQJ8ZX9UtstPLpdcspnCb8dlBIb83SIAbQPb1w');
    expect(await seedOf(k), List.filled(32, 1));
  });

  test('newChatKey is 32 random bytes', () {
    final a = newChatKey(), b = newChatKey();
    expect(a.length, 32);
    expect(a, isNot(b));
  });
}
