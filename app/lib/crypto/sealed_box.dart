// Sealed box: anonymous public-key encryption to one X25519 key.
// Format: ephPub(32) ‖ nonce(24) ‖ ciphertext ‖ mac(16).
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:meta/meta.dart';

import 'encoding.dart';

final _x25519 = X25519();
final _aead = Xchacha20.poly1305Aead();
final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
final _info = utf8.encode('famchat-sealed-box-v1');

const _overhead = 32 + 24 + 16;

/// key = HKDF-SHA256(X25519(own, other), salt = ephPub ‖ recipientPub, info).
/// Refuses an all-zero shared secret, which a low-order public key produces.
Future<SecretKey> _boxKey(SimpleKeyPair own, List<int> otherPub, List<int> ephPub, List<int> recipientPub) async {
  final List<int> shared;
  try {
    final k = await _x25519.sharedSecretKey(
      keyPair: own,
      remotePublicKey: SimplePublicKey(otherPub, type: KeyPairType.x25519),
    );
    shared = await k.extractBytes();
  } catch (_) {
    throw const CryptoFailure('low-order key');
  }
  if (shared.every((b) => b == 0)) throw const CryptoFailure('low-order key');
  return _hkdf.deriveKey(secretKey: SecretKey(shared), nonce: [...ephPub, ...recipientPub], info: _info);
}

/// Seals [plaintext] to [recipientPub]. Throws [CryptoFailure] for a bad or low-order key.
Future<Uint8List> sealBox(
  List<int> recipientPub,
  List<int> plaintext, {
  @visibleForTesting SimpleKeyPair? ephemeral,
  @visibleForTesting List<int>? nonce,
}) async {
  if (recipientPub.length != 32) throw const CryptoFailure('recipient key must be 32 bytes');
  final eph = ephemeral ?? await _x25519.newKeyPair();
  final ephPub = (await eph.extractPublicKey()).bytes;
  final key = await _boxKey(eph, recipientPub, ephPub, recipientPub);
  final box = await _aead.encrypt(plaintext, secretKey: key, nonce: nonce);
  return Uint8List.fromList([...ephPub, ...box.nonce, ...box.cipherText, ...box.mac.bytes]);
}

/// Opens a sealed box. Throws [CryptoFailure] on short input, a bad MAC or a low-order key.
Future<Uint8List> openBox(SimpleKeyPair recipient, List<int> sealed) async {
  if (sealed.length < _overhead) throw const CryptoFailure('sealed box too short');
  final ephPub = sealed.sublist(0, 32);
  final recipientPub = (await recipient.extractPublicKey()).bytes;
  final key = await _boxKey(recipient, ephPub, ephPub, recipientPub);
  final box = SecretBox(
    sealed.sublist(56, sealed.length - 16),
    nonce: sealed.sublist(32, 56),
    mac: Mac(sealed.sublist(sealed.length - 16)),
  );
  try {
    return Uint8List.fromList(await _aead.decrypt(box, secretKey: key));
  } catch (_) {
    throw const CryptoFailure('sealed box does not open');
  }
}
