// What travels inside an envelope: UTF-8 JSON with a `kind`.
import 'dart:convert';
import 'dart:typed_data';

const maxTextLength = 4000;

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
      default:
        return UnknownBody(kind);
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

/// A kind this version doesn't know (photos and voice before plans 7–8 land, or newer kinds).
class UnknownBody extends Plaintext {
  const UnknownBody(this.kind);
  @override
  final String kind;
  @override
  Map<String, Object?> toJson() => {'kind': kind};
}
