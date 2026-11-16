// Shared encoding helpers for FamChat's crypto formats.
import 'dart:convert';
import 'dart:typed_data';

// Domain strings. Every byte string FamChat signs, MACs or derives a key from starts with its own
// domain string, so a signature or key made for one purpose can never be read as another.
// RULE: no domain string may be a prefix of another (a prefix would let one kind's bytes parse as
// the other's). Add every new one to [famchatDomains]; a test checks the rule.
const domainDeviceCert = 'famchat-device-cert-v1';
const domainWrap = 'famchat-wrap-v1';
const domainEnvelope = 'famchat-envelope-v1';
const domainSealedBox = 'famchat-sealed-box-v1';
const domainPairKeys = 'famchat-pair-keys-v1';
const domainPairBundle = 'famchat-pair-bundle-v1';
const domainMedia = 'famchat-media-v1';
const domainReset = 'famchat-reset-v1';
const domainResetClaim = 'famchat-reset-claim-v1';
const domainRecoveryKey = 'famchat-recovery-key-v1';
const domainRecoverySeed = 'famchat-recovery-seed-v1';
const domainAdmin = 'famchat-admin-v1';

const famchatDomains = [
  domainAdmin,
  domainReset,
  domainResetClaim,
  domainRecoveryKey,
  domainRecoverySeed,
  domainDeviceCert,
  domainWrap,
  domainEnvelope,
  domainSealedBox,
  domainPairKeys,
  domainPairBundle,
  domainMedia,
];

/// Thrown for every failure to verify, open, decrypt or parse crypto data.
class CryptoFailure implements Exception {
  const CryptoFailure(this.reason);
  final String reason;

  @override
  String toString() => 'CryptoFailure: $reason';
}

final _b64urlChars = RegExp(r'^[A-Za-z0-9_-]*$');

/// base64url without padding.
String b64url(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

/// Decodes base64url without padding. Throws [CryptoFailure] on anything else.
Uint8List b64urlDecode(String s) {
  if (!_b64urlChars.hasMatch(s) || s.length % 4 == 1) throw const CryptoFailure('bad base64');
  try {
    return base64Url.decode(s.padRight((s.length + 3) & ~3, '='));
  } on FormatException {
    throw const CryptoFailure('bad base64');
  }
}

/// Builds the byte strings FamChat signs or authenticates: a domain string as raw
/// UTF-8, then fields in order. Strings are u16be length ‖ UTF-8, integers are
/// big-endian, byte fields are raw (fixed-length, or last).
class ByteWriter {
  ByteWriter(String domain) {
    _b.add(utf8.encode(domain));
  }

  final _b = BytesBuilder(copy: false);

  void str(String s) {
    final bytes = utf8.encode(s);
    if (bytes.length > 0xffff) throw ArgumentError.value(s.length, 's', 'longer than 65535 UTF-8 bytes');
    _b
      ..addByte(bytes.length >> 8)
      ..addByte(bytes.length & 0xff)
      ..add(bytes);
  }

  void u8(int v) {
    if (v < 0 || v > 0xff) throw ArgumentError.value(v, 'v', 'not a u8');
    _b.addByte(v);
  }

  void u32(int v) {
    if (v < 0 || v > 0xffffffff) throw ArgumentError.value(v, 'v', 'not a u32');
    _b
      ..addByte((v >> 24) & 0xff)
      ..addByte((v >> 16) & 0xff)
      ..addByte((v >> 8) & 0xff)
      ..addByte(v & 0xff);
  }

  void bytes(List<int> b) => _b.add(b);

  Uint8List finish() => _b.toBytes();
}

/// Reads a base64url field from parsed JSON. Throws [CryptoFailure] if it is
/// missing, not a string, not base64url, or not [length] bytes long.
Uint8List jsonBytes(Map<String, Object?> j, String key, {int? length}) {
  final v = j[key];
  if (v is! String) throw CryptoFailure('missing or non-string $key');
  final b = b64urlDecode(v);
  if (length != null && b.length != length) throw CryptoFailure('$key must be $length bytes');
  return b;
}

/// Reads a string field from parsed JSON, or throws [CryptoFailure].
String jsonString(Map<String, Object?> j, String key) {
  final v = j[key];
  if (v is! String) throw CryptoFailure('missing or non-string $key');
  return v;
}

/// Reads a non-negative u32 field from parsed JSON, or throws [CryptoFailure].
int jsonU32(Map<String, Object?> j, String key) {
  final v = j[key];
  if (v is! int || v < 0 || v > 0xffffffff) throw CryptoFailure('missing or bad $key');
  return v;
}
