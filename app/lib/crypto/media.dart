// Media blobs (photos, thumbnails, later voice): each message's media gets a fresh random key, which
// travels inside the encrypted message with the SHA-256 of every blob. R2 holds only these blobs.
//   blob = nonce(24) ‖ ct ‖ mac(16)
//   ct   = XChaCha20-Poly1305(key, nonce, plaintext, aad)
//   aad  = "famchat-media-v1" ‖ str(purpose)          purpose: "file" | "thumb"
//
// Single-shot, not chunked: blobs are capped at 16 MiB (photos ≤ 15 MiB, voice ≤ 8 MiB) and are held
// in memory whole anyway (hash check before decrypting, then Image.memory / the audio player).
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:meta/meta.dart';

import 'encoding.dart';

final _aead = Xchacha20.poly1305Aead();
final _sha256 = Sha256();
final _random = Random.secure();

const mediaDomain = 'famchat-media-v1';

/// nonce + MAC.
const mediaOverhead = 24 + 16;

/// Largest blob encrypted or decrypted.
const maxMediaBlobBytes = 16 * 1024 * 1024;

/// What a blob is, bound into its AAD so the server can't swap a thumbnail for the file.
enum MediaPurpose { file, thumb }

Uint8List newMediaKey() => Uint8List.fromList(List.generate(32, (_) => _random.nextInt(256)));

Uint8List mediaAad(MediaPurpose purpose) => (ByteWriter(mediaDomain)..str(purpose.name)).finish();

Future<Uint8List> encryptMedia({
  required List<int> key,
  required List<int> plaintext,
  required MediaPurpose purpose,
  @visibleForTesting List<int>? nonce,
}) async {
  if (key.length != 32) throw ArgumentError('media key must be 32 bytes');
  if (plaintext.length + mediaOverhead > maxMediaBlobBytes) throw ArgumentError('media too large');
  final box = await _aead.encrypt(plaintext, secretKey: SecretKey(key), nonce: nonce, aad: mediaAad(purpose));
  final out = Uint8List(box.nonce.length + box.cipherText.length + 16)
    ..setAll(0, box.nonce)
    ..setAll(24, box.cipherText)
    ..setAll(24 + box.cipherText.length, box.mac.bytes);
  return out;
}

/// Throws [CryptoFailure] for a bad key, a short or oversized blob, or a blob that doesn't open
/// under [key] for [purpose].
Future<Uint8List> decryptMedia({
  required List<int> key,
  required List<int> blob,
  required MediaPurpose purpose,
}) async {
  if (key.length != 32) throw const CryptoFailure('media key must be 32 bytes');
  if (blob.length < mediaOverhead || blob.length > maxMediaBlobBytes) throw const CryptoFailure('bad media blob size');
  final b = blob is Uint8List ? blob : Uint8List.fromList(blob);
  final box = SecretBox(
    Uint8List.sublistView(b, 24, b.length - 16),
    nonce: Uint8List.sublistView(b, 0, 24),
    mac: Mac(Uint8List.sublistView(b, b.length - 16)),
  );
  try {
    return Uint8List.fromList(await _aead.decrypt(box, secretKey: SecretKey(key), aad: mediaAad(purpose)));
  } catch (_) {
    throw const CryptoFailure('media does not decrypt');
  }
}

Future<Uint8List> sha256Of(List<int> bytes) async => Uint8List.fromList((await _sha256.hash(bytes)).bytes);

/// Whether SHA-256([bytes]) equals [expected] (compared in constant time).
Future<bool> sha256Matches(List<int> bytes, List<int> expected) async {
  final h = await sha256Of(bytes);
  if (expected.length != h.length) return false;
  var diff = 0;
  for (var i = 0; i < h.length; i++) {
    diff |= h[i] ^ expected[i];
  }
  return diff == 0;
}
