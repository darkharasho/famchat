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

  factory PhotoBody._fromJson(Map<String, Object?> j) {
    String id(String k) {
      final v = j[k];
      // Media keys are ULIDs (they become URL path segments).
      if (v is! String || !_ulid.hasMatch(v)) throw FormatException('bad $k');
      return v;
    }

    Uint8List b32(String k) {
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

    int positive(String k, int max) {
      final v = j[k];
      if (v is! int || v < 1 || v > max) throw FormatException('bad $k');
      return v;
    }

    final mime = j['mime'];
    if (mime is! String || mime.isEmpty || mime.length > 64) throw const FormatException('bad mime');
    return PhotoBody(
      mediaKey: id('mediaKey'),
      thumbKey: id('thumbKey'),
      key: b32('key'),
      sha256: b32('sha256'),
      thumbSha256: b32('thumbSha256'),
      width: positive('width', 100000),
      height: positive('height', 100000),
      bytes: positive('bytes', 1 << 30),
      mime: mime,
    );
  }
}

/// A kind this version doesn't know (voice before plan 8 lands, or newer kinds).
/// Keeps the whole body, so a later version can show the stored message.
class UnknownBody extends Plaintext {
  const UnknownBody(this.kind, [this.raw = const {}]);
  @override
  final String kind;
  final Map<String, Object?> raw;
  @override
  Map<String, Object?> toJson() => {...raw, 'kind': kind};
}
