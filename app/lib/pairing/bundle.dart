// The history handover a new device gets when it is paired: the user's identity key, its own
// certificate, every chat key the approving device holds, and that device's trust-on-first-use
// state for the other users (docs/protocol.md "Pairing a new device").
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../chat/db/chat_db.dart';
import '../crypto/device_cert.dart';
import '../crypto/encoding.dart';
import '../crypto/keys.dart';

class HandoverKey {
  const HandoverKey({required this.chatId, required this.epoch, required this.key});
  final String chatId;
  final int epoch;
  final Uint8List key;
}

/// Another user's identity key as the approving device trusts it.
class TrustedIdentity {
  const TrustedIdentity({required this.userId, required this.trustedIdentityPub, required this.known});
  final String userId, trustedIdentityPub;

  /// Every identity key trusted for the user so far (base64url).
  final List<String> known;
}

class PairBundle {
  const PairBundle({
    required this.userId,
    required this.deviceId,
    required this.identitySeed,
    required this.certSig,
    required this.keys,
    required this.trust,
  });

  final String userId, deviceId;
  final Uint8List identitySeed, certSig;
  final List<HandoverKey> keys;
  final List<TrustedIdentity> trust;

  static const version = 1;

  Uint8List encode() => utf8.encode(jsonEncode({
        'v': version,
        'userId': userId,
        'deviceId': deviceId,
        'identitySeed': b64url(identitySeed),
        'certSig': b64url(certSig),
        'keys': [
          for (final k in keys) {'chatId': k.chatId, 'epoch': k.epoch, 'key': b64url(k.key)},
        ],
        'trust': [
          for (final t in trust) {'userId': t.userId, 'trustedIdentityPub': t.trustedIdentityPub, 'known': t.known},
        ],
      }));

  /// Throws [CryptoFailure] for anything but a well-formed version-1 bundle.
  static PairBundle decode(List<int> bytes) {
    final Object? raw;
    try {
      raw = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      throw const CryptoFailure('bundle is not JSON');
    }
    if (raw is! Map<String, Object?> || raw['v'] != version) throw const CryptoFailure('unknown bundle version');
    final j = raw;
    List<Map<String, Object?>> list(String k) {
      final v = j[k];
      if (v is! List || v.any((x) => x is! Map<String, Object?>)) throw CryptoFailure('bad $k');
      return v.cast<Map<String, Object?>>();
    }

    return PairBundle(
      userId: jsonString(j, 'userId'),
      deviceId: jsonString(j, 'deviceId'),
      identitySeed: jsonBytes(j, 'identitySeed', length: 32),
      certSig: jsonBytes(j, 'certSig', length: 64),
      keys: [
        for (final k in list('keys'))
          HandoverKey(chatId: jsonString(k, 'chatId'), epoch: jsonU32(k, 'epoch'), key: jsonBytes(k, 'key', length: 32)),
      ],
      trust: [
        for (final t in list('trust'))
          TrustedIdentity(
            userId: jsonString(t, 'userId'),
            trustedIdentityPub: jsonString(t, 'trustedIdentityPub'),
            known: switch (t['known']) {
              final List<Object?> l when l.every((x) => x is String) => l.cast<String>(),
              _ => throw const CryptoFailure('bad known'),
            },
          ),
      ],
    );
  }
}

/// On the approving device: everything the new device ([deviceId], with [encPub]/[signPub]) needs.
Future<PairBundle> buildHandover({
  required ChatDb db,
  required String userId,
  required String deviceId,
  required SimpleKeyPair identity,
  required List<int> encPub,
  required List<int> signPub,
}) async =>
    PairBundle(
      userId: userId,
      deviceId: deviceId,
      identitySeed: await seedOf(identity),
      certSig: await signCertFor(identity: identity, encPub: encPub, signPub: signPub),
      keys: [for (final k in await db.allKeys()) HandoverKey(chatId: k.chatId, epoch: k.epoch, key: k.key)],
      trust: [
        for (final u in await db.allUsers())
          if (u.id != userId)
            TrustedIdentity(userId: u.id, trustedIdentityPub: u.trustedIdentityPub, known: _known(u)),
      ],
    );

List<String> _known(UserRow u) {
  try {
    return {...(jsonDecode(u.knownIdentityPubs) as List).cast<String>(), u.trustedIdentityPub}.toList();
  } on Object {
    return [u.trustedIdentityPub];
  }
}

/// The identity key from a verified bundle.
class VerifiedHandover {
  const VerifiedHandover(this.identity, this.identityPub);
  final SimpleKeyPair identity;
  final Uint8List identityPub;
}

/// On the new device: the bundle is for this user and device, and its certificate covers this
/// device's own keys under the identity key it carries. Throws [CryptoFailure] otherwise.
Future<VerifiedHandover> verifyHandover(
  PairBundle b, {
  required String userId,
  required String deviceId,
  required List<int> encPub,
  required List<int> signPub,
}) async {
  if (b.userId != userId || b.deviceId != deviceId) throw const CryptoFailure('bundle is for another device');
  final identity = await newIdentityKey(seed: b.identitySeed);
  final identityPub = await publicKeyOf(identity);
  final ok = await verifyDeviceCert(
      DeviceCert(identityPub, Uint8List.fromList(encPub), Uint8List.fromList(signPub), b.certSig));
  if (!ok) throw const CryptoFailure('certificate does not cover this device');
  return VerifiedHandover(identity, identityPub);
}

/// On the new device, before its session is saved: binds the database to the device, stores the
/// chat keys and seeds trust for other users (a later directory refresh keeps it).
Future<void> installHandover(ChatDb db, PairBundle b) async {
  await db.bindDevice(b.deviceId);
  await db.transaction(() async {
    for (final k in b.keys) {
      await db.putKey(k.chatId, k.epoch, k.key);
    }
    for (final t in b.trust) {
      final existing = await db.userById(t.userId);
      final known = {...t.known, t.trustedIdentityPub}.toList();
      await db.putUser(existing?.copyWith(trustedIdentityPub: t.trustedIdentityPub, knownIdentityPubs: jsonEncode(known)) ??
          UserRow(
            id: t.userId,
            name: '',
            isAdmin: false,
            identityPub: t.trustedIdentityPub,
            trustedIdentityPub: t.trustedIdentityPub,
            knownIdentityPubs: jsonEncode(known),
          ));
    }
  });
}
