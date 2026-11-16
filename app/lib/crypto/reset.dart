// Account resets and the admin recovery code (docs/protocol.md "Account resets").
// Byte strings match server/src/lib/reset.ts.
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'encoding.dart';
import 'keys.dart';

final _ed25519 = Ed25519();

/// What an admin (or the recovery key) signs to reset [userId]: their old identity key is
/// retired, and whoever holds the claim key for [claimPub] may sign in with a new one.
class ResetStatement {
  const ResetStatement({
    required this.resetId,
    required this.userId,
    required this.signerUserId,
    required this.signerKind,
    required this.oldIdentityPub,
    required this.claimPub,
    required this.createdAt,
  });

  final String resetId, userId, signerUserId;

  /// `admin` or `recovery`.
  final String signerKind;
  final Uint8List oldIdentityPub, claimPub;

  /// Unix ms.
  final int createdAt;
}

/// `"famchat-reset-v1" ‖ str(resetId) ‖ str(userId) ‖ str(signerUserId) ‖ str(signerKind) ‖
/// oldIdentityPub ‖ claimPub ‖ u64(createdAt)`.
Uint8List resetMessage(ResetStatement s) {
  if (s.oldIdentityPub.length != 32 || s.claimPub.length != 32) throw ArgumentError('keys must be 32 bytes');
  if (s.createdAt < 0) throw ArgumentError.value(s.createdAt, 'createdAt');
  return (ByteWriter(domainReset)
        ..str(s.resetId)
        ..str(s.userId)
        ..str(s.signerUserId)
        ..str(s.signerKind)
        ..bytes(s.oldIdentityPub)
        ..bytes(s.claimPub)
        ..u32(s.createdAt ~/ 0x100000000)
        ..u32(s.createdAt % 0x100000000))
      .finish();
}

Future<Uint8List> _sign(SimpleKeyPair key, List<int> msg) async =>
    Uint8List.fromList((await _ed25519.sign(msg, keyPair: key)).bytes);

Future<bool> _verify(List<int> pub, List<int> sig, List<int> msg) async {
  if (pub.length != 32 || sig.length != 64) return false;
  try {
    return await _ed25519.verify(msg, signature: Signature(sig, publicKey: SimplePublicKey(pub, type: KeyPairType.ed25519)));
  } catch (_) {
    return false;
  }
}

Future<Uint8List> signReset(ResetStatement s, SimpleKeyPair signer) => _sign(signer, resetMessage(s));

/// Never throws.
Future<bool> verifyReset(ResetStatement s, {required List<int> signerPub, required List<int> sig}) async {
  final Uint8List msg;
  try {
    msg = resetMessage(s);
  } on ArgumentError {
    return false;
  }
  return _verify(signerPub, sig, msg);
}

/// `"famchat-reset-claim-v1" ‖ claimPub ‖ newIdentityPub`. The claim key is made for one reset
/// (whose signed statement names it), so it binds the reset; the new device needn't know its id.
Uint8List _claimMessage(List<int> claimPub, List<int> newIdentityPub) {
  if (claimPub.length != 32 || newIdentityPub.length != 32) throw ArgumentError('keys must be 32 bytes');
  return (ByteWriter(domainResetClaim)
        ..bytes(claimPub)
        ..bytes(newIdentityPub))
      .finish();
}

/// The new device's proof that it holds the reset link's claim key.
Future<Uint8List> signResetClaim(SimpleKeyPair claimKey, {required List<int> newIdentityPub}) async =>
    _sign(claimKey, _claimMessage(await publicKeyOf(claimKey), newIdentityPub));

Future<bool> verifyResetClaim({
  required List<int> claimPub,
  required List<int> newIdentityPub,
  required List<int> sig,
}) async {
  if (claimPub.length != 32 || newIdentityPub.length != 32) return false;
  return _verify(claimPub, sig, _claimMessage(claimPub, newIdentityPub));
}

Uint8List _recoveryKeyMessage(String userId, List<int> recoveryPub) {
  if (recoveryPub.length != 32) throw ArgumentError('key must be 32 bytes');
  return (ByteWriter(domainRecoveryKey)
        ..str(userId)
        ..bytes(recoveryPub))
      .finish();
}

/// The admin's identity key vouches for their recovery key.
Future<Uint8List> signRecoveryKey(SimpleKeyPair identity, {required String userId, required List<int> recoveryPub}) =>
    _sign(identity, _recoveryKeyMessage(userId, recoveryPub));

Future<bool> verifyRecoveryKey({
  required List<int> identityPub,
  required String userId,
  required List<int> recoveryPub,
  required List<int> sig,
}) async {
  if (recoveryPub.length != 32) return false;
  return _verify(identityPub, sig, _recoveryKeyMessage(userId, recoveryPub));
}

// --- the printed admin recovery code ---

const _alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
const recoveryCodeLength = 25;
final _compact = RegExp(r'^[0-9A-HJKMNP-TV-Z]{25}$');

/// 25 Crockford base32 characters (125 bits), shown as `XXXXX-XXXXX-XXXXX-XXXXX-XXXXX`.
class RecoveryCode {
  const RecoveryCode._(this.compact);

  final String compact;

  String get display => [for (var i = 0; i < recoveryCodeLength; i += 5) compact.substring(i, i + 5)].join('-');

  /// Accepts any case, spaces and dashes, and `O`→`0`, `I`/`L`→`1`. Null unless exactly 25 code characters.
  static RecoveryCode? parse(String input) {
    final s = input
        .toUpperCase()
        .replaceAll(RegExp(r'[\s-]'), '')
        .replaceAll('O', '0')
        .replaceAll(RegExp('[IL]'), '1');
    return _compact.hasMatch(s) ? RecoveryCode._(s) : null;
  }
}

RecoveryCode newRecoveryCode([Random? random]) {
  final r = random ?? Random.secure();
  return RecoveryCode._(String.fromCharCodes(List.generate(recoveryCodeLength, (_) => _alphabet.codeUnitAt(r.nextInt(32)))));
}

final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

/// The Ed25519 recovery key: seed = HKDF-SHA256(UTF-8(code), salt = "", info = "famchat-recovery-seed-v1").
Future<SimpleKeyPair> recoveryKeyFrom(RecoveryCode code) async {
  final k = await _hkdf.deriveKey(
    secretKey: SecretKey(utf8.encode(code.compact)),
    nonce: const <int>[],
    info: utf8.encode(domainRecoverySeed),
  );
  return newIdentityKey(seed: await k.extractBytes());
}
