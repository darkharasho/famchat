// What an admin's device does for the family (docs/protocol.md "Account resets"): reset someone who
// lost every device, make someone a second admin, and save an admin recovery code.
import 'package:cryptography/cryptography.dart';

import '../api/api_client.dart';
import '../api/models.dart';
import '../chat/ulid.dart';
import '../crypto/encoding.dart';
import '../crypto/keys.dart';
import '../crypto/reset.dart';

class AdminService {
  AdminService({required this.api, required this.userId, required this.identity, DateTime Function()? now})
      : _now = now ?? DateTime.now;

  final ApiClient api;

  /// The admin (this device's user) and their identity key.
  final String userId;
  final Future<SimpleKeyPair> Function() identity;
  final DateTime Function() _now;

  ApiClient get _api => api;
  String get _userId => userId;
  Future<SimpleKeyPair> _identity() => identity();

  /// Resets [userId], whose identity key the server lists as [currentIdentityPub] (base64url):
  /// signs the statement with this admin's identity key and returns the link to give them. Their
  /// devices are signed out at once. Throws [ApiException] (`conflict`: the directory was stale).
  Future<ResetLink> resetUser(String userId, {required String currentIdentityPub}) async {
    final claim = await newIdentityKey();
    final now = _now();
    final st = ResetStatement(
      resetId: newUlid(now),
      userId: userId,
      signerUserId: _userId,
      signerKind: 'admin',
      oldIdentityPub: b64urlDecode(currentIdentityPub),
      claimPub: await publicKeyOf(claim),
      createdAt: now.millisecondsSinceEpoch,
    );
    final r = await _api.resetUser(
      userId,
      resetId: st.resetId,
      oldIdentityPub: currentIdentityPub,
      claimPub: b64url(st.claimPub),
      createdAt: st.createdAt,
      sig: b64url(await signReset(st, await _identity())),
    );
    return ResetLink(resetId: r.resetId, url: '${r.inviteUrl}.${b64url(await seedOf(claim))}', expiresAt: r.expiresAt);
  }

  Future<void> makeAdmin(String userId) => _api.makeAdmin(userId);

  /// Makes a new recovery code and registers its key (replacing any earlier code). Show the code
  /// once: it isn't stored anywhere.
  Future<RecoveryCode> createRecoveryCode() async {
    final code = newRecoveryCode();
    final rk = await publicKeyOf(await recoveryKeyFrom(code));
    final sig = await signRecoveryKey(await _identity(), userId: _userId, recoveryPub: rk);
    await _api.setRecoveryKey(recoveryPub: b64url(rk), sig: b64url(sig));
    return code;
  }
}
