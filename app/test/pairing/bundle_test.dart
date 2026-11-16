import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:famchat/chat/directory.dart';
import 'package:famchat/crypto/device_cert.dart';
import 'package:famchat/crypto/encoding.dart';
import 'package:famchat/crypto/keys.dart';
import 'package:famchat/crypto/pairing.dart';
import 'package:famchat/pairing/bundle.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_chat_backend.dart';

void main() {
  late FakeChatBackend b;
  late TestDevice phone, bob;

  setUp(() async {
    b = FakeChatBackend();
    phone = await b.addUser('Alice');
    bob = await b.addUser('Bob');
  });
  tearDown(() async {
    await phone.dispose();
    await bob.dispose();
  });

  PairBundle sample() => PairBundle(
        userId: 'U1',
        deviceId: 'D1',
        identitySeed: Uint8List(32)..[0] = 1,
        certSig: Uint8List(64)..[1] = 2,
        keys: [HandoverKey(chatId: 'C1', epoch: 2, key: Uint8List(32)..[2] = 3)],
        trust: [const TrustedIdentity(userId: 'U2', trustedIdentityPub: 'pubA', known: ['pubA', 'pubOld'])],
      );

  test('bundle JSON round-trips', () {
    final back = PairBundle.decode(sample().encode());
    expect(back.userId, 'U1');
    expect(back.deviceId, 'D1');
    expect(back.identitySeed, sample().identitySeed);
    expect(back.certSig, sample().certSig);
    expect(back.keys.single.chatId, 'C1');
    expect(back.keys.single.epoch, 2);
    expect(back.keys.single.key, sample().keys.single.key);
    expect(back.trust.single.known, ['pubA', 'pubOld']);
    expect(jsonDecode(utf8.decode(sample().encode()))['v'], 1);
  });

  test('bad bundle json -> CryptoFailure', () {
    for (final s in ['', '[]', '{"v":2}', '{"v":1,"userId":"U"}', '{"v":1,"userId":"U","deviceId":"D","identitySeed":"AA","certSig":"AA","keys":[],"trust":[]}']) {
      expect(() => PairBundle.decode(utf8.encode(s)), throwsA(isA<CryptoFailure>()), reason: s);
    }
  });

  test('handover carries every key and trust; install restores them and the directory keeps the handed trust',
      () async {
    await phone.db.bindDevice(phone.deviceId);
    await Directory(phone.db, phone.api, phone.me).refresh();
    await phone.db.putKey('C1', 1, Uint8List(32)..[0] = 9);
    await phone.db.putKey('C1', 2, Uint8List(32)..[0] = 8);
    await phone.db.putKey('C2', 1, Uint8List(32)..[0] = 7);

    final newKeys = await DeviceKeys.generate();
    final bundle = await buildHandover(
      db: phone.db,
      userId: phone.userId,
      deviceId: 'NEWDEVICE',
      identity: b.identityOf(phone.userId),
      encPub: await newKeys.encPub(),
      signPub: await newKeys.signPub(),
    );
    expect(bundle.keys.map((k) => '${k.chatId}/${k.epoch}').toSet(), {'C1/1', 'C1/2', 'C2/1'});
    expect(bundle.trust.map((t) => t.userId), [bob.userId]); // not Alice herself
    expect(bundle.identitySeed, await seedOf(b.identityOf(phone.userId)));

    final verified = await verifyHandover(
      bundle,
      userId: phone.userId,
      deviceId: 'NEWDEVICE',
      encPub: await newKeys.encPub(),
      signPub: await newKeys.signPub(),
    );
    expect(verified.identityPub, await publicKeyOf(b.identityOf(phone.userId)));

    // The new device: Bob's identity changes on the server before it ever saw him.
    final laptop = await b.addDevice(phone.userId);
    await installHandover(laptop.db, bundle);
    expect(await laptop.db.key('C1', 2), bundle.keys.firstWhere((k) => k.chatId == 'C1' && k.epoch == 2).key);
    await b.resetUser(bob.userId);
    await Directory(laptop.db, laptop.api, laptop.me).refresh();
    expect(await Directory(laptop.db, laptop.api, laptop.me).identityChanged(bob.userId), isTrue);
    await laptop.dispose();
  });

  test('install binds the database to the new device first', () async {
    await phone.db.bindDevice('OLD');
    await phone.db.putKey('X', 1, Uint8List(32));
    await installHandover(phone.db, sample());
    expect(await phone.db.key('X', 1), isNull);
    expect(await phone.db.key('C1', 2), isNotNull);
    expect((await phone.db.userById('U2'))!.trustedIdentityPub, 'pubA');
  });

  test('a bundle whose cert is not for my keys or my ids is rejected', () async {
    final identity = await newIdentityKey();
    final mine = await DeviceKeys.generate(), other = await DeviceKeys.generate();
    final good = PairBundle(
      userId: 'U1',
      deviceId: 'D1',
      identitySeed: await seedOf(identity),
      certSig: await signCertFor(identity: identity, encPub: await mine.encPub(), signPub: await mine.signPub()),
      keys: const [],
      trust: const [],
    );
    Future<void> verify(PairBundle x, {String userId = 'U1', String deviceId = 'D1', DeviceKeys? keys}) async =>
        verifyHandover(x,
            userId: userId,
            deviceId: deviceId,
            encPub: await (keys ?? mine).encPub(),
            signPub: await (keys ?? mine).signPub());
    await verify(good);
    await expectLater(verify(good, keys: other), throwsA(isA<CryptoFailure>()));
    await expectLater(verify(good, userId: 'U2'), throwsA(isA<CryptoFailure>()));
    await expectLater(verify(good, deviceId: 'D2'), throwsA(isA<CryptoFailure>()));
  });

  test('sealed handover opens only with the secret', () async {
    final eph = await X25519().newKeyPair();
    final sealed = await sealPairBundle(recipientEphPub: await publicKeyOf(eph), secret: 'ABCDEFGHJKMN', plaintext: sample().encode());
    final back = PairBundle.decode(await openPairBundle(eph: eph, secret: 'ABCDEFGHJKMN', sealed: sealed));
    expect(back.userId, 'U1');
  });
}
