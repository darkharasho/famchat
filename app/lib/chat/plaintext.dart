// What travels inside an envelope: UTF-8 JSON with a `kind`.
import 'dart:convert';
import 'dart:typed_data';

import '../crypto/encoding.dart';

const maxTextLength = 4000;

final _ulid = RegExp(r'^[0-9A-HJKMNP-TV-Z]{26}$');

/// The trimmed text if it can be sent (1–4000 characters), else null.
String? validMessageText(String s) {
  final t = s.trim();
  if (t.isEmpty || t.runes.length > maxTextLength) return null;
  return t;
}

sealed class Plaintext {
  const Plaintext();

  String get kind;

  Map<String, Object?> toJson();

  Uint8List encode() => Uint8List.fromList(utf8.encode(jsonEncode(toJson())));

  /// Throws [FormatException] for anything that isn't a JSON object with a string `kind`
  /// and the fields that kind needs. Unknown kinds become [UnknownBody].
  static Plaintext decode(List<int> bytes) {
    final Object? j;
    try {
      j = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      rethrow;
    } catch (e) {
      throw FormatException('bad plaintext: $e');
    }
    if (j is! Map<String, Object?>) throw const FormatException('plaintext is not an object');
    final kind = j['kind'];
    if (kind is! String) throw const FormatException('missing kind');
    switch (kind) {
      case 'text':
        final text = j['text'];
        if (text is! String || text.isEmpty) throw const FormatException('bad text');
        return TextBody(text);
      case 'reaction':
        final target = j['target'], emoji = j['emoji'];
        if (target is! String || target.isEmpty || emoji is! String || emoji.length > 32) {
          throw const FormatException('bad reaction');
        }
        return ReactionBody(target, emoji);
      case 'photo':
        return PhotoBody._fromJson(j);
      case 'voice':
        return VoiceBody._fromJson(j);
      default:
        return UnknownBody(kind, j);
    }
  }
}

class TextBody extends Plaintext {
  const TextBody(this.text);
  final String text;
  @override
  String get kind => 'text';
  @override
  Map<String, Object?> toJson() => {'kind': kind, 'text': text};
}

/// [emoji] empty removes the sender's reaction on [target].
class ReactionBody extends Plaintext {
  const ReactionBody(this.target, this.emoji);
  final String target, emoji;
  @override
  String get kind => 'reaction';
  @override
  Map<String, Object?> toJson() => {'kind': kind, 'target': target, 'emoji': emoji};
}

/// A photo: two encrypted blobs in R2 (the full JPEG and a thumbnail) under one fresh media [key]
/// (`lib/crypto/media.dart`), each pinned by the SHA-256 of its ciphertext.
class PhotoBody extends Plaintext {
  const PhotoBody({
    required this.mediaKey,
    required this.thumbKey,
    required this.key,
    required this.sha256,
    required this.thumbSha256,
    required this.width,
    required this.height,
    required this.bytes,
    this.mime = 'image/jpeg',
  });

  /// Media keys (`/api/media/:key`) of the full image and the thumbnail.
  final String mediaKey, thumbKey;

  /// The 32-byte media key, and SHA-256 of each encrypted blob.
  final Uint8List key, sha256, thumbSha256;

  /// Full image size in pixels, and its JPEG size in bytes.
  final int width, height, bytes;
  final String mime;

  @override
  String get kind => 'photo';

  @override
  Map<String, Object?> toJson() => {
        'kind': kind,
        'mediaKey': mediaKey,
        'thumbKey': thumbKey,
        'key': b64url(key),
        'sha256': b64url(sha256),
        'thumbSha256': b64url(thumbSha256),
        'width': width,
        'height': height,
        'bytes': bytes,
        'mime': mime,
      };

  factory PhotoBody._fromJson(Map<String, Object?> j) => PhotoBody(
        mediaKey: _mediaId(j, 'mediaKey'),
        thumbKey: _mediaId(j, 'thumbKey'),
        key: _bytes32(j, 'key'),
        sha256: _bytes32(j, 'sha256'),
        thumbSha256: _bytes32(j, 'thumbSha256'),
        width: _positive(j, 'width', 100000),
        height: _positive(j, 'height', 100000),
        bytes: _positive(j, 'bytes', 1 << 30),
        mime: _mime(j),
      );
}

/// A voice clip: one encrypted AAC-LC `.m4a` blob in R2 under a fresh media [key], pinned by the
/// SHA-256 of its ciphertext, with its length and a small waveform for the bubble.
class VoiceBody extends Plaintext {
  const VoiceBody({
    required this.mediaKey,
    required this.key,
    required this.sha256,
    required this.durationMs,
    required this.waveform,
    required this.bytes,
    this.mime = 'audio/mp4',
  });

  /// Receivers accept clips up to this long; senders stop at 10 minutes.
  static const maxDurationMs = 15 * 60 * 1000;

  /// Most waveform peaks a receiver accepts (senders send 64).
  static const maxWaveform = 128;

  /// Media key (`/api/media/:key`) of the clip.
  final String mediaKey;

  /// The 32-byte media key, and SHA-256 of the encrypted blob.
  final Uint8List key, sha256;
  final int durationMs;

  /// Peaks 0–255, oldest first.
  final List<int> waveform;

  /// Size of the `.m4a` in bytes.
  final int bytes;
  final String mime;

  @override
  String get kind => 'voice';

  @override
  Map<String, Object?> toJson() => {
        'kind': kind,
        'mediaKey': mediaKey,
        'key': b64url(key),
        'sha256': b64url(sha256),
        'durationMs': durationMs,
        'waveform': b64url(Uint8List.fromList(waveform)),
        'bytes': bytes,
        'mime': mime,
      };

  factory VoiceBody._fromJson(Map<String, Object?> j) {
    final w = j['waveform'];
    Uint8List? wave;
    if (w is String) {
      try {
        wave = w.isEmpty ? Uint8List(0) : b64urlDecode(w);
      } on CryptoFailure {
        wave = null;
      }
    }
    if (wave == null || wave.length > maxWaveform) throw const FormatException('bad waveform');
    return VoiceBody(
      mediaKey: _mediaId(j, 'mediaKey'),
      key: _bytes32(j, 'key'),
      sha256: _bytes32(j, 'sha256'),
      durationMs: _positive(j, 'durationMs', maxDurationMs),
      waveform: List.unmodifiable(wave),
      bytes: _positive(j, 'bytes', 1 << 30),
      mime: _mime(j),
    );
  }
}

String _mediaId(Map<String, Object?> j, String k) {
  final v = j[k];
  // Media keys are ULIDs (they become URL path segments).
  if (v is! String || !_ulid.hasMatch(v)) throw FormatException('bad $k');
  return v;
}

Uint8List _bytes32(Map<String, Object?> j, String k) {
  final v = j[k];
  try {
    if (v is String) {
      final b = b64urlDecode(v);
      if (b.length == 32) return b;
    }
  } on CryptoFailure {
    // falls through
  }
  throw FormatException('bad $k');
}

int _positive(Map<String, Object?> j, String k, int max) {
  final v = j[k];
  if (v is! int || v < 1 || v > max) throw FormatException('bad $k');
  return v;
}

String _mime(Map<String, Object?> j) {
  final mime = j['mime'];
  if (mime is! String || mime.isEmpty || mime.length > 64) throw const FormatException('bad mime');
  return mime;
}

/// A kind this version doesn't know (a newer version's).
/// Keeps the whole body, so a later version can show the stored message.
class UnknownBody extends Plaintext {
  const UnknownBody(this.kind, [this.raw = const {}]);
  @override
  final String kind;
  final Map<String, Object?> raw;
  @override
  Map<String, Object?> toJson() => {...raw, 'kind': kind};
}
