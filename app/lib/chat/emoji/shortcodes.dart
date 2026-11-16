import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show StringCharacters;

import 'shortcode_data.dart';

/// The emoji for a `:name:` shortcode (without the colons; case-insensitive), or null.
String? emojiForShortcode(String name) => emojiShortcodes[name.toLowerCase()];

/// A shortcode name being typed: the `:partial` between [start] (the colon) and [end].
@immutable
class ShortcodeQuery {
  const ShortcodeQuery(this.start, this.end, this.query);

  final int start, end;

  /// Lowercased, without the colon.
  final String query;

  @override
  bool operator ==(Object other) =>
      other is ShortcodeQuery && other.start == start && other.end == end && other.query == query;

  @override
  int get hashCode => Object.hash(start, end, query);

  @override
  String toString() => 'ShortcodeQuery($start, $end, $query)';
}

/// One suggestion: a shortcode [name] and its [emoji].
@immutable
class ShortcodeMatch {
  const ShortcodeMatch(this.name, this.emoji);

  final String name, emoji;

  @override
  bool operator ==(Object other) => other is ShortcodeMatch && other.name == name && other.emoji == emoji;

  @override
  int get hashCode => Object.hash(name, emoji);

  @override
  String toString() => ':$name: $emoji';
}

/// The opening colon only counts at the start, after whitespace or after an opening bracket or quote, so
/// `http://`, `10:30` and `a:b` never trigger.
const _lead = r'(?:^|(?<=[\s(\[{"' "'" r']))';
const _nameChar = r'[A-Za-z0-9_+\-]';

final _partialBeforeCursor = RegExp('$_lead:($_nameChar{2,})\$');
final _wordAfterCursor = RegExp('^$_nameChar*');
final _fullBeforeCursor = RegExp('$_lead:($_nameChar+):\$');

/// The `:partial` shortcode the cursor is in (at least two characters after the colon), or null.
ShortcodeQuery? shortcodeQueryAt(TextEditingValue value) {
  final sel = value.selection;
  if (!sel.isValid || !sel.isCollapsed) return null;
  final cursor = sel.baseOffset;
  final m = _partialBeforeCursor.firstMatch(value.text.substring(0, cursor));
  if (m == null) return null;
  final rest = _wordAfterCursor.firstMatch(value.text.substring(cursor))!.end;
  // `:smile|:` is a finished name, not a query.
  if (cursor + rest < value.text.length && value.text[cursor + rest] == ':') return null;
  return ShortcodeQuery(m.start, cursor + rest, m.group(1)!.toLowerCase());
}

/// Names people reach for most (Slack/Discord favourites), suggested ahead of other matches.
const _popular = [
  'thumbsup', '+1', 'heart', 'joy', 'smile', 'fire', 'tada', 'pray', 'laughing', 'rofl', 'sob', 'eyes', 'wave',
  'clap', 'ok_hand', 'thinking', 'grin', 'wink', 'blush', 'heart_eyes', 'kissing_heart', 'sunglasses', 'cry',
  'hugs', 'muscle', 'raised_hands', 'smiley', 'slightly_smiling_face', 'upside_down_face', 'thumbsdown', '-1',
  'white_check_mark', 'star', 'sparkles', 'birthday', 'cake', 'gift', 'sunny', 'rainbow', 'dog', 'cat',
  'coffee', 'pizza', '100', 'scream', 'sweat_smile', 'relaxed', 'kiss', 'see_no_evil',
];

final _rank = {for (final (i, n) in _popular.indexed) n: i};

/// Shortcodes matching [query]: the exact name, then names starting with it (popular ones first, then
/// shorter ones), then names containing it, each emoji once (by its first matching name).
List<ShortcodeMatch> searchShortcodes(String query, {int limit = 8}) {
  final q = query.toLowerCase();
  if (q.isEmpty) return const [];
  final exact = <ShortcodeMatch>[], prefix = <ShortcodeMatch>[], inner = <ShortcodeMatch>[];
  for (final MapEntry(key: name, value: emoji) in emojiShortcodes.entries) {
    if (name == q) {
      exact.add(ShortcodeMatch(name, emoji));
    } else if (name.startsWith(q)) {
      prefix.add(ShortcodeMatch(name, emoji));
    } else if (name.contains(q)) {
      inner.add(ShortcodeMatch(name, emoji));
    }
  }
  int byRank(ShortcodeMatch a, ShortcodeMatch b) {
    final ra = _rank[a.name] ?? _popular.length, rb = _rank[b.name] ?? _popular.length;
    return ra != rb ? ra.compareTo(rb) : a.name.length.compareTo(b.name.length);
  }

  mergeSort(prefix, compare: byRank); // stable: equal ranks keep gemoji order
  final seen = <String>{};
  return [
    for (final m in [...exact, ...prefix, ...inner])
      if (seen.add(m.emoji)) m,
  ].take(limit).toList();
}

/// [value] with the [query] text replaced by [emoji], the cursor after it.
TextEditingValue replaceShortcodeQuery(TextEditingValue value, ShortcodeQuery query, String emoji) =>
    _replace(value, query.start, query.end, emoji);

/// [value] with [emoji] at the cursor, replacing any selection (appended when there is no selection).
TextEditingValue insertEmoji(TextEditingValue value, String emoji) {
  final sel = value.selection;
  if (!sel.isValid) return _replace(value, value.text.length, value.text.length, emoji);
  return _replace(value, sel.start, sel.end, emoji);
}

TextEditingValue _replace(TextEditingValue value, int start, int end, String insert) => TextEditingValue(
      text: value.text.replaceRange(start, end, insert),
      selection: TextSelection.collapsed(offset: start + insert.length),
    );

/// When [next] is [old] with a `:` typed at the cursor that closes a known `:name:`, [next] with the
/// name replaced by its emoji; otherwise null.
TextEditingValue? completeShortcode(TextEditingValue old, TextEditingValue next) {
  final sel = next.selection;
  if (!sel.isValid || !sel.isCollapsed || sel.baseOffset == 0) return null;
  final cursor = sel.baseOffset;
  final typedColon = next.text.length == old.text.length + 1 &&
      next.text[cursor - 1] == ':' &&
      next.text.replaceRange(cursor - 1, cursor, '') == old.text;
  if (!typedColon) return null;
  final m = _fullBeforeCursor.firstMatch(next.text.substring(0, cursor));
  if (m == null) return null;
  final emoji = emojiForShortcode(m.group(1)!);
  if (emoji == null) return null;
  return _replace(next, m.start, cursor, emoji);
}

/// Turns a known `:name:` into its emoji as the closing colon is typed (pastes are left alone).
class ShortcodeFormatter extends TextInputFormatter {
  const ShortcodeFormatter();

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) =>
      completeShortcode(oldValue, newValue) ?? newValue;
}

final _emojiCluster = RegExp(
  // The lint checks without `unicode: true`, so it rejects the \p{…} property escapes (covered by tests).
  // ignore: valid_regexps
  r'^(?:[#*0-9]\uFE0F?\u20E3'
  r'|\p{Regional_Indicator}{2}'
  r'|(?=.*(?:\p{Emoji_Presentation}|\uFE0F|\p{Emoji_Modifier}))\p{Extended_Pictographic}.*)$',
  unicode: true,
  dotAll: true,
);

/// How many emoji [text] is made of (whitespace between them is fine), or null when it holds anything else.
int? emojiOnlyCount(String text) {
  var count = 0;
  for (final c in text.characters) {
    if (c.trim().isEmpty) continue;
    if (!_emojiCluster.hasMatch(c)) return null;
    count++;
  }
  return count == 0 ? null : count;
}

/// [value] after a backspace: the selection, or the one character (emoji included) before the cursor.
TextEditingValue deleteBackward(TextEditingValue value) {
  final sel = value.selection.isValid ? value.selection : TextSelection.collapsed(offset: value.text.length);
  if (!sel.isCollapsed) return _replace(value, sel.start, sel.end, '');
  final before = value.text.substring(0, sel.start);
  if (before.isEmpty) return value;
  final kept = before.characters.skipLast(1).string;
  return _replace(value, kept.length, sel.start, '');
}
