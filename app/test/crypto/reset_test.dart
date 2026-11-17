import 'dart:math';
import 'dart:typed_data';

import 'package:famchat/crypto/encoding.dart';
import 'package:famchat/crypto/keys.dart';
import 'package:famchat/crypto/reset.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _bytes(int n, int fill) => Uint8List.fromList(List.filled(n, fill));

void main() {
  test('reset domains are registered and no domain is a prefix of another', () {
    expect(famchatDomains, containsAll(['famchat-reset-v1', 'famchat-reset-claim-v1', 'famchat-recovery-key-v1', 'famchat-recovery-seed-v1', 'famchat-admin-v1']));
    for (final a in famchatDomains) {
      for (final b in famchatDomains) {
        if (a != b) expect(b.startsWith(a), isFalse, reason: '$a is a prefix of $b');
      }
    }
  });

  ResetStatement statement({String? userId, String? signer, String kind = 'admin', int? createdAt, Uint8List? old, Uint8List? claim}) =>
      ResetStatement(
        resetId: '01JRESET000000000000000000',
        userId: userId ?? '01JMOM0000000000000000000A',
        signerUserId: signer ?? '01JADMIN000000000000000000',
        signerKind: kind,
        oldIdentityPub: old ?? _bytes(32, 1),
        claimPub: claim ?? _bytes(32, 2),
        createdAt: createdAt ?? 1763280000123,
      );

  test('statement byte layout (u64 time, big-endian)', () {
    final m = resetMessage(statement(createdAt: 0x0102030405));
    expect(m.sublist(0, 16), 'famchat-reset-v1'.codeUnits);
    expect(m.sublist(m.length - 8), [0, 0, 0, 1, 2, 3, 4, 5]);
  });

  test('statement signs and verifies; any change fails', () async {
    final admin = await newIdentityKey();
    final st = statement();
    final sig = await signReset(st, admin);
    final pub = await publicKeyOf(admin);
    expect(await verifyReset(st, signerPub: pub, sig: sig), isTrue);
    for (final other in [
      statement(userId: '01JDAD0000000000000000000A'),
      statement(signer: '01JKID0000000000000000000A'),
      statement(kind: 'recovery'),
      statement(createdAt: 1763280000124),
      statement(old: _bytes(32, 9)),
      statement(claim: _bytes(32, 9)),
    ]) {
      expect(await verifyReset(other, signerPub: pub, sig: sig), isFalse);
    }
    expect(await verifyReset(st, signerPub: await publicKeyOf(await newIdentityKey()), sig: sig), isFalse);
    expect(await verifyReset(st, signerPub: pub, sig: Uint8List(64)), isFalse);
    expect(await verifyReset(st, signerPub: pub, sig: Uint8List(3)), isFalse);
  });

  test('claim binds the claim key and the new identity key', () async {
    final claim = await newIdentityKey();
    final newId = _bytes(32, 7);
    final sig = await signResetClaim(claim, newIdentityPub: newId);
    final pub = await publicKeyOf(claim);
    expect(await verifyResetClaim(claimPub: pub, newIdentityPub: newId, sig: sig), isTrue);
    expect(await verifyResetClaim(claimPub: pub, newIdentityPub: _bytes(32, 8), sig: sig), isFalse);
    expect(await verifyResetClaim(claimPub: await publicKeyOf(await newIdentityKey()), newIdentityPub: newId, sig: sig), isFalse);
  });

  test('promotion binds the promoted user and the promoter', () async {
    final admin = await newIdentityKey();
    final pub = await publicKeyOf(admin);
    final sig = await signPromotion(admin, userId: 'DAD', byUserId: 'ADM');
    expect(b64url(sig), isNotEmpty);
    expect(await verifyPromotion(signerPub: pub, userId: 'DAD', byUserId: 'ADM', sig: sig), isTrue);
    expect(await verifyPromotion(signerPub: pub, userId: 'KID', byUserId: 'ADM', sig: sig), isFalse);
    expect(await verifyPromotion(signerPub: pub, userId: 'DAD', byUserId: 'MOM', sig: sig), isFalse);
  });

  test('recovery key registration is signed by the identity key', () async {
    final identity = await newIdentityKey();
    final rk = _bytes(32, 5);
    final sig = await signRecoveryKey(identity, userId: 'U1', recoveryPub: rk);
    final pub = await publicKeyOf(identity);
    expect(await verifyRecoveryKey(identityPub: pub, userId: 'U1', recoveryPub: rk, sig: sig), isTrue);
    expect(await verifyRecoveryKey(identityPub: pub, userId: 'U2', recoveryPub: rk, sig: sig), isFalse);
  });

  group('recovery code', () {
    test('25 Crockford characters shown in five groups', () {
      final c = newRecoveryCode(Random(1));
      expect(c.compact, matches(RegExp(r'^[0-9A-HJKMNP-TV-Z]{25}$')));
      expect(c.display, matches(RegExp(r'^([0-9A-Z]{5}-){4}[0-9A-Z]{5}$')));
      expect(RecoveryCode.parse(c.display)!.compact, c.compact);
    });

    test('parse forgives case, spaces, dashes and look-alikes', () {
      final c = RecoveryCode.parse('abcde fghjk-mnpqr stvwx-yz01o')!;
      expect(c.compact, 'ABCDEFGHJKMNPQRSTVWXYZ010');
      expect(RecoveryCode.parse('ABCDE-FGHJK-MNPQR-STVWX-YZ01I')!.compact, 'ABCDEFGHJKMNPQRSTVWXYZ011');
      expect(RecoveryCode.parse('ABCDE'), isNull);
      expect(RecoveryCode.parse('ABCDE-FGHJK-MNPQR-STVWX-YZ01U'), isNull);
    });

    test('the key is deterministic per code', () async {
      final c = newRecoveryCode();
      final a = await recoveryKeyFrom(c), b = await recoveryKeyFrom(RecoveryCode.parse(c.display.toLowerCase())!);
      expect(await publicKeyOf(a), await publicKeyOf(b));
      expect(await publicKeyOf(await recoveryKeyFrom(newRecoveryCode())), isNot(await publicKeyOf(a)));
    });
  });

  test('fixed vector shared with server/test/reset-vector.test.ts', () async {
    final signer = await newIdentityKey(seed: _bytes(32, 0x11));
    final st = statement();
    final sig = await signReset(st, signer);
    // Ed25519 is deterministic: these bytes are pinned in the server test.
    expect(b64url(await publicKeyOf(signer)), resetVector['signerPub']);
    expect(b64url(sig), resetVector['sig']);
    final claim = await newIdentityKey(seed: _bytes(32, 0x22));
    expect(b64url(await signResetClaim(claim, newIdentityPub: _bytes(32, 3))), resetVector['claimSig']);
    expect(b64url(await publicKeyOf(claim)), resetVector['claimPub']);
    final rk = await recoveryKeyFrom(RecoveryCode.parse('ABCDE-FGHJK-MNPQR-STVWX-YZ012')!);
    expect(b64url(await publicKeyOf(rk)), resetVector['recoveryPub']);
    expect(b64url(await signPromotion(signer, userId: st.userId, byUserId: st.signerUserId)), resetVector['promotionSig']);
  });
  group('v2 promotions', () {
    const seed = 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8';
    const signerPub = 'A6EHv_POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg';
    const userId = '01JMOM0000000000000000000A';
    const byUserId = '01JADMIN000000000000000000';
    const sig = 'R15HUaNwSBgJ2AhhhRTOuzSYuCYKEiSPof7eXnK4EOEZPSgMz8u-wzyzgveO6l6cWd6NifFbfeKcnY23AQs-Dw';

    test('shared vector verifies; wrong family and v1 do not', () async {
      Future<bool> v2(int familyId) => verifyPromotionV2(
          signerPub: b64urlDecode(signerPub), familyId: familyId, userId: userId, byUserId: byUserId, sig: b64urlDecode(sig));
      expect(await v2(1), isTrue);
      expect(await v2(2), isFalse);
      expect(await verifyPromotion(signerPub: b64urlDecode(signerPub), userId: userId, byUserId: byUserId, sig: b64urlDecode(sig)), isFalse);
    });

    test('signing with the vector seed reproduces the vector', () async {
      final key = await newIdentityKey(seed: b64urlDecode(seed));
      expect(b64url(await publicKeyOf(key)), signerPub);
      final s = await signPromotionV2(key, familyId: 1, userId: userId, byUserId: byUserId);
      expect(b64url(s), sig);
      expect(await verifyPromotionV2(signerPub: await publicKeyOf(key), familyId: 1, userId: userId, byUserId: byUserId, sig: s), isTrue);
      expect(await verifyPromotionV2(signerPub: await publicKeyOf(key), familyId: 1, userId: userId, byUserId: 'x', sig: s), isFalse);
    });
  });

}

/// The server test (server/test/reset-vector.test.ts) checks the same values.
const resetVector = <String, String>{
  'signerPub': '0EqyMnQrtKs6E2i9RhXk5tAiSrcaAWuvhSCjMsl3hzc',
  'sig': '2bTQ9TLFCiIhyFcaaiIdJG5EYZ5DWv4NnPBSezyszPNyhHTC--a4j2MKAtke7MRr2utg04wxqEkBylI2sYr7Dg',
  'claimPub': 'oJql9HpnWYAv-VX43C0qFKXJnSO-l_hkEn_5ODRVpPA',
  'claimSig': 'Jlze_kYQ0E_SOE2Vk6N1uO6MZap0wohPBjrFZiznTKtHmwZP47d9H15vqMVFkDpQEjwNFcQFnryJ9rQxdVGwDg',
  'recoveryPub': 'eUCm29K8ImuMaI3m5sFSFc5dTYRJGuhtXRbOZQv2CWY',
  'promotionSig': 'KunKvoovZnGzngrDT31ZUMxdUZOSNCnlGs7dvdjBtm_HP8sxqHvWWayKVARJih5XqgHGEuTVT37R-NHKXysADQ',
};
