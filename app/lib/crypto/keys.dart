// Identity, device and chat keys.
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'encoding.dart';

final _ed25519 = Ed25519();
final _x25519 = X25519();

/// A user identity key (Ed25519). [seed] is for tests and pairing only.
Future<SimpleKeyPair> newIdentityKey({List<int>? seed}) =>
    seed == null ? _ed25519.newKeyPair() : _ed25519.newKeyPairFromSeed(seed);

Future<Uint8List> publicKeyOf(SimpleKeyPair k) async =>
    Uint8List.fromList((await k.extractPublicKey()).bytes);

Future<Uint8List> seedOf(SimpleKeyPair k) async => Uint8List.fromList(await k.extractPrivateKeyBytes());

/// A fresh 32-byte chat key for one epoch.
Uint8List newChatKey() {
  final r = Random.secure();
  return Uint8List.fromList(List.generate(32, (_) => r.nextInt(256)));
}

/// A device's keys: X25519 [enc] receives wrapped chat keys, Ed25519 [sign] signs.
class DeviceKeys {
  DeviceKeys(this.enc, this.sign);

  final SimpleKeyPair enc;
  final SimpleKeyPair sign;

  static Future<DeviceKeys> generate() async =>
      DeviceKeys(await _x25519.newKeyPair(), await _ed25519.newKeyPair());

  /// Seeds as base64url, for secure storage.
  Future<Map<String, String>> toStorage() async =>
      {'encSeed': b64url(await seedOf(enc)), 'signSeed': b64url(await seedOf(sign))};

  /// Throws [CryptoFailure] if a seed is missing or not 32 bytes.
  static Future<DeviceKeys> fromStorage(Map<String, String> m) async {
    final encSeed = _seed(m['encSeed']), signSeed = _seed(m['signSeed']);
    return DeviceKeys(await _x25519.newKeyPairFromSeed(encSeed), await _ed25519.newKeyPairFromSeed(signSeed));
  }

  static Uint8List _seed(String? s) {
    if (s == null) throw const CryptoFailure('missing seed');
    final b = b64urlDecode(s);
    if (b.length != 32) throw const CryptoFailure('seed must be 32 bytes');
    return b;
  }

  Future<Uint8List> encPub() => publicKeyOf(enc);
  Future<Uint8List> signPub() => publicKeyOf(sign);
}
