// Pairing crypto (docs/protocol.md "Pairing a new device"). The new device and the approving device
// share a short secret S that never reaches the server: the new device MACs its keys with it, and
// the approving device binds the sealed bundle to it, so the server can neither swap the keys nor
// forge a bundle.
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:meta/meta.dart';

import 'encoding.dart';
import 'sealed_box.dart';

final _hmac = Hmac.sha256();
final _bundleInfo = utf8.encode(domainPairBundle);

Uint8List _keysMessage(List<int> ephPub, List<int> encPub, List<int> signPub, String deviceName, String platform) {
  if (ephPub.length != 32 || encPub.length != 32 || signPub.length != 32) {
    throw ArgumentError('public keys must be 32 bytes');
  }
  return (ByteWriter(domainPairKeys)
        ..bytes(ephPub)
        ..bytes(encPub)
        ..bytes(signPub)
        ..str(deviceName)
        ..str(platform))
      .finish();
}

/// HMAC-SHA256(UTF-8(secret), "famchat-pair-keys-v1" ‖ ephPub ‖ encPub ‖ signPub ‖ str(deviceName) ‖ str(platform)).
Future<Uint8List> pairKeysMac({
  required String secret,
  required List<int> ephPub,
  required List<int> encPub,
  required List<int> signPub,
  required String deviceName,
  required String platform,
}) async {
  final mac = await _hmac.calculateMac(
    _keysMessage(ephPub, encPub, signPub, deviceName, platform),
    secretKey: SecretKey(utf8.encode(secret)),
  );
  return Uint8List.fromList(mac.bytes);
}

/// True if [mac] is [pairKeysMac] of these fields. Constant-time compare; never throws.
Future<bool> checkPairKeysMac({
  required String secret,
  required List<int> ephPub,
  required List<int> encPub,
  required List<int> signPub,
  required String deviceName,
  required String platform,
  required List<int> mac,
}) async {
  final Uint8List want;
  try {
    want = await pairKeysMac(
        secret: secret, ephPub: ephPub, encPub: encPub, signPub: signPub, deviceName: deviceName, platform: platform);
  } on ArgumentError {
    return false;
  }
  if (mac.length != want.length) return false;
  var diff = 0;
  for (var i = 0; i < want.length; i++) {
    diff |= want[i] ^ mac[i];
  }
  return diff == 0;
}

/// Seals [plaintext] to the new device's ephemeral key, bound to [secret]
/// (info "famchat-pair-bundle-v1"). Throws [CryptoFailure] for a bad or low-order key.
Future<Uint8List> sealPairBundle({
  required List<int> recipientEphPub,
  required String secret,
  required List<int> plaintext,
  @visibleForTesting SimpleKeyPair? ephemeral,
  @visibleForTesting List<int>? nonce,
}) =>
    sealBoxBound(
      recipientEphPub,
      plaintext,
      info: _bundleInfo,
      secret: utf8.encode(secret),
      // ignore: invalid_use_of_visible_for_testing_member
      ephemeral: ephemeral,
      // ignore: invalid_use_of_visible_for_testing_member
      nonce: nonce,
    );

/// Opens a bundle with the new device's ephemeral key and [secret]. Throws [CryptoFailure] if it
/// was made without the secret, for another key, or was changed.
Future<Uint8List> openPairBundle({required SimpleKeyPair eph, required String secret, required List<int> sealed}) =>
    openBoxBound(eph, sealed, info: _bundleInfo, secret: utf8.encode(secret));
