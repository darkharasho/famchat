// What the family's signed account resets prove (docs/protocol.md "Account resets").
//
// A reset counts only if its statement verifies under its signer key and either
// - (admin) the signer is another user the directory marks admin, and the signer key is one this
//   device trusts for them (current, acknowledged, or learned from a verified reset), or
// - (recovery) the user's old identity key — one this device already trusts — vouched for the
//   recovery key that signed it.
// From a counted reset:
// - forward: if its old key is the user's trusted key and it was claimed with a valid claim
//   signature, its new key becomes trusted (acknowledged automatically, no manual banner);
// - witnessed: if its old key is the trusted key, it gets a reset banner;
// - backward: if its new key is known, its old key becomes known (history: old messages verify);
// - retired: its old key's devices count as revoked.
// Everything is repeated until nothing changes, because one user's history can vouch for the admin
// key that signed another's.
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
    this.resets = const [],
  });

  final String userId;
  final bool isAdmin;

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
  });

  final Map<String, String> trusted;
  final Map<String, Set<String>> known;

  /// Per user, keys a counted reset retired: devices certified only by them count as revoked.
  final Map<String, Set<String>> retired;

  /// Users whose trusted key moved forward through counted, claimed resets.
  final Set<String> acknowledged;

  /// Counted resets whose old key was the trusted key (the reset banner), in order.
  final List<WitnessedReset> witnessed;
}

class _Checked {
  _Checked(this.userId, this.r, this.claimed);
  final String userId;
  final ResetDto r;

  /// Completed with a claim signature over the new key that verifies under the claim key.
  final bool claimed;
}

Future<TrustOutcome> resolveTrust(List<TrustInput> users, {required String myUserId}) async {
  final byId = {for (final u in users) u.userId: u};
  final trusted = {for (final u in users) u.userId: u.trustedKey};
  final known = {for (final u in users) u.userId: {...u.known, u.trustedKey}};
  final retired = <String, Set<String>>{};
  final acknowledged = <String>{};
  final witnessed = <WitnessedReset>[];

  // Signature checks that don't depend on trust, once per reset.
  final candidates = <_Checked>[];
  for (final u in users) {
    for (final r in u.resets) {
      if (!await _statementValid(u.userId, r, byId)) continue;
      candidates.add(_Checked(u.userId, r, await _claimValid(r)));
    }
  }

  bool counted(_Checked c) {
    final r = c.r;
    if (r.signerKind == 'recovery') return known[c.userId]!.contains(r.oldIdentityPub);
    return known[r.signerUserId]?.contains(r.signerPub) ?? false;
  }

  final done = <String>{}; // resets already applied forward or witnessed
  for (var changed = true; changed;) {
    changed = false;
    for (final c in candidates) {
      if (!counted(c)) continue;
      final r = c.r, u = c.userId;
      if ((retired[u] ??= {}).add(r.oldIdentityPub)) changed = true;
      if (r.oldIdentityPub == trusted[u] && u != myUserId && done.add(r.id)) {
        witnessed.add(WitnessedReset(u, r));
        changed = true;
        if (c.claimed) {
          trusted[u] = r.newIdentityPub!;
          known[u]!.add(r.newIdentityPub!);
          acknowledged.add(u);
        }
      }
      if (c.claimed && known[u]!.contains(r.newIdentityPub) && known[u]!.add(r.oldIdentityPub)) changed = true;
    }
  }
  return TrustOutcome(trusted: trusted, known: known, retired: retired, acknowledged: acknowledged, witnessed: witnessed);
}

Future<bool> _statementValid(String userId, ResetDto r, Map<String, TrustInput> users) async {
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
        return r.signerUserId != userId && (users[r.signerUserId]?.isAdmin ?? false);
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
