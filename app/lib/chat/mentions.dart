// @mentions in group texts: what's being typed, picking a person, and who a text mentions.
import 'package:flutter/services.dart';

/// The `@query` being typed: where its `@` is, and the text after it up to the cursor.
typedef MentionQuery = ({int start, String query});

final _wordChar = RegExp(r'[\p{L}\p{N}_]', unicode: true);
final _space = RegExp(r'\s');

bool _isWordChar(String s, int i) => i >= 0 && i < s.length && _wordChar.hasMatch(s[i]);

/// The mention being typed at the cursor: an `@` at the start or after whitespace, then no spaces.
MentionQuery? mentionQueryAt(TextEditingValue v) {
  final sel = v.selection;
  if (!sel.isValid || !sel.isCollapsed) return null;
  final before = v.text.substring(0, sel.baseOffset);
  final at = before.lastIndexOf('@');
  if (at < 0) return null;
  if (at > 0 && !_space.hasMatch(before[at - 1])) return null;
  final query = before.substring(at + 1);
  if (query.contains(_space) || query.contains('@')) return null;
  return (start: at, query: query);
}

/// People (id → name) whose name, or a word of it, starts with [query], ignoring case; by name.
List<({String id, String name})> matchingPeople(String query, Map<String, String> people) {
  final q = query.toLowerCase();
  final out = [
    for (final e in people.entries)
      if (e.value.toLowerCase().startsWith(q) || e.value.toLowerCase().split(_space).any((w) => w.startsWith(q)))
        (id: e.key, name: e.value),
  ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return out;
}

/// [v] with [q] replaced by `@name ` and the cursor after it.
TextEditingValue insertMention(TextEditingValue v, MentionQuery q, String name) {
  final end = q.start + 1 + q.query.length;
  final rest = v.text.substring(end);
  final insert = rest.startsWith(' ') ? '@$name' : '@$name ';
  final text = v.text.replaceRange(q.start, end, insert);
  final cursor = q.start + insert.length + (rest.startsWith(' ') ? 1 : 0);
  return TextEditingValue(text: text, selection: TextSelection.collapsed(offset: cursor));
}

/// Where `@name` appears in [text] for each of [names] (ignoring case), as whole words: not after a
/// letter or digit, not followed by one. Longer names win where two overlap ("@Ann Lee" over "@Ann").
List<(int, int)> mentionRanges(String text, Iterable<String> names) {
  final lower = text.toLowerCase();
  final taken = <(int, int)>[];
  final sorted = names.where((n) => n.isNotEmpty).toSet().toList()..sort((a, b) => b.length.compareTo(a.length));
  for (final name in sorted) {
    final needle = '@${name.toLowerCase()}';
    for (var i = lower.indexOf(needle); i >= 0; i = lower.indexOf(needle, i + 1)) {
      final end = i + needle.length;
      if (_isWordChar(text, i - 1) || _isWordChar(text, end)) continue;
      if (taken.any((r) => i < r.$2 && end > r.$1)) continue;
      taken.add((i, end));
    }
  }
  return taken..sort((a, b) => a.$1.compareTo(b.$1));
}

/// The ids of [people] (id → name) that [text] mentions.
List<String> mentionsIn(String text, Map<String, String> people) {
  final ranges = mentionRanges(text, people.values);
  final found = <String>[];
  for (final (s, e) in ranges) {
    final name = text.substring(s + 1, e).toLowerCase();
    // Everyone with that name: the text can't tell two of them apart.
    for (final p in people.entries) {
      if (p.value.toLowerCase() == name && !found.contains(p.key)) found.add(p.key);
    }
  }
  return found;
}
