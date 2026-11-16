// The approving device's side of pairing: find the session by the typed or scanned code, check
// that the server shows the new device's real keys (the MAC keyed by the code's secret), then
// certify the device and hand over the identity key and chat keys, sealed to the new device.
import '../api/api_client.dart';
import '../api/models.dart';
import '../chat/db/chat_db.dart';
import '../crypto/encoding.dart';
import '../crypto/pairing.dart';
import '../session/stored_session.dart';
import 'bundle.dart';
import 'pair_code.dart';

enum PairingError {
  /// Not a pairing code or QR.
  badCode,

  /// No open session for this code (expired, used or mistyped).
  notFound,

  /// The session's keys don't match the code: someone changed them, or the code is wrong.
  mismatch,
}

class PairingException implements Exception {
  const PairingException(this.kind);
  final PairingError kind;

  @override
  String toString() => 'PairingException($kind)';
}

/// A session whose keys checked out, waiting for the user's OK.
class PendingApproval {
  const PendingApproval(this.code, this.info);
  final PairCode code;
  final PairSessionInfo info;

  String get deviceName => info.deviceName;
  String get platform => info.platform;
}

class DeviceApprover {
  DeviceApprover({required this.api, required this.db, required this.session});

  final ApiClient api;
  final ChatDb db;
  final StoredSession session;

  /// [input] is a typed code or a scanned QR. Throws [PairingException], or [ApiException] /
  /// [NetworkException] for other failures.
  Future<PendingApproval> lookup(String input) async {
    final parsed = parsePairInput(input);
    if (parsed == null) throw const PairingException(PairingError.badCode);
    final PairSessionInfo info;
    try {
      info = await api.pairLookup(parsed.code.lookup);
    } on ApiException catch (e) {
      if (e.code == 'not_found') throw const PairingException(PairingError.notFound);
      rethrow;
    }
    try {
      final ephPub = b64urlDecode(info.ephPub);
      final qrEph = parsed.ephPub;
      if (qrEph != null && !_same(qrEph, ephPub)) throw const PairingException(PairingError.mismatch);
      final ok = await checkPairKeysMac(
        secret: parsed.code.secret,
        ephPub: ephPub,
        encPub: b64urlDecode(info.encPub),
        signPub: b64urlDecode(info.signPub),
        deviceName: info.deviceName,
        platform: info.platform,
        mac: b64urlDecode(info.keysMac),
      );
      if (!ok) throw const PairingException(PairingError.mismatch);
    } on CryptoFailure {
      throw const PairingException(PairingError.mismatch);
    }
    return PendingApproval(parsed.code, info);
  }

  /// Certifies the new device and posts the sealed handover. Throws [PairingException] (notFound if
  /// the session expired meanwhile), [ApiException] or [NetworkException].
  Future<void> approve(PendingApproval p) async {
    final bundle = await buildHandover(
      db: db,
      userId: session.userId,
      deviceId: p.info.deviceId,
      identity: await session.identityKey(),
      encPub: b64urlDecode(p.info.encPub),
      signPub: b64urlDecode(p.info.signPub),
    );
    final sealed = await sealPairBundle(
      recipientEphPub: b64urlDecode(p.info.ephPub),
      secret: p.code.secret,
      plaintext: bundle.encode(),
    );
    try {
      await api.pairApprove(p.info.lookup, deviceId: p.info.deviceId, certSig: b64url(bundle.certSig), bundle: b64url(sealed));
    } on ApiException catch (e) {
      if (e.code == 'not_found') throw const PairingException(PairingError.notFound);
      rethrow;
    }
  }

  static bool _same(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
