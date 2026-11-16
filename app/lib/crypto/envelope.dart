// Message envelopes: XChaCha20-Poly1305 under the chat key, signed by the sender device.
//   aad = "famchat-envelope-v1" ‖ u8(v) ‖ str(chatId) ‖ u32(epoch) ‖ str(messageId) ‖ str(senderDeviceId)
//   ct  = XChaCha20-Poly1305(chatKey, nonce, plaintext, aad)   (includes the 16-byte MAC)
//   sig = Ed25519(senderSignKey, aad ‖ nonce ‖ ct)
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:meta/meta.dart';

import 'encoding.dart';

final _ed25519 = Ed25519();
final _aead = Xchacha20.poly1305Aead();

const envelopeVersion = 1;

class Envelope {
  Envelope({required this.v, required this.epoch, required this.nonce, required this.ct, required this.sig});

  final int v, epoch;
  final Uint8List nonce, ct, sig;

  Map<String, Object> toJson() =>
      {'v': v, 'epoch': epoch, 'nonce': b64url(nonce), 'ct': b64url(ct), 'sig': b64url(sig)};

  /// Throws [CryptoFailure] on a missing or mistyped field, bad base64, a nonce that
  /// isn't 24 bytes, ct shorter than the MAC or a signature that isn't 64 bytes.
  factory Envelope.fromJson(Map<String, Object?> j) {
    final v = j['v'];
    if (v is! int || v < 0 || v > 0xff) throw const CryptoFailure('missing or bad v');
    final ct = jsonBytes(j, 'ct');
    if (ct.length < 16) throw const CryptoFailure('ct shorter than the MAC');
    return Envelope(
      v: v,
      epoch: jsonU32(j, 'epoch'),
      nonce: jsonBytes(j, 'nonce', length: 24),
      ct: ct,
      sig: jsonBytes(j, 'sig', length: 64),
    );
  }
}

Uint8List envelopeAad({
  required int v,
  required String chatId,
  required int epoch,
  required String messageId,
  required String senderDeviceId,
}) =>
    (ByteWriter(domainEnvelope)
          ..u8(v)
          ..str(chatId)
          ..u32(epoch)
          ..str(messageId)
          ..str(senderDeviceId))
        .finish();

Future<Envelope> encryptEnvelope({
  required List<int> chatKey,
  required int epoch,
  required String chatId,
  required String messageId,
  required String senderDeviceId,
  required SimpleKeyPair signKey,
  required List<int> plaintext,
  @visibleForTesting List<int>? nonce,
}) async {
  if (chatKey.length != 32) throw ArgumentError('chat key must be 32 bytes');
  final aad = envelopeAad(
      v: envelopeVersion, chatId: chatId, epoch: epoch, messageId: messageId, senderDeviceId: senderDeviceId);
  final box = await _aead.encrypt(plaintext, secretKey: SecretKey(chatKey), nonce: nonce, aad: aad);
  final ct = Uint8List.fromList([...box.cipherText, ...box.mac.bytes]);
  final sig = await _ed25519.sign([...aad, ...box.nonce, ...ct], keyPair: signKey);
  return Envelope(
    v: envelopeVersion,
    epoch: epoch,
    nonce: Uint8List.fromList(box.nonce),
    ct: ct,
    sig: Uint8List.fromList(sig.bytes),
  );
}

/// Verifies the sender's signature, then decrypts. Throws [CryptoFailure] on any failure.
/// The caller picks [chatKey] by [Envelope.epoch].
Future<Uint8List> decryptEnvelope({
  required Envelope envelope,
  required List<int> chatKey,
  required String chatId,
  required String messageId,
  required String senderDeviceId,
  required List<int> senderSignPub,
}) async {
  final e = envelope;
  if (e.v != envelopeVersion) throw const CryptoFailure('unsupported envelope version');
  if (e.nonce.length != 24 || e.ct.length < 16 || e.sig.length != 64 || senderSignPub.length != 32) {
    throw const CryptoFailure('malformed envelope');
  }
  try {
    final aad = envelopeAad(
        v: e.v, chatId: chatId, epoch: e.epoch, messageId: messageId, senderDeviceId: senderDeviceId);
    final ok = await _ed25519.verify(
      [...aad, ...e.nonce, ...e.ct],
      signature: Signature(e.sig, publicKey: SimplePublicKey(senderSignPub, type: KeyPairType.ed25519)),
    );
    if (!ok) throw const CryptoFailure('bad envelope signature');
    final box = SecretBox(
      e.ct.sublist(0, e.ct.length - 16),
      nonce: e.nonce,
      mac: Mac(e.ct.sublist(e.ct.length - 16)),
    );
    return Uint8List.fromList(await _aead.decrypt(box, secretKey: SecretKey(chatKey), aad: aad));
  } on CryptoFailure {
    rethrow;
  } catch (_) {
    throw const CryptoFailure('envelope does not decrypt');
  }
}
