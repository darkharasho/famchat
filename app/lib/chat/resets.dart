// What the family's signed account resets prove (docs/protocol.md "Account resets").
//
// Admins: the server's isAdmin flag alone carries no authority. A device trusts as admins the
// users it pinned (every admin the server listed when this device first saw the family, plus what
// a pairing handed over), anyone an admin it trusts promoted with a signed promotion, and its own
// user (nobody else can make this user's signatures).
//
// A reset counts only if its statement verifies under its signer key and either
// - (admin) the signer is a trusted admin other than the user, signing with a key this device
//   trusts for them, or
// - (recovery) the user's old identity key — one this device already trusts — vouched for the
//   recovery key that signed it.
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
    required this.isAdmin,
    required this.serverKey,
    required this.trustedKey,
    required this.known,
    this.pinnedAdmin = false,
    this.adminProof,
    this.resets = const [],
  });

  final String userId;

  /// What the server says (no authority on its own).
  final bool isAdmin;

  /// This device already trusts the user as an admin.
  final bool pinnedAdmin;
  final AdminProofDto? adminProof;

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

  /// Users this device trusts as admins (pinned, or promoted by a trusted admin).
  final Set<String> admins;
}

class _Checked {
  _Checked(this.userId, this.r, this.claimed);
  final String userId;
  final ResetDto r;

  /// Completed with a claim signature over the new key that verifies under the claim key.
  final bool claimed;
}

Future<TrustOutcome> resolveTrust(List<TrustInput> users, {required String myUserId}) async {
  final trusted0 = {for (final u in users) u.userId: u.trustedKey};
  final trusted = {...trusted0};
  final known = {for (final u in users) u.userId: {...u.known, u.trustedKey}};
  final admins = {for (final u in users) if (u.pinnedAdmin && u.isAdmin) u.userId};
  final retired = <String, Set<String>>{};
  final acknowledged = <String>{};
  final witnessed = <WitnessedReset>[];

  // Signature checks that don't depend on trust, once each.
  final candidates = <_Checked>[];
  final promotions = <TrustInput>[];
  for (final u in users) {
    for (final r in u.resets) {
      if (!await _statementValid(u.userId, r)) continue;
      candidates.add(_Checked(u.userId, r, await _claimValid(r)));
    }
    final p = u.adminProof;
    if (u.isAdmin && p != null && p.byUserId != u.userId && await _promotionValid(u.userId, p)) promotions.add(u);
  }

  /// [signer]'s current trusted key (as of the start, or after this pass moved it).
  bool current(String signer, String pub) => pub == trusted0[signer] || pub == trusted[signer];

  bool counted(_Checked c, {required bool history}) {
    final r = c.r;
    if (r.signerKind == 'recovery') return known[c.userId]!.contains(r.oldIdentityPub);
    final signer = r.signerUserId;
    if (signer != myUserId && !admins.contains(signer)) return false;
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
    for (final u in promotions) {
      final p = u.adminProof!;
      if (!admins.contains(u.userId) && (p.byUserId == myUserId || admins.contains(p.byUserId)) && current(p.byUserId, p.signerPub)) {
        admins.add(u.userId);
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

Future<bool> _promotionValid(String userId, AdminProofDto p) async {
  try {
    return await verifyPromotion(
      signerPub: b64urlDecode(p.signerPub),
      userId: userId,
      byUserId: p.byUserId,
      sig: b64urlDecode(p.sig),
    );
  } on CryptoFailure {
    return false;
  }
}
