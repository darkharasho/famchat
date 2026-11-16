import 'package:cryptography/cryptography.dart';
import 'package:famchat/chat/resets.dart';
import 'package:famchat/chat/wire.dart';
import 'package:famchat/crypto/encoding.dart';
import 'package:famchat/crypto/keys.dart';
import 'package:famchat/crypto/reset.dart';
import 'package:flutter_test/flutter_test.dart';

class K {
  K._(this.pair, this.pub);
  final SimpleKeyPair pair;
  final String pub;
  static Future<K> make() async {
    final p = await newIdentityKey();
    return K._(p, b64url(await publicKeyOf(p)));
  }
}

int _n = 0;

/// A reset of [userId] from [old] (to [next] if given) signed by [signer] (an admin's identity key or a
/// recovery key), with a valid claim unless [badClaim].
Future<ResetDto> makeReset({
  required String userId,
  required String signerUserId,
  required K signer,
  required K old,
  K? next,
  String kind = 'admin',
  String? recoverySig,
  bool badClaim = false,
}) async {
  final claim = await K.make();
  final id = 'R${_n++}';
  final st = ResetStatement(
    resetId: id,
    userId: userId,
    signerUserId: signerUserId,
    signerKind: kind,
    oldIdentityPub: b64urlDecode(old.pub),
    claimPub: b64urlDecode(claim.pub),
    createdAt: 1763280000000 + _n,
  );
  String? claimSig;
  if (next != null) {
    final signWith = badClaim ? (await K.make()).pair : claim.pair;
    claimSig = b64url(await signResetClaim(signWith, newIdentityPub: b64urlDecode(next.pub)));
  }
  return ResetDto(
    id: id,
    signerUserId: signerUserId,
    signerKind: kind,
    signerPub: signer.pub,
    recoverySig: recoverySig,
    oldIdentityPub: old.pub,
    claimPub: claim.pub,
    createdAt: st.createdAt,
    sig: b64url(await signReset(st, signer.pair)),
    newIdentityPub: next?.pub,
    claimSig: claimSig,
    completedAt: next == null ? null : st.createdAt + 1,
  );
}

TrustInput user(
  String id, {
  required K server,
  K? trusted,
  Set<String>? known,
  bool admin = false,
  bool? pinned,
  AdminProofDto? proof,
  List<ResetDto> resets = const [],
}) =>
    TrustInput(
      userId: id,
      isAdmin: admin,
      pinnedAdmin: pinned ?? admin,
      adminProof: proof,
      serverKey: server.pub,
      trustedKey: (trusted ?? server).pub,
      known: known ?? {(trusted ?? server).pub},
      resets: resets,
    );

Future<AdminProofDto> promotion(String userId, {required String by, required K signer}) async => AdminProofDto(
      byUserId: by,
      signerPub: signer.pub,
      sig: b64url(await signPromotion(signer.pair, userId: userId, byUserId: by)),
    );

void main() {
  late K me, admin, mom1, mom2;
  setUp(() async {
    me = await K.make();
    admin = await K.make();
    mom1 = await K.make();
    mom2 = await K.make();
  });

  Future<TrustOutcome> resolve(List<TrustInput> others) =>
      resolveTrust([user('ME', server: me), ...others], myUserId: 'ME');

  test('a verified reset is acknowledged and witnessed', () async {
    final r = await makeReset(userId: 'MOM', signerUserId: 'ADM', signer: admin, old: mom1, next: mom2);
    final out = await resolve([
      user('ADM', server: admin, admin: true),
      user('MOM', server: mom2, trusted: mom1, resets: [r]),
    ]);
    expect(out.trusted['MOM'], mom2.pub);
    expect(out.acknowledged, {'MOM'});
    expect(out.known['MOM'], containsAll([mom1.pub, mom2.pub]));
    expect(out.retired['MOM'], {mom1.pub});
    expect(out.witnessed.map((w) => w.reset.id), [r.id]);
  });

  test('a chain of two resets is followed', () async {
    final mom3 = await K.make();
    final r1 = await makeReset(userId: 'MOM', signerUserId: 'ADM', signer: admin, old: mom1, next: mom2);
    final r2 = await makeReset(userId: 'MOM', signerUserId: 'ADM', signer: admin, old: mom2, next: mom3);
    final out = await resolve([
      user('ADM', server: admin, admin: true),
      user('MOM', server: mom3, trusted: mom1, resets: [r1, r2]),
    ]);
    expect(out.trusted['MOM'], mom3.pub);
    expect(out.witnessed.map((w) => w.reset.id), [r1.id, r2.id]);
  });

  test('reset signed by a non-admin is not trusted', () async {
    final r = await makeReset(userId: 'MOM', signerUserId: 'ADM', signer: admin, old: mom1, next: mom2);
    final out = await resolve([
      user('ADM', server: admin),
      user('MOM', server: mom2, trusted: mom1, resets: [r]),
    ]);
    expect(out.trusted['MOM'], mom1.pub);
    expect(out.acknowledged, isEmpty);
    expect(out.witnessed, isEmpty);
    expect(out.retired['MOM'] ?? {}, isEmpty);
  });

  test("reset signed by a key that isn't the admin's trusted key is not trusted", () async {
    final fake = await K.make();
    final r = await makeReset(userId: 'MOM', signerUserId: 'ADM', signer: fake, old: mom1, next: mom2);
    final out = await resolve([
      user('ADM', server: admin, admin: true),
      user('MOM', server: mom2, trusted: mom1, resets: [r]),
    ]);
    expect(out.acknowledged, isEmpty);
    expect(out.witnessed, isEmpty);
  });

  test('a tampered statement does not verify', () async {
    final r = await makeReset(userId: 'MOM', signerUserId: 'ADM', signer: admin, old: mom1, next: mom2);
    final tampered = ResetDto(
      id: r.id, signerUserId: r.signerUserId, signerKind: r.signerKind, signerPub: r.signerPub, recoverySig: null,
      oldIdentityPub: r.oldIdentityPub, claimPub: r.claimPub, createdAt: r.createdAt + 1, sig: r.sig,
      newIdentityPub: r.newIdentityPub, claimSig: r.claimSig, completedAt: r.completedAt,
    );
    final out = await resolve([
      user('ADM', server: admin, admin: true),
      user('MOM', server: mom2, trusted: mom1, resets: [tampered]),
    ]);
    expect(out.acknowledged, isEmpty);
  });

  test('completed reset with a bad claim is not acknowledged but still witnessed', () async {
    final r = await makeReset(userId: 'MOM', signerUserId: 'ADM', signer: admin, old: mom1, next: mom2, badClaim: true);
    final out = await resolve([
      user('ADM', server: admin, admin: true),
      user('MOM', server: mom2, trusted: mom1, resets: [r]),
    ]);
    expect(out.trusted['MOM'], mom1.pub);
    expect(out.acknowledged, isEmpty);
    expect(out.witnessed.map((w) => w.reset.id), [r.id]);
    expect(out.retired['MOM'], {mom1.pub});
  });

  test('a pending reset is witnessed and retires the old key, without acknowledging anything', () async {
    final r = await makeReset(userId: 'MOM', signerUserId: 'ADM', signer: admin, old: mom1);
    final out = await resolve([
      user('ADM', server: admin, admin: true),
      user('MOM', server: mom1, resets: [r]),
    ]);
    expect(out.trusted['MOM'], mom1.pub);
    expect(out.acknowledged, isEmpty);
    expect(out.witnessed.single.reset.id, r.id);
    expect(out.retired['MOM'], {mom1.pub});
  });

  test('a device that first sees the new key learns the old one from the history, without a banner', () async {
    final r = await makeReset(userId: 'MOM', signerUserId: 'ADM', signer: admin, old: mom1, next: mom2);
    final out = await resolve([
      user('ADM', server: admin, admin: true),
      user('MOM', server: mom2, resets: [r]),
    ]);
    expect(out.trusted['MOM'], mom2.pub);
    expect(out.known['MOM'], {mom1.pub, mom2.pub});
    expect(out.retired['MOM'], {mom1.pub});
    expect(out.witnessed, isEmpty);
    expect(out.acknowledged, isEmpty);
  });

  test('my own old key is learned from the history', () async {
    final me2 = await K.make();
    final r = await makeReset(userId: 'ME', signerUserId: 'ADM', signer: admin, old: me, next: me2);
    final out = await resolveTrust([
      user('ME', server: me2, resets: [r]),
      user('ADM', server: admin, admin: true),
    ], myUserId: 'ME');
    expect(out.known['ME'], {me.pub, me2.pub});
    expect(out.trusted['ME'], me2.pub);
  });

  test('history signed by an admin key learned from its own history verifies (any order)', () async {
    final admin2 = await K.make();
    final dad1 = await K.make(), dad2 = await K.make();
    // Mom (second admin) reset Michael; earlier, Michael (old key) had reset Dad.
    final dadReset = await makeReset(userId: 'DAD', signerUserId: 'ADM', signer: admin, old: dad1, next: dad2);
    final adminReset = await makeReset(userId: 'ADM', signerUserId: 'MOM', signer: mom1, old: admin, next: admin2);
    final out = await resolve([
      user('DAD', server: dad2, resets: [dadReset]),
      user('ADM', server: admin2, admin: true, resets: [adminReset]),
      user('MOM', server: mom1, admin: true),
    ]);
    expect(out.known['ADM'], {admin.pub, admin2.pub});
    expect(out.known['DAD'], {dad1.pub, dad2.pub});
  });

  group('who counts as an admin', () {
    test("an admin this device never pinned (the server's word only) is not trusted", () async {
      final fake = await K.make();
      final r = await makeReset(userId: 'MOM', signerUserId: 'FAKE', signer: fake, old: mom1, next: mom2);
      final out = await resolve([
        user('FAKE', server: fake, admin: true, pinned: false),
        user('MOM', server: mom2, trusted: mom1, resets: [r]),
      ]);
      expect(out.acknowledged, isEmpty);
      expect(out.witnessed, isEmpty);
      expect(out.retired['MOM'] ?? {}, isEmpty);
      expect(out.admins, isNot(contains('FAKE')));
    });

    test('a promotion signed by a trusted admin makes a trusted admin', () async {
      final dad = await K.make();
      final r = await makeReset(userId: 'MOM', signerUserId: 'DAD', signer: dad, old: mom1, next: mom2);
      final out = await resolve([
        user('ADM', server: admin, admin: true),
        user('DAD', server: dad, admin: true, pinned: false, proof: await promotion('DAD', by: 'ADM', signer: admin)),
        user('MOM', server: mom2, trusted: mom1, resets: [r]),
      ]);
      expect(out.admins, containsAll(['ADM', 'DAD']));
      expect(out.acknowledged, {'MOM'});
    });

    test('a promotion by an untrusted admin, or with a bad signature, makes nobody an admin', () async {
      final dad = await K.make(), fake = await K.make();
      final out = await resolve([
        user('ADM', server: admin, admin: true),
        user('FAKE', server: fake, admin: true, pinned: false),
        user('DAD', server: dad, admin: true, pinned: false, proof: await promotion('DAD', by: 'FAKE', signer: fake)),
        user('KID', server: dad, admin: true, pinned: false, proof: await promotion('DAD', by: 'ADM', signer: admin)),
      ]);
      expect(out.admins, {'ADM'});
    });

    test("a retired admin key (a lost phone's) can't move anyone's trust", () async {
      final admin2 = await K.make();
      final r = await makeReset(userId: 'MOM', signerUserId: 'ADM', signer: admin, old: mom1, next: mom2);
      final out = await resolve([
        user('ADM', server: admin2, trusted: admin2, known: {admin.pub, admin2.pub}, admin: true),
        user('MOM', server: mom2, trusted: mom1, resets: [r]),
      ]);
      expect(out.acknowledged, isEmpty);
      expect(out.witnessed, isEmpty);
      expect(out.trusted['MOM'], mom1.pub);
    });

    test('a newer reset of the same key replaces an unclaimed one in the banners', () async {
      final r1 = await makeReset(userId: 'MOM', signerUserId: 'ADM', signer: admin, old: mom1);
      final r2 = await makeReset(userId: 'MOM', signerUserId: 'ADM', signer: admin, old: mom1, next: mom2);
      final out = await resolve([
        user('ADM', server: admin, admin: true),
        user('MOM', server: mom2, trusted: mom1, resets: [r1, r2]),
      ]);
      expect(out.witnessed.map((w) => w.reset.id), [r2.id]);
      expect(out.acknowledged, {'MOM'});
    });
  });

  group('recovery', () {
    late K rk;
    setUp(() async => rk = await K.make());

    Future<ResetDto> recovery({K? vouchedBy}) async {
      final rsig = await signRecoveryKey((vouchedBy ?? admin).pair, userId: 'ADM', recoveryPub: b64urlDecode(rk.pub));
      return makeReset(
        userId: 'ADM', signerUserId: 'ADM', signer: rk, old: admin, next: mom2, kind: 'recovery', recoverySig: b64url(rsig),
      );
    }

    test('a recovery vouched for by the old identity key is acknowledged', () async {
      final r = await recovery();
      final out = await resolve([user('ADM', server: mom2, trusted: admin, admin: true, resets: [r])]);
      expect(out.trusted['ADM'], mom2.pub);
      expect(out.acknowledged, {'ADM'});
      expect(out.witnessed.single.reset.signerKind, 'recovery');
    });

    test('a recovery key vouched for by another key is not', () async {
      final r = await recovery(vouchedBy: await K.make());
      final out = await resolve([user('ADM', server: mom2, trusted: admin, admin: true, resets: [r])]);
      expect(out.acknowledged, isEmpty);
      expect(out.witnessed, isEmpty);
    });

    test('a recovery does not vouch for an old key nobody knew', () async {
      final r = await recovery();
      final out = await resolve([user('ADM', server: mom2, admin: true, resets: [r])]);
      expect(out.known['ADM'], {mom2.pub});
    });
  });
}
