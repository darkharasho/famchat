// The family directory: users, their devices' public keys, and which of them to trust.
// Identity keys are trusted on first use; a later change is accepted (admin resets are real)
// but flagged until the user acknowledges it. A device is usable only if its certificate
// verifies against its user's identity key — for this user, against the local identity key.
import 'dart:async';
import 'dart:typed_data';

import '../crypto/device_cert.dart';
import '../crypto/encoding.dart';
import '../crypto/keys.dart';
import 'db/chat_db.dart';
import 'wire.dart';

/// This device: who it is and its private keys.
class LocalIdentity {
  const LocalIdentity({required this.userId, required this.deviceId, required this.keys, required this.identityPub});
  final String userId, deviceId;
  final DeviceKeys keys;
  final Uint8List identityPub;
}

class VerifiedDevice {
  const VerifiedDevice({required this.id, required this.userId, required this.encPub, required this.signPub, required this.revoked});
  final String id, userId;
  final Uint8List encPub, signPub;
  final bool revoked;
}

class Directory {
  Directory(this._db, this._api, this._me);

  final ChatDb _db;
  final ChatApi _api;
  final LocalIdentity _me;
  Future<void>? _inflight;

  /// Fetches every user and device and re-checks every certificate. One call at a time.
  Future<void> refresh() => _inflight ??= _refresh().whenComplete(() => _inflight = null);

  Future<void> _refresh() async {
    final users = await _api.users();
    final myPub = b64url(_me.identityPub);
    for (final u in users) {
      final old = await _db.userById(u.id);
      final trusted = u.id == _me.userId ? myPub : (old?.trustedIdentityPub ?? u.identityPub);
      await _db.putUser(UserRow(
        id: u.id,
        name: u.name,
        isAdmin: u.isAdmin,
        identityPub: u.identityPub,
        trustedIdentityPub: trusted,
      ));
      // My own devices must chain to the key I hold; others' to the key the server lists now.
      final anchor = u.id == _me.userId ? myPub : u.identityPub;
      for (final d in u.devices) {
        await _db.putDevice(DeviceRow(
          id: d.id,
          userId: u.id,
          name: d.name,
          encPub: d.encPub,
          signPub: d.signPub,
          certSig: d.certSig,
          revoked: d.revoked,
          certValid: await _certValid(anchor, d),
        ));
      }
    }
  }

  static Future<bool> _certValid(String identityPub, DeviceDto d) async {
    try {
      return await verifyDeviceCert(DeviceCert(
        b64urlDecode(identityPub),
        b64urlDecode(d.encPub),
        b64urlDecode(d.signPub),
        b64urlDecode(d.certSig),
      ));
    } on CryptoFailure {
      return false;
    }
  }

  static VerifiedDevice? _verified(DeviceRow? d) {
    if (d == null || !d.certValid) return null;
    return VerifiedDevice(
      id: d.id,
      userId: d.userId,
      encPub: b64urlDecode(d.encPub),
      signPub: b64urlDecode(d.signPub),
      revoked: d.revoked,
    );
  }

  /// The device if its certificate verifies (revoked devices included, for old signatures).
  /// An unknown id refreshes the directory once.
  Future<VerifiedDevice?> device(String id) async {
    var row = await _db.deviceById(id);
    if (row == null) {
      try {
        await refresh();
      } catch (_) {
        return null;
      }
      row = await _db.deviceById(id);
    }
    return _verified(row);
  }

  /// Verified, non-revoked devices of [userIds]: the ones that get wraps.
  Future<List<VerifiedDevice>> liveDevices(Iterable<String> userIds) async => [
        for (final d in await _db.devicesOf(userIds.toSet()))
          if (!d.revoked) ?_verified(d),
      ];

  /// The user's identity key differs from the one first seen (or last acknowledged).
  Future<bool> identityChanged(String userId) async {
    final u = await _db.userById(userId);
    return u != null && u.identityPub != u.trustedIdentityPub;
  }

  Future<void> acknowledgeIdentity(String userId) async {
    final u = await _db.userById(userId);
    if (u != null) await _db.putUser(u.copyWith(trustedIdentityPub: u.identityPub));
  }
}
