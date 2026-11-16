// The pairing code a new device shows (docs/protocol.md "Pairing a new device"): a 4-character
// lookup code from the server and a 12-character secret that never leaves the two devices,
// typed as XXXX-XXXX-XXXX-XXXX or scanned from a QR that also carries the ephemeral public key.
// In reverse pairing a signed-in device shows the same kind of code (its offer's lookup code and a
// secret) in a `famchat-link` QR, and the new device scans or types it.
import 'dart:math';
import 'dart:typed_data';

import '../crypto/encoding.dart';

/// Crockford base32 (no I, L, O, U).
const pairAlphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

const _lookupLength = 4, _secretLength = 12;
final _compact = RegExp(r'^[0-9A-HJKMNP-TV-Z]{16}$');

class PairCode {
  const PairCode(this.lookup, this.secret);

  /// The server's lookup code (4 characters).
  final String lookup;

  /// The shared secret S (12 characters, 60 bits). Never sent to the server.
  final String secret;

  String get compact => '$lookup$secret';

  String get display => [for (var i = 0; i < 16; i += 4) compact.substring(i, i + 4)].join('-');

  /// Accepts any case, spaces and dashes, and `O`→`0`, `I`/`L`→`1`. Null unless exactly 16 code characters.
  static PairCode? parse(String input) {
    final s = input
        .toUpperCase()
        .replaceAll(RegExp(r'[\s-]'), '')
        .replaceAll('O', '0')
        .replaceAll(RegExp('[IL]'), '1');
    if (!_compact.hasMatch(s)) return null;
    return PairCode(s.substring(0, _lookupLength), s.substring(_lookupLength));
  }
}

/// A fresh 12-character secret.
String newPairSecret([Random? random]) {
  final r = random ?? Random.secure();
  return String.fromCharCodes(List.generate(_secretLength, (_) => pairAlphabet.codeUnitAt(r.nextInt(32))));
}

/// What the QR holds: `famchat-pair:1:<16-char code>:<ephPub base64url>`.
class PairQr {
  const PairQr(this.code, this.ephPub);
  final PairCode code;
  final Uint8List ephPub;

  static const prefix = 'famchat-pair:1:';

  String encode() => '$prefix${code.compact}:${b64url(ephPub)}';

  static PairQr? parse(String text) {
    final t = text.trim();
    if (!t.startsWith(prefix)) return null;
    final parts = t.substring(prefix.length).split(':');
    if (parts.length != 2 || !_compact.hasMatch(parts[0])) return null;
    try {
      final eph = b64urlDecode(parts[1]);
      if (eph.length != 32) return null;
      return PairQr(PairCode.parse(parts[0])!, eph);
    } on CryptoFailure {
      return null;
    }
  }
}

/// A scanned QR (with its ephemeral key) or a typed code (without), or null.
({PairCode code, Uint8List? ephPub})? parsePairInput(String input) {
  final qr = PairQr.parse(input);
  if (qr != null) return (code: qr.code, ephPub: qr.ephPub);
  final code = PairCode.parse(input);
  return code == null ? null : (code: code, ephPub: null);
}

/// What a signed-in device's QR holds for reverse pairing: `famchat-link:1:<16-char code>`.
class LinkQr {
  const LinkQr(this.code);
  final PairCode code;

  static const prefix = 'famchat-link:1:';

  String encode() => '$prefix${code.compact}';

  static LinkQr? parse(String text) {
    final t = text.trim();
    if (!t.startsWith(prefix)) return null;
    final rest = t.substring(prefix.length);
    return _compact.hasMatch(rest) ? LinkQr(PairCode.parse(rest)!) : null;
  }
}

/// On a new device: a scanned link QR or a typed code, or null.
PairCode? parseLinkInput(String input) => LinkQr.parse(input)?.code ?? PairCode.parse(input);
