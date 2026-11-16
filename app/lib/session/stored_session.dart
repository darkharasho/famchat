// What a signed-in device keeps between launches.
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:meta/meta.dart';

import '../crypto/encoding.dart';
import '../crypto/keys.dart';
import 'secure_kv.dart';

@immutable
class StoredSession {
  const StoredSession({
    required this.userId,
    required this.deviceId,
    required this.deviceName,
    required this.refreshToken,
    required this.isAdmin,
    required this.name,
    required this.identitySeed,
    required this.encSeed,
    required this.signSeed,
  });

  final String userId, deviceId, deviceName, refreshToken;
  final bool isAdmin;

  /// The user's display name; null until `GET /api/me` has answered once.
  final String? name;

  /// Base64url 32-byte seeds.
  final String identitySeed, encSeed, signSeed;

  static const version = 1;

  Map<String, Object?> toJson() => {
        'v': version,
        'userId': userId,
        'deviceId': deviceId,
        'deviceName': deviceName,
        'refreshToken': refreshToken,
        'isAdmin': isAdmin,
        'name': name,
        'identitySeed': identitySeed,
        'encSeed': encSeed,
        'signSeed': signSeed,
      };

  /// Throws [FormatException] on a missing or mistyped field or an unknown version.
  factory StoredSession.fromJson(Map<String, Object?> j) {
    if (j['v'] != version) throw const FormatException('unknown session version');
    String s(String k) {
      final v = j[k];
      if (v is String && v.isNotEmpty) return v;
      throw FormatException('bad $k');
    }

    final isAdmin = j['isAdmin'], name = j['name'];
    if (isAdmin is! bool) throw const FormatException('bad isAdmin');
    if (name != null && name is! String) throw const FormatException('bad name');
    return StoredSession(
      userId: s('userId'),
      deviceId: s('deviceId'),
      deviceName: s('deviceName'),
      refreshToken: s('refreshToken'),
      isAdmin: isAdmin,
      name: name as String?,
      identitySeed: s('identitySeed'),
      encSeed: s('encSeed'),
      signSeed: s('signSeed'),
    );
  }

  StoredSession copyWith({String? refreshToken, bool? isAdmin, String? name}) => StoredSession(
        userId: userId,
        deviceId: deviceId,
        deviceName: deviceName,
        refreshToken: refreshToken ?? this.refreshToken,
        isAdmin: isAdmin ?? this.isAdmin,
        name: name ?? this.name,
        identitySeed: identitySeed,
        encSeed: encSeed,
        signSeed: signSeed,
      );

  Future<SimpleKeyPair> identityKey() => newIdentityKey(seed: b64urlDecode(identitySeed));

  Future<DeviceKeys> deviceKeys() => DeviceKeys.fromStorage({'encSeed': encSeed, 'signSeed': signSeed});
}

/// The session as one JSON blob, so a token rotation rewrites it atomically.
class SessionStore {
  SessionStore(this._kv);

  final SecureKv _kv;

  static const key = 'famchat.session.v1';

  /// Null when there is no session or the blob can't be parsed. Storage errors propagate.
  Future<StoredSession?> load() async {
    final raw = await _kv.read(key);
    if (raw == null) return null;
    try {
      final j = jsonDecode(raw);
      if (j is! Map<String, Object?>) return null;
      return StoredSession.fromJson(j);
    } on FormatException {
      return null;
    }
  }

  Future<void> save(StoredSession s) => _kv.write(key, jsonEncode(s.toJson()));

  Future<void> clear() => _kv.delete(key);
}
