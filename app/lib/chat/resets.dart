// What the family's signed account resets prove (docs/protocol.md "Account resets").
//
// Admins, per family: the server's admin role alone carries no authority, and a device trusts
// admins only in the families its own user belongs to (my own input's `families`).
// - Start: for a family this device has seen (a key in `pinned`), its pins that the server still
//   lists as admins of it (losing trust follows the server: a demoted, removed or departed admin is
//   dropped); for a family seen for the first time, every admin the server lists for it (trust on
//   first use).
// - Then: a user the server lists as an admin of family F becomes a trusted admin of F if their
//   signed promotion (v2 for F, or a legacy v1 proof in family 1 only) was made by someone else, by
//   me or a trusted admin of F, with that promoter's current trusted key. Becoming trusted again
//   after a demotion needs such a fresh proof.
// My own user needs no pin (nobody else can make this user's signatures).
//
// A reset counts only if its statement verifies under its signer key and either
// - (admin) the signer is me, or a trusted admin of a family the reset user and I both belong to
//   (some F on the user's `families` with the signer in admins[F]), other than the user, signing
//   with a key this device trusts for them, or
// - (admin, history only) the user is a former one (no families: someone I only share a chat
//   with, listed so old messages still verify) and the signer is me or a trusted admin of any
//   family of mine; forward, witnessed and retired still need a shared family, so a former user
//   never gets an admin reset acknowledged, or
// - (recovery) the user's old identity key — one this device already trusts — vouched for the
//   recovery key that signed it.
// A reset that doesn't count leaves the trusted key alone, so the key mismatch gets the manual
// "security key changed" banner.
// What a counted reset does:
// - forward: if its old key is the user's trusted key and it was claimed with a valid claim
//   signature, its new key becomes trusted (acknowledged automatically, no manual banner);
// - witnessed: if its old key is the trusted key, it gets a reset banner (a newer reset of the same
//   key supersedes an unclaimed one);
// - retired: its old key's devices count as revoked;
// - backward: if its new key is known, its old key becomes known (history: old messages verify).
// Forward, witnessed and retired need the signer's current trusted key (a retired admin key, e.g.
// on a lost phone, can't move anyone's trust); history also accepts the signer's older known keys.
// Everything is repeated until nothing changes, because one user's history or promotion can vouch
// for the admin key that signed another's.
import '../crypto/encoding.dart';
import '../crypto/reset.dart';
import 'wire.dart';

class TrustInput {
  const TrustInput({
    required this.userId,
    required this.serverKey,
    required this.trustedKey,
    required this.known,
    this.families = const [],
    this.resets = const [],
  });

  final String userId;

  /// The user's role in each family, as the server lists it (no authority on its own); empty for
  /// a former user.
  final List<FamilyRoleDto> families;

  /// What the server says the user's identity key is now.
  final String serverKey;

  /// The key this device trusts for the user (first seen or acknowledged; mine: the key I hold).
  final String trustedKey;

  /// Every key this device has trusted for the user.
  final Set<String> known;
  final List<ResetDto> resets;
}

class WitnessedReset {
  const WitnessedReset(this.userId, this.reset);
  final String userId;
  final ResetDto reset;
}

class TrustOutcome {
  const TrustOutcome({
    required this.trusted,
    required this.known,
    required this.retired,
    required this.acknowledged,
    required this.witnessed,
    required this.admins,
  });

  final Map<String, String> trusted;
  final Map<String, Set<String>> known;

  /// Per user, keys a counted reset retired: devices certified only by them count as revoked.
  final Map<String, Set<String>> retired;

  /// Users whose trusted key moved forward through counted, claimed resets.
  final Set<String> acknowledged;

  /// Counted resets whose old key was the trusted key (the reset banner), in order.
  final List<WitnessedReset> witnessed;

  /// Per family of mine, the users this device trusts as its admins (pinned and still listed, or
  /// promoted by a trusted admin of it).
  final Map<int, Set<String>> admins;
}

class _Checked {
  _Checked(this.userId, this.r, this.claimed);
  final String userId;
  final ResetDto r;

  /// Completed with a claim signature over the new key that verifies under the claim key.
  final bool claimed;
}

class _Promotion {
  _Promotion(this.familyId, this.userId, this.proof);
  final int familyId;
  final String userId;
  final AdminProofDto proof;
}

/// [pinned]: per family this device has seen, the admins it trusted there (absent: first sight).
Future<TrustOutcome> resolveTrust(
  List<TrustInput> users, {
  required String myUserId,
  required Map<int, Set<String>> pinned,
}) async {
  final trusted0 = {for (final u in users) u.userId: u.trustedKey};
  final trusted = {...trusted0};
  final known = {for (final u in users) u.userId: {...u.known, u.trustedKey}};
  final families = {for (final u in users) u.userId: u.families};
  bool listedAdmin(TrustInput u, int familyId) => u.families.any((f) => f.id == familyId && f.admin);
  final myFamilies = {for (final f in families[myUserId] ?? const <FamilyRoleDto>[]) f.id};
  final admins = <int, Set<String>>{
    for (final fid in myFamilies)
      fid: {
        for (final u in users)
          if (listedAdmin(u, fid) && (pinned[fid]?.contains(u.userId) ?? true)) u.userId,
      },
  };
  final retired = <String, Set<String>>{};
  final acknowledged = <String>{};
  final witnessed = <WitnessedReset>[];

  // Signature checks that don't depend on trust, once each.
  final candidates = <_Checked>[];
  final promotions = <_Promotion>[];
  for (final u in users) {
    for (final r in u.resets) {
      if (!await _statementValid(u.userId, r)) continue;
      candidates.add(_Checked(u.userId, r, await _claimValid(r)));
    }
    for (final f in u.families) {
      final p = f.adminProof;
      if (!myFamilies.contains(f.id) || !f.admin || p == null || p.byUserId == u.userId) continue;
      if (await _promotionValid(f.id, u.userId, p)) promotions.add(_Promotion(f.id, u.userId, p));
    }
  }

  /// [signer]'s current trusted key (as of the start, or after this pass moved it).
  bool current(String signer, String pub) => pub == trusted0[signer] || pub == trusted[signer];

  /// [signer] is a trusted admin of a family [targetFamilies] shares with me; for history only, a
  /// former target (no families) accepts a trusted admin of any family of mine.
  bool adminOf(String signer, List<FamilyRoleDto> targetFamilies, {required bool history}) =>
      targetFamilies.any((f) => admins[f.id]?.contains(signer) ?? false) ||
      (history && targetFamilies.isEmpty && admins.values.any((a) => a.contains(signer)));

  bool counted(_Checked c, {required bool history}) {
    final r = c.r;
    if (r.signerKind == 'recovery') return known[c.userId]!.contains(r.oldIdentityPub);
    final signer = r.signerUserId;
    if (signer != myUserId && !adminOf(signer, families[c.userId]!, history: history)) return false;
    return history ? (known[signer]?.contains(r.signerPub) ?? false) : current(signer, r.signerPub);
  }

  /// A newer counted reset of the same old key replaces an unclaimed one (a superseded link).
  bool superseded(_Checked c) =>
      !c.claimed &&
      candidates.any((o) =>
          o != c && o.userId == c.userId && o.r.oldIdentityPub == c.r.oldIdentityPub && o.r.createdAt > c.r.createdAt);

  final done = <String>{}; // resets already applied forward or witnessed
  for (var changed = true; changed;) {
    changed = false;
    for (final pr in promotions) {
      final p = pr.proof, fa = admins[pr.familyId]!;
      if (!fa.contains(pr.userId) && (p.byUserId == myUserId || fa.contains(p.byUserId)) && current(p.byUserId, p.signerPub)) {
        fa.add(pr.userId);
        changed = true;
      }
    }
    for (final c in candidates) {
      final r = c.r, u = c.userId;
      if (counted(c, history: false)) {
        if ((retired[u] ??= {}).add(r.oldIdentityPub)) changed = true;
        if (r.oldIdentityPub == trusted[u] && u != myUserId && !superseded(c) && done.add(r.id)) {
          witnessed.add(WitnessedReset(u, r));
          changed = true;
          if (c.claimed) {
            trusted[u] = r.newIdentityPub!;
            known[u]!.add(r.newIdentityPub!);
            acknowledged.add(u);
          }
        }
      }
      if (c.claimed && counted(c, history: true) && known[u]!.contains(r.newIdentityPub) && known[u]!.add(r.oldIdentityPub)) {
        changed = true;
      }
    }
  }
  return TrustOutcome(
    trusted: trusted,
    known: known,
    retired: retired,
    acknowledged: acknowledged,
    witnessed: witnessed,
    admins: admins,
  );
}

Future<bool> _statementValid(String userId, ResetDto r) async {
  try {
    final st = ResetStatement(
      resetId: r.id,
      userId: userId,
      signerUserId: r.signerUserId,
      signerKind: r.signerKind,
      oldIdentityPub: b64urlDecode(r.oldIdentityPub),
      claimPub: b64urlDecode(r.claimPub),
      createdAt: r.createdAt,
    );
    if (!await verifyReset(st, signerPub: b64urlDecode(r.signerPub), sig: b64urlDecode(r.sig))) return false;
    switch (r.signerKind) {
      case 'admin':
        return r.signerUserId != userId;
      case 'recovery':
        final rs = r.recoverySig;
        return r.signerUserId == userId &&
            rs != null &&
            await verifyRecoveryKey(
              identityPub: b64urlDecode(r.oldIdentityPub),
              userId: userId,
              recoveryPub: b64urlDecode(r.signerPub),
              sig: b64urlDecode(rs),
            );
      default:
        return false;
    }
  } on CryptoFailure {
    return false;
  } on ArgumentError {
    return false;
  }
}

Future<bool> _claimValid(ResetDto r) async {
  final next = r.newIdentityPub, sig = r.claimSig;
  if (next == null || sig == null) return false;
  try {
    return await verifyResetClaim(
      claimPub: b64urlDecode(r.claimPub),
      newIdentityPub: b64urlDecode(next),
      sig: b64urlDecode(sig),
    );
  } on CryptoFailure {
    return false;
  }
}

/// A v2 promotion for [familyId], or a legacy v1 one in family 1 only.
Future<bool> _promotionValid(int familyId, String userId, AdminProofDto p) async {
  try {
    final signerPub = b64urlDecode(p.signerPub), sig = b64urlDecode(p.sig);
    if (await verifyPromotionV2(signerPub: signerPub, familyId: familyId, userId: userId, byUserId: p.byUserId, sig: sig)) {
      return true;
    }
    return familyId == 1 &&
        await verifyPromotion(signerPub: signerPub, userId: userId, byUserId: p.byUserId, sig: sig);
  } on CryptoFailure {
    return false;
  } on ArgumentError {
    return false;
  }
}
