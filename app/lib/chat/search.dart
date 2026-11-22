// Searching messages on this device (the server only holds ciphertext).
import 'db/chat_db.dart';
import 'message_changes.dart';
import 'files.dart' show fileOf;
import 'polls.dart' show pollOf;

/// A message whose current text matches.
class SearchHit {
  const SearchHit(this.message, this.text);
  final MessageRow message;

  /// Its current text (the latest edit).
  final String text;
}

/// Text messages whose current text contains [query] (ignoring case), newest first, and polls whose
/// question or an option does (their text: "📊 question · option · option"), and files whose name
/// does ("📎 name"). Deleted messages, and
/// text only an earlier version had, don't match.
Future<List<SearchHit>> searchMessages(ChatDb db, String query, {String? chatId, int limit = 50}) async {
  final q = query.trim();
  if (q.isEmpty) return const [];
  final pattern = '%${q.replaceAllMapped(RegExp(r'[\\%_]'), (m) => '\\${m[0]}')}%';
  final needle = q.toLowerCase();
  final hits = <SearchHit>[];
  for (final m in await db.searchCandidates(pattern, chatId: chatId)) {
    final c = messageChanges([m, ...await db.changesTo(m.chatId, m.id)]);
    final poll = c.isDeleted(m.id) ? null : pollOf(m);
    final file = c.isDeleted(m.id) ? null : fileOf(m);
    final text = poll != null
        ? '📊 ${[poll.question, ...poll.options].join(' · ')}'
        : file != null
            ? '📎 ${file.name}'
            : c.textOf(m);
    if (text != null && text.toLowerCase().contains(needle)) hits.add(SearchHit(m, text));
    if (hits.length >= limit) break;
  }
  return hits;
}

/// Where [query] occurs in [text], ignoring case, as (start, end) pairs.
List<(int, int)> matchRanges(String text, String query) {
  if (query.isEmpty) return const [];
  final t = text.toLowerCase(), q = query.toLowerCase();
  final out = <(int, int)>[];
  for (var i = t.indexOf(q); i >= 0; i = t.indexOf(q, i + q.length)) {
    out.add((i, i + q.length));
  }
  return out;
}

/// One line of [text] around the first match of [query], with … where it was cut.
String snippetAround(String text, String query, {int radius = 40}) {
  final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  final hit = matchRanges(flat, query).firstOrNull;
  if (hit == null || flat.length <= radius * 2 + query.length) return flat;
  final start = (hit.$1 - radius).clamp(0, flat.length);
  final end = (hit.$2 + radius).clamp(0, flat.length);
  return '${start > 0 ? '…' : ''}${flat.substring(start, end).trim()}${end < flat.length ? '…' : ''}';
}
