// The family directory: users, their devices' public keys, and which of them to trust.
// Identity keys are trusted on first use; a later change is accepted (admin resets are real)
// but flagged until the user acknowledges it. A device is usable only if its certificate
// verifies against its user's identity key — for this user, against the local identity key.
import 'dart:async';
import 'dart:convert';
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
  const VerifiedDevice({
    required this.id,
    required this.userId,
    required this.encPub,
    required this.signPub,
    required this.revoked,
    required this.trusted,
  });
  final String id, userId;
  final Uint8List encPub, signPub;
  final bool revoked;

  /// Certified by an identity key this device trusts. False for a key that changed and hasn't
  /// been acknowledged yet: such a device verifies but gets no keys and isn't believed.
  final bool trusted;
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
      final mine = u.id == _me.userId;
      // My own devices must chain to the key I hold; others' to a key trusted before (first seen
      // or acknowledged). A device under a new, unacknowledged key verifies but isn't trusted.
      final trusted = mine ? myPub : (old?.trustedIdentityPub ?? u.identityPub);
      final known = mine ? {myPub} : {..._known(old), trusted};
      await _db.putUser(UserRow(
        id: u.id,
        name: u.name,
        isAdmin: u.isAdmin,
        identityPub: mine ? myPub : u.identityPub,
        trustedIdentityPub: trusted,
        knownIdentityPubs: jsonEncode(known.toList()),
      ));
      for (final d in u.devices) {
        var isTrusted = false;
        for (final k in known) {
          if (await _certValid(k, d.encPub, d.signPub, d.certSig)) {
            isTrusted = true;
            break;
          }
        }
        final valid = isTrusted || (!mine && await _certValid(u.identityPub, d.encPub, d.signPub, d.certSig));
        await _db.putDevice(DeviceRow(
          id: d.id,
          userId: u.id,
          name: d.name,
          encPub: d.encPub,
          signPub: d.signPub,
          certSig: d.certSig,
          revoked: d.revoked,
          certValid: valid,
          trusted: isTrusted,
        ));
      }
    }
  }

  static Set<String> _known(UserRow? u) {
    if (u == null) return {};
    try {
      return {...(jsonDecode(u.knownIdentityPubs) as List).cast<String>()};
    } on FormatException {
      return {};
    }
  }

  static Future<bool> _certValid(String identityPub, String encPub, String signPub, String certSig) async {
    try {
      return await verifyDeviceCert(DeviceCert(
        b64urlDecode(identityPub),
        b64urlDecode(encPub),
        b64urlDecode(signPub),
        b64urlDecode(certSig),
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
      trusted: d.trusted,
    );
  }

  /// The device if its certificate verifies (revoked devices included, for old signatures).
  /// An unknown id refreshes the directory once; a failed refresh throws (the caller retries
  /// later instead of treating the device as fake).
  Future<VerifiedDevice?> device(String id) async {
    var row = await _db.deviceById(id);
    if (row == null) {
      await refresh();
      row = await _db.deviceById(id);
    }
    return _verified(row);
  }

  /// Trusted, non-revoked devices of [userIds]: the ones that get wraps.
  Future<List<VerifiedDevice>> liveDevices(Iterable<String> userIds) async => [
        for (final d in await _db.devicesOf(userIds.toSet()))
          if (!d.revoked && d.trusted) ?_verified(d),
      ];

  /// The user's identity key differs from the one first seen (or last acknowledged).
  Future<bool> identityChanged(String userId) async {
    final u = await _db.userById(userId);
    return u != null && u.identityPub != u.trustedIdentityPub;
  }

  /// Trusts the user's current identity key (after the banner's OK) and the devices it certifies.
  Future<void> acknowledgeIdentity(String userId) async {
    final u = await _db.userById(userId);
    if (u == null) return;
    final known = {..._known(u), u.identityPub};
    await _db.putUser(u.copyWith(trustedIdentityPub: u.identityPub, knownIdentityPubs: jsonEncode(known.toList())));
    for (final d in await _db.devicesOf([userId])) {
      if (!d.trusted && await _certValid(u.identityPub, d.encPub, d.signPub, d.certSig)) {
        await _db.putDevice(d.copyWith(trusted: true, certValid: true));
      }
    }
  }
}
