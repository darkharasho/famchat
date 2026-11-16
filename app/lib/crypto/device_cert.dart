// Device certificates: the user's identity key signs a device's public keys.
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'encoding.dart';
import 'keys.dart';

final _ed25519 = Ed25519();
final _certContext = utf8.encode(domainDeviceCert);

class DeviceCert {
  DeviceCert(this.identityPub, this.encPub, this.signPub, this.certSig);

  final Uint8List identityPub, encPub, signPub, certSig;

  /// Same field names as the server API.
  Map<String, String> toJson() => {
        'identityPub': b64url(identityPub),
        'encPub': b64url(encPub),
        'signPub': b64url(signPub),
        'certSig': b64url(certSig),
      };

  /// Throws [CryptoFailure] on a missing field, bad base64 or wrong length.
  factory DeviceCert.fromJson(Map<String, Object?> j) => DeviceCert(
        jsonBytes(j, 'identityPub', length: 32),
        jsonBytes(j, 'encPub', length: 32),
        jsonBytes(j, 'signPub', length: 32),
        jsonBytes(j, 'certSig', length: 64),
      );
}

/// UTF-8 "famchat-device-cert-v1" ‖ encPub ‖ signPub. Byte-identical to the
/// server's devicecert.ts, so it doesn't use ByteWriter's length prefixes.
Uint8List deviceCertMessage(List<int> encPub, List<int> signPub) {
  if (encPub.length != 32 || signPub.length != 32) throw ArgumentError('public keys must be 32 bytes');
  return Uint8List.fromList([..._certContext, ...encPub, ...signPub]);
}

Future<DeviceCert> signDeviceCert({required SimpleKeyPair identity, required DeviceKeys device}) async {
  final encPub = await device.encPub(), signPub = await device.signPub();
  final sig = await signCertFor(identity: identity, encPub: encPub, signPub: signPub);
  return DeviceCert(await publicKeyOf(identity), encPub, signPub, sig);
}

/// The cert signature for another device's public keys (pairing: the approving device certifies
/// the new one).
Future<Uint8List> signCertFor({required SimpleKeyPair identity, required List<int> encPub, required List<int> signPub}) async =>
    Uint8List.fromList((await _ed25519.sign(deviceCertMessage(encPub, signPub), keyPair: identity)).bytes);

/// True if [c.certSig] is [c.identityPub]'s signature over the cert message. Never throws.
Future<bool> verifyDeviceCert(DeviceCert c) async {
  if (c.identityPub.length != 32 || c.encPub.length != 32 || c.signPub.length != 32 || c.certSig.length != 64) {
    return false;
  }
  try {
    return await _ed25519.verify(
      deviceCertMessage(c.encPub, c.signPub),
      signature: Signature(c.certSig, publicKey: SimplePublicKey(c.identityPub, type: KeyPairType.ed25519)),
    );
  } catch (_) {
    return false;
  }
}
