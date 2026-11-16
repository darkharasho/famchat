// Spike proposal for FamChat's crypto formats. Plan 3 finalises them with test vectors.
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

const _certContext = 'famchat-device-cert-v1';
const _sealedBoxInfo = 'famchat-sealed-box-v1';

final _ed25519 = Ed25519();
final _x25519 = X25519();
final _aead = Xchacha20.poly1305Aead();
final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

/// base64url without padding.
String b64url(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

Uint8List b64urlDecode(String s) => base64Url.decode(s.padRight((s.length + 3) & ~3, '='));

/// UTF-8 "famchat-device-cert-v1" ‖ encPub ‖ signPub.
Future<Uint8List> deviceCertMessage(List<int> encPub, List<int> signPub) async {
  if (encPub.length != 32 || signPub.length != 32) {
    throw ArgumentError('public keys must be 32 bytes');
  }
  return Uint8List.fromList([...utf8.encode(_certContext), ...encPub, ...signPub]);
}

Future<({String identityPub, String encPub, String signPub, String certSig})> makeDeviceCert({
  required SimpleKeyPair identity,
  required SimpleKeyPair enc,
  required SimpleKeyPair sign,
}) async {
  final identityPub = (await identity.extractPublicKey()).bytes;
  final encPub = (await enc.extractPublicKey()).bytes;
  final signPub = (await sign.extractPublicKey()).bytes;
  final sig = await _ed25519.sign(await deviceCertMessage(encPub, signPub), keyPair: identity);
  return (
    identityPub: b64url(identityPub),
    encPub: b64url(encPub),
    signPub: b64url(signPub),
    certSig: b64url(sig.bytes),
  );
}

Future<SecretKey> _boxKey(SimpleKeyPair own, List<int> otherPub, List<int> ephPub, List<int> recipientPub) async {
  final shared = await _x25519.sharedSecretKey(
    keyPair: own,
    remotePublicKey: SimplePublicKey(otherPub, type: KeyPairType.x25519),
  );
  return _hkdf.deriveKey(
    secretKey: shared,
    nonce: [...ephPub, ...recipientPub],
    info: utf8.encode(_sealedBoxInfo),
  );
}

/// Sealed box: ephPub(32) ‖ nonce(24) ‖ ciphertext ‖ mac(16).
Future<Uint8List> sealBox(List<int> recipientPub, List<int> plaintext) async {
  final eph = await _x25519.newKeyPair();
  final ephPub = (await eph.extractPublicKey()).bytes;
  final key = await _boxKey(eph, recipientPub, ephPub, recipientPub);
  final box = await _aead.encrypt(plaintext, secretKey: key);
  return Uint8List.fromList([...ephPub, ...box.nonce, ...box.cipherText, ...box.mac.bytes]);
}

Future<Uint8List> openBox(SimpleKeyPair recipient, List<int> sealed) async {
  if (sealed.length < 32 + 24 + 16) throw ArgumentError('sealed box too short');
  final ephPub = sealed.sublist(0, 32);
  final recipientPub = (await recipient.extractPublicKey()).bytes;
  final key = await _boxKey(recipient, ephPub, ephPub, recipientPub);
  final box = SecretBox(
    sealed.sublist(56, sealed.length - 16),
    nonce: sealed.sublist(32, 56),
    mac: Mac(sealed.sublist(sealed.length - 16)),
  );
  return Uint8List.fromList(await _aead.decrypt(box, secretKey: key));
}

List<int> _aad(String chatId, String messageId, String senderDeviceId) =>
    utf8.encode('$chatId|$messageId|$senderDeviceId');

/// Envelope {v:1, epoch, nonce, ct, sig}; ct includes the 16-byte MAC; sig = Ed25519(ct ‖ aad).
Future<Map<String, Object>> encryptEnvelope({
  required List<int> chatKey,
  required int epoch,
  required String chatId,
  required String messageId,
  required String senderDeviceId,
  required SimpleKeyPair signKey,
  required List<int> plaintext,
}) async {
  final aad = _aad(chatId, messageId, senderDeviceId);
  final box = await _aead.encrypt(plaintext, secretKey: SecretKey(chatKey), aad: aad);
  final ct = [...box.cipherText, ...box.mac.bytes];
  final sig = await _ed25519.sign([...ct, ...aad], keyPair: signKey);
  return {'v': 1, 'epoch': epoch, 'nonce': b64url(box.nonce), 'ct': b64url(ct), 'sig': b64url(sig.bytes)};
}

/// Verifies the signature, then decrypts. Throws on any failure.
Future<Uint8List> decryptEnvelope({
  required List<int> chatKey,
  required String chatId,
  required String messageId,
  required String senderDeviceId,
  required List<int> senderSignPub,
  required Map<String, Object?> envelope,
}) async {
  if (envelope['v'] != 1) throw const FormatException('unsupported envelope version');
  final aad = _aad(chatId, messageId, senderDeviceId);
  final ct = b64urlDecode(envelope['ct'] as String);
  final ok = await _ed25519.verify(
    [...ct, ...aad],
    signature: Signature(
      b64urlDecode(envelope['sig'] as String),
      publicKey: SimplePublicKey(senderSignPub, type: KeyPairType.ed25519),
    ),
  );
  if (!ok) throw const FormatException('bad envelope signature');
  if (ct.length < 16) throw const FormatException('ciphertext too short');
  final box = SecretBox(
    ct.sublist(0, ct.length - 16),
    nonce: b64urlDecode(envelope['nonce'] as String),
    mac: Mac(ct.sublist(ct.length - 16)),
  );
  return Uint8List.fromList(await _aead.decrypt(box, secretKey: SecretKey(chatKey), aad: aad));
}
