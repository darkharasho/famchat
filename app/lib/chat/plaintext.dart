// What travels inside an envelope: UTF-8 JSON with a `kind`.
import 'dart:convert';
import 'dart:typed_data';

import '../crypto/encoding.dart';
import '../games/rules.dart';

const maxTextLength = 4000;

/// At most this many @mentions in one text (the server's limit too).
const maxMentions = 50;

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
        final text = j['text'], replyTo = j['replyTo'], mentions = j['mentions'];
        if (text is! String || text.isEmpty) throw const FormatException('bad text');
        if (replyTo != null && (replyTo is! String || replyTo.isEmpty)) throw const FormatException('bad replyTo');
        if (mentions != null && (mentions is! List || mentions.length > maxMentions || mentions.any((m) => m is! String))) {
          throw const FormatException('bad mentions');
        }
        return TextBody(
          text,
          replyTo: replyTo as String?,
          mentions: [...?(mentions as List?)?.cast<String>()],
          // A preview that doesn't check out is dropped; the text still shows.
          preview: LinkPreview.tryParse(j['preview']),
        );
      case 'edit':
        final target = j['target'], text = j['text'];
        if (target is! String || target.isEmpty || text is! String || text.isEmpty) {
          throw const FormatException('bad edit');
        }
        // A preview-only edit whose preview doesn't check out changes nothing.
        return EditBody(
          target,
          text,
          preview: LinkPreview.tryParse(j['preview']),
          previewOnly: j['previewOnly'] == true,
        );
      case 'delete':
        final target = j['target'];
        if (target is! String || target.isEmpty) throw const FormatException('bad delete');
        return DeleteBody(target);
      case 'pin':
        final target = j['target'], pinned = j['pinned'];
        if (target is! String || target.isEmpty || pinned is! bool) throw const FormatException('bad pin');
        return PinBody(target, pinned: pinned);
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
      case 'gif':
        return GifBody._fromJson(j);
      case 'video':
        return VideoBody._fromJson(j);
      case 'game':
        final game = j['game'], first = j['first'];
        if (first is! String || first.isEmpty) throw const FormatException('bad first');
        if (game is! String) throw const FormatException('bad game');
        final type = GameType.fromWire(game);
        final seed = wireInt(j['seed']);
        final validSeed = seed != null && seed >= 0 && seed <= 0xFFFFFFFF ? seed : null;
        return type == null
            ? UnknownBody(kind, j)
            : GameBody(
                type,
                first,
                seed: validSeed,
                optionalJumps: type == GameType.checkers && j['jumps'] == 'optional',
                wholeDeck: type == GameType.war && j['until'] == 'all_cards',
              );
      case 'move':
        final target = j['target'], game = j['game'], ply = wireInt(j['ply']), action = j['action'];
        if (target is! String || target.isEmpty) throw const FormatException('bad move target');
        if (game is! String) throw const FormatException('bad game');
        if (ply == null || ply < 0) throw const FormatException('bad ply');
        if (action is! Map<String, Object?> || action['type'] is! String) throw const FormatException('bad action');
        final type = GameType.fromWire(game);
        final rules = wireInt(j['rules']);
        return type == null
            ? UnknownBody(kind, j)
            : MoveBody(target, type, ply, action, rules: rules != null && rules > 0 ? rules : null);
      case 'poll':
        return PollBody._fromJson(j);
      case 'vote':
        final target = j['target'], choices = j['choices'];
        if (target is! String || target.isEmpty) throw const FormatException('bad vote target');
        if (choices is! List || choices.length > maxPollOptions) throw const FormatException('bad choices');
        final ints = [for (final c in choices) wireInt(c)];
        if (ints.any((c) => c == null)) throw const FormatException('bad choices');
        return VoteBody(target, List.unmodifiable(ints.cast<int>()));
      case 'poll_end':
        final target = j['target'];
        if (target is! String || target.isEmpty) throw const FormatException('bad poll_end');
        return PollEndBody(target);
      default:
        return UnknownBody(kind, j);
    }
  }
}

class TextBody extends Plaintext {
  const TextBody(this.text, {this.replyTo, this.mentions = const [], this.preview});

  /// A card for the first link in [text], made by the sender (docs/protocol.md "Link previews").
  final LinkPreview? preview;
  final String text;

  /// The message this one replies to, if any.
  final String? replyTo;

  /// Users @mentioned in [text] (docs/protocol.md "Messages").
  final List<String> mentions;
  @override
  String get kind => 'text';
  @override
  Map<String, Object?> toJson() => {
        'kind': kind,
        'text': text,
        if (replyTo != null) 'replyTo': replyTo,
        if (mentions.isNotEmpty) 'mentions': mentions,
        if (preview != null) 'preview': preview!.toJson(),
      };
}

/// A link's title, description, site and (as an encrypted thumbnail) image.
class LinkPreview {
  const LinkPreview({required this.url, required this.title, this.description, this.siteName, this.image});
  final String url, title;
  final String? description, siteName;
  final PreviewImage? image;

  Map<String, Object?> toJson() => {
        'url': url,
        'title': title,
        if (description != null) 'description': description,
        if (siteName != null) 'siteName': siteName,
        if (image != null) 'image': image!.toJson(),
      };

  /// Null unless [j] is a preview of an http(s) link with a title (an image that doesn't check
  /// out is dropped).
  static LinkPreview? tryParse(Object? j) {
    if (j is! Map<String, Object?>) return null;
    final url = j['url'], title = j['title'], description = j['description'], site = j['siteName'];
    if (url is! String || title is! String || title.isEmpty || title.length > 300) return null;
    final u = Uri.tryParse(url);
    if (u == null || !(u.scheme == 'https' || u.scheme == 'http') || u.host.isEmpty) return null;
    String? short(Object? v, int max) => v is String && v.isNotEmpty ? (v.length > max ? v.substring(0, max) : v) : null;
    PreviewImage? image;
    if (j['image'] case final Map<String, Object?> i) {
      try {
        image = PreviewImage(
          mediaKey: _mediaId(i, 'mediaKey'),
          key: _bytes32(i, 'key'),
          sha256: _bytes32(i, 'sha256'),
          width: _positive(i, 'width', 100000),
          height: _positive(i, 'height', 100000),
        );
      } on FormatException {
        image = null;
      }
    }
    return LinkPreview(url: url, title: title, description: short(description, 400), siteName: short(site, 100), image: image);
  }
}

/// A preview's image: one encrypted thumbnail blob (purpose thumb) under its own media key.
class PreviewImage {
  const PreviewImage({required this.mediaKey, required this.key, required this.sha256, required this.width, required this.height});
  final String mediaKey;
  final Uint8List key, sha256;
  final int width, height;

  Map<String, Object?> toJson() =>
      {'mediaKey': mediaKey, 'key': b64url(key), 'sha256': b64url(sha256), 'width': width, 'height': height};
}

/// New text for the sender's own text message [target]; the latest edit wins.
///
/// [previewOnly]: not an edit but a link [preview] that wasn't ready when [target] was sent. [text]
/// repeats the text in force (older clients read it as a plain edit); it counts only while it still
/// matches, and doesn't mark the message edited (docs/protocol.md "Link previews").
class EditBody extends Plaintext {
  const EditBody(this.target, this.text, {this.preview, this.previewOnly = false});
  final String target, text;
  final LinkPreview? preview;
  final bool previewOnly;
  @override
  String get kind => 'edit';
  @override
  Map<String, Object?> toJson() => {
        'kind': kind,
        'target': target,
        'text': text,
        if (preview != null) 'preview': preview!.toJson(),
        if (previewOnly) 'previewOnly': true,
      };
}

/// Pins [target] for everyone in the chat ([pinned] false unpins it). Anyone can pin any message;
/// the latest pin event per target wins and at most [maxPins] stay pinned (docs/protocol.md "Pins").
class PinBody extends Plaintext {
  const PinBody(this.target, {required this.pinned});
  final String target;
  final bool pinned;
  @override
  String get kind => 'pin';
  @override
  Map<String, Object?> toJson() => {'kind': kind, 'target': target, 'pinned': pinned};
}

/// At most this many messages are pinned in a chat; pinning another unpins the oldest.
const maxPins = 3;

/// Unsends the sender's own message [target].
class DeleteBody extends Plaintext {
  const DeleteBody(this.target);
  final String target;
  @override
  String get kind => 'delete';
  @override
  Map<String, Object?> toJson() => {'kind': kind, 'target': target};
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
class PhotoBody extends Plaintext with Captioned {
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
    this.caption,
    this.replyTo,
    this.mentions = const [],
    this.album,
  });

  /// Media keys (`/api/media/:key`) of the full image and the thumbnail.
  final String mediaKey, thumbKey;

  /// The 32-byte media key, and SHA-256 of each encrypted blob.
  final Uint8List key, sha256, thumbSha256;

  /// Full image size in pixels, and its JPEG size in bytes.
  final int width, height, bytes;
  final String mime;

  @override
  final String? caption, replyTo, album;
  @override
  final List<String> mentions;

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
        ...captionJson,
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
        caption: _caption(j),
        replyTo: _replyTo(j),
        mentions: _mentions(j),
        album: _album(j),
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

/// A video: one encrypted MP4 blob in R2, and (when one could be made) an encrypted JPEG poster
/// frame, both under one fresh media [key] and pinned by the SHA-256 of their ciphertext.
class VideoBody extends Plaintext with Captioned {
  const VideoBody({
    required this.mediaKey,
    required this.key,
    required this.sha256,
    this.thumbKey,
    this.thumbSha256,
    required this.width,
    required this.height,
    required this.durationMs,
    required this.bytes,
    this.mime = 'video/mp4',
    this.caption,
    this.replyTo,
    this.mentions = const [],
    this.album,
  }) : assert((thumbKey == null) == (thumbSha256 == null));

  /// Receivers accept videos up to this long.
  static const maxDurationMs = 60 * 60 * 1000;

  /// Media key (`/api/media/:key`) of the video, and of its poster frame if it has one.
  final String mediaKey;
  final String? thumbKey;

  /// The 32-byte media key, and SHA-256 of each encrypted blob.
  final Uint8List key, sha256;
  final Uint8List? thumbSha256;

  /// Display size in pixels, length, and file size in bytes.
  final int width, height, durationMs, bytes;
  final String mime;

  @override
  final String? caption, replyTo, album;
  @override
  final List<String> mentions;

  @override
  String get kind => 'video';

  @override
  Map<String, Object?> toJson() => {
        'kind': kind,
        'mediaKey': mediaKey,
        'key': b64url(key),
        'sha256': b64url(sha256),
        if (thumbKey != null) 'thumbKey': thumbKey,
        if (thumbSha256 != null) 'thumbSha256': b64url(thumbSha256!),
        'width': width,
        'height': height,
        'durationMs': durationMs,
        'bytes': bytes,
        'mime': mime,
        ...captionJson,
      };

  factory VideoBody._fromJson(Map<String, Object?> j) {
    final hasThumb = j.containsKey('thumbKey') || j.containsKey('thumbSha256');
    return VideoBody(
      mediaKey: _mediaId(j, 'mediaKey'),
      key: _bytes32(j, 'key'),
      sha256: _bytes32(j, 'sha256'),
      thumbKey: hasThumb ? _mediaId(j, 'thumbKey') : null,
      thumbSha256: hasThumb ? _bytes32(j, 'thumbSha256') : null,
      width: _positive(j, 'width', 100000),
      height: _positive(j, 'height', 100000),
      durationMs: _positive(j, 'durationMs', maxDurationMs),
      bytes: _positive(j, 'bytes', 1 << 30),
      mime: _mime(j),
      caption: _caption(j),
      replyTo: _replyTo(j),
      mentions: _mentions(j),
      album: _album(j),
    );
  }
}

/// A GIF from KLIPY (docs/protocol.md "GIFs"). KLIPY's terms have each viewer load it straight from
/// KLIPY, so only its link travels (encrypted, like any message).
class GifBody extends Plaintext {
  const GifBody({required this.slug, required this.title, required this.url, required this.width, required this.height});

  /// KLIPY's id for it, and its title (shown to screen readers).
  final String slug, title;

  /// An https URL on klipy.com (animated WebP or GIF).
  final String url;
  final int width, height;

  @override
  String get kind => 'gif';

  @override
  Map<String, Object?> toJson() =>
      {'kind': kind, 'slug': slug, 'title': title, 'url': url, 'width': width, 'height': height};

  factory GifBody._fromJson(Map<String, Object?> j) {
    final slug = j['slug'], title = j['title'], url = j['url'];
    if (slug is! String || slug.isEmpty || slug.length > 200) throw const FormatException('bad slug');
    if (title is! String || title.length > 500) throw const FormatException('bad title');
    if (url is! String || !isKlipyMediaUrl(url)) throw const FormatException('bad url');
    return GifBody(
      slug: slug,
      title: title,
      url: url,
      width: _positive(j, 'width', 4096),
      height: _positive(j, 'height', 4096),
    );
  }
}

/// https on klipy.com or a subdomain, with no credentials or port: the only links a GIF loads.
bool isKlipyMediaUrl(String url) {
  final u = Uri.tryParse(url);
  if (u == null || u.scheme != 'https' || u.userInfo.isNotEmpty || u.hasPort) return false;
  return u.host == 'klipy.com' || u.host.endsWith('.klipy.com');
}

/// A photo or video's optional caption, with the message it replies to and the users @mentioned
/// in the caption (docs/protocol.md "Messages"). A caption that doesn't check out is dropped; the
/// media still shows.
///
/// [album]: photos and videos sent together share this id and show as one album.
mixin Captioned {
  String? get caption;
  String? get replyTo;
  List<String> get mentions;
  String? get album;

  Map<String, Object?> get captionJson => {
        'caption': ?caption,
        'replyTo': ?replyTo,
        if (mentions.isNotEmpty) 'mentions': mentions,
        'album': ?album,
      };
}

String? _album(Map<String, Object?> j) {
  final a = j['album'];
  return a is String && _ulid.hasMatch(a) ? a : null;
}

String? _caption(Map<String, Object?> j) {
  final c = j['caption'];
  return c is String ? validMessageText(c) : null;
}

String? _replyTo(Map<String, Object?> j) {
  final r = j['replyTo'];
  return r is String && r.isNotEmpty ? r : null;
}

List<String> _mentions(Map<String, Object?> j) {
  final m = j['mentions'];
  return m is List && m.length <= maxMentions && m.every((u) => u is String) ? List.unmodifiable(m.cast<String>()) : const [];
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

/// Starts a game in a direct chat; the message's id is the game's id (docs/protocol.md "Games").
/// [first] is the user who moves first (X, dark, white).
class GameBody extends Plaintext {
  const GameBody(this.game, this.first, {this.seed, this.optionalJumps = false, this.wholeDeck = false});
  final GameType game;
  final String first;

  /// `0..4294967295`, for games with luck (docs/protocol.md "Games"); null when absent or invalid.
  final int? seed;

  /// Checkers only: captures may be skipped (`"jumps": "optional"`; docs/protocol.md "Games").
  final bool optionalJumps;

  /// War only: play until one player has every card (`"until": "all_cards"`; docs/protocol.md "Games").
  final bool wholeDeck;
  @override
  String get kind => 'game';
  @override
  Map<String, Object?> toJson() => {
    'kind': kind,
    'game': game.wire,
    'first': first,
    'seed': ?seed,
    if (optionalJumps && game == GameType.checkers) 'jumps': 'optional',
    if (wholeDeck && game == GameType.war) 'until': 'all_cards',
  };
}

/// One action in the game [target] (a `game` message id) at move number [ply]. [action] has a string
/// `type` (play, resign, draw_offer, draw_accept, draw_decline, poke) and the game's move fields.
class MoveBody extends Plaintext {
  const MoveBody(this.target, this.game, this.ply, this.action, {this.rules});
  final String target;
  final GameType game;
  final int ply;
  final Map<String, Object?> action;

  /// The sender's [GameType.rules]; null from versions before it was sent.
  final int? rules;
  @override
  String get kind => 'move';
  @override
  Map<String, Object?> toJson() => {'kind': kind, 'target': target, 'game': game.wire, 'ply': ply, 'action': action, 'rules': ?rules};
}

/// Most options a poll has (and least: 2).
const maxPollOptions = 10;

/// Longest poll question and option, in characters.
const maxPollQuestion = 300;
const maxPollOption = 100;

/// A poll; the message's id is the poll's id and option ids are indexes (docs/protocol.md "Polls").
/// [multi]: voters may pick more than one option.
class PollBody extends Plaintext {
  const PollBody(this.question, this.options, {this.multi = false, this.replyTo});
  final String question;
  final List<String> options;
  final bool multi;
  final String? replyTo;
  @override
  String get kind => 'poll';
  @override
  Map<String, Object?> toJson() => {'kind': kind, 'question': question, 'options': options, 'multi': multi, 'replyTo': ?replyTo};

  /// Throws [FormatException] unless the question and options keep the limits (receivers drop such polls).
  factory PollBody._fromJson(Map<String, Object?> j) {
    final question = j['question'], options = j['options'], multi = j['multi'];
    if (question is! String || _pollText(question, maxPollQuestion) == null) throw const FormatException('bad question');
    if (options is! List || options.any((o) => o is! String || o.trim().isEmpty)) throw const FormatException('bad options');
    if (multi != null && multi is! bool) throw const FormatException('bad multi');
    final p = validPoll(question, options.cast<String>(), multi: multi == true, replyTo: _replyTo(j));
    if (p == null) throw const FormatException('bad options');
    return p;
  }
}

/// The trimmed text if it's 1–[max] characters, else null.
String? _pollText(String s, int max) {
  final t = s.trim();
  return t.isEmpty || t.runes.length > max ? null : t;
}

/// A poll that can be sent: [question] and [options] trimmed, blank options dropped; null if the
/// question isn't 1–[maxPollQuestion] characters, there aren't 2–[maxPollOptions] options of
/// 1–[maxPollOption] characters, or two options are the same (ignoring case).
PollBody? validPoll(String question, List<String> options, {bool multi = false, String? replyTo}) {
  final q = _pollText(question, maxPollQuestion);
  if (q == null) return null;
  final opts = <String>[];
  final seen = <String>{};
  for (final o in options) {
    if (o.trim().isEmpty) continue;
    final t = _pollText(o, maxPollOption);
    if (t == null || !seen.add(t.toLowerCase())) return null;
    opts.add(t);
  }
  if (opts.length < 2 || opts.length > maxPollOptions) return null;
  return PollBody(q, List.unmodifiable(opts), multi: multi, replyTo: replyTo);
}

/// This sender's choices (option indexes) on the poll [target], replacing their earlier vote; `[]`
/// takes the vote back.
class VoteBody extends Plaintext {
  const VoteBody(this.target, this.choices);
  final String target;
  final List<int> choices;
  @override
  String get kind => 'vote';
  @override
  Map<String, Object?> toJson() => {'kind': kind, 'target': target, 'choices': choices};
}

/// Ends the poll [target]; counts only from the poll's sender.
class PollEndBody extends Plaintext {
  const PollEndBody(this.target);
  final String target;
  @override
  String get kind => 'poll_end';
  @override
  Map<String, Object?> toJson() => {'kind': kind, 'target': target};
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
