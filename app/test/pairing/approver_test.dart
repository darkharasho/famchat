import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:famchat/chat/db/chat_db.dart';
import 'package:famchat/crypto/device_cert.dart';
import 'package:famchat/crypto/encoding.dart';
import 'package:famchat/crypto/keys.dart';
import 'package:famchat/crypto/pairing.dart';
import 'package:famchat/pairing/approver.dart';
import 'package:famchat/pairing/bundle.dart';
import 'package:famchat/pairing/pair_code.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_chat_backend.dart';
import '../support/fake_server.dart';
import '../support/pairing_helpers.dart';

void main() {
  late FakeServer server;
  late SignedInClient alice;
  late ChatDb db;
  late DeviceApprover approver;

  setUp(() async {
    quietDrift();
    server = FakeServer();
    alice = await signedInClient(server);
    db = ChatDb(NativeDatabase.memory());
    await db.bindDevice(alice.session.deviceId);
    await db.putKey('C1', 1, Uint8List(32)..[0] = 1);
    await db.putKey('C1', 2, Uint8List(32)..[0] = 2);
    approver = DeviceApprover(api: alice.api, db: db, session: alice.session);
  });
  tearDown(() => db.close());

  Future<PairBundle> openSent(StartedPairing n) async {
    final x = server.pairSessionByCode(n.code.lookup)!;
    expect(x.approvedAt, isNotNull);
    return PairBundle.decode(await openPairBundle(eph: n.eph, secret: n.code.secret, sealed: b64urlDecode(x.bundle!)));
  }

  test('typed code and QR both approve', () async {
    for (final viaQr in [false, true]) {
      final n = await startPairing(server, deviceName: viaQr ? 'Tablet' : 'Laptop', platform: viaQr ? 'android' : 'linux');
      final pending = await approver.lookup(viaQr ? n.qr : n.code.display.toLowerCase());
      expect(pending.deviceName, viaQr ? 'Tablet' : 'Laptop');
      expect(pending.platform, viaQr ? 'android' : 'linux');
      await approver.approve(pending);

      final bundle = await openSent(n);
      expect(bundle.userId, alice.userId);
      expect(bundle.deviceId, n.start.deviceId);
      expect(bundle.identitySeed, await seedOf(alice.identity));
      expect(bundle.keys.map((k) => k.epoch).toSet(), {1, 2});
      final cert = DeviceCert(await publicKeyOf(alice.identity), await n.keys.encPub(), await n.keys.signPub(), bundle.certSig);
      expect(await verifyDeviceCert(cert), isTrue);
    }
  });

  test('approver rejects swapped keys', () async {
    final n = await startPairing(server);
    final evil = await DeviceKeys.generate();
    server.tamperNextLookup = {'encPub': b64url(await evil.encPub()), 'signPub': b64url(await evil.signPub())};
    await expectLater(
      approver.lookup(n.code.display),
      throwsA(isA<PairingException>().having((e) => e.kind, 'kind', PairingError.mismatch)),
    );
    expect(server.pairSessionByCode(n.code.lookup)!.approvedAt, isNull);
  });

  test('a relabelled device is rejected', () async {
    final n = await startPairing(server, deviceName: 'Laptop');
    server.tamperNextLookup = {'deviceName': "Mom's phone"};
    await expectLater(approver.lookup(n.code.display), throwsA(isA<PairingException>()));
  });

  test('QR eph mismatch is rejected', () async {
    final n = await startPairing(server);
    final other = PairQr(n.code, Uint8List(32)..[0] = 9).encode();
    await expectLater(
      approver.lookup(other),
      throwsA(isA<PairingException>().having((e) => e.kind, 'kind', PairingError.mismatch)),
    );
  });

  test('a wrong secret is a mismatch, an unknown lookup is notFound, garbage is badCode', () async {
    final n = await startPairing(server);
    final wrongSecret = PairCode(n.code.lookup, 'ZZZZZZZZZZZZ').display;
    await expectLater(approver.lookup(wrongSecret),
        throwsA(isA<PairingException>().having((e) => e.kind, 'kind', PairingError.mismatch)));
    final unknownLookup = n.code.lookup == 'ZZZZ' ? 'YYYY' : 'ZZZZ';
    await expectLater(approver.lookup(PairCode(unknownLookup, n.code.secret).display),
        throwsA(isA<PairingException>().having((e) => e.kind, 'kind', PairingError.notFound)));
    await expectLater(approver.lookup('hello'),
        throwsA(isA<PairingException>().having((e) => e.kind, 'kind', PairingError.badCode)));
  });

  test('approving an expired session is notFound', () async {
    final n = await startPairing(server);
    final pending = await approver.lookup(n.code.display);
    server.pairSessionByCode(n.code.lookup)!.cancelledAt = DateTime.now();
    await expectLater(approver.approve(pending),
        throwsA(isA<PairingException>().having((e) => e.kind, 'kind', PairingError.notFound)));
  });
}
