import 'dart:convert';

import 'db/chat_db.dart';

/// target message id → emoji → user ids. Rows in display order; each user's newest reaction on a
/// target wins and an empty emoji removes it.
Map<String, Map<String, Set<String>>> aggregateReactions(Iterable<MessageRow> rows) {
  final latest = <String, Map<String, String>>{}; // target → user → emoji
  for (final r in rows) {
    if (r.kind != 'reaction' || r.targetId == null || r.body == null || r.state == 'failed') continue;
    final Object? j;
    try {
      j = jsonDecode(r.body!);
    } on FormatException {
      continue;
    }
    final emoji = j is Map ? j['emoji'] : null;
    if (emoji is! String) continue;
    (latest[r.targetId!] ??= {})[r.senderUserId] = emoji;
  }
  final out = <String, Map<String, Set<String>>>{};
  latest.forEach((target, byUser) {
    byUser.forEach((user, emoji) {
      if (emoji.isEmpty) return;
      ((out[target] ??= {})[emoji] ??= {}).add(user);
    });
  });
  return out;
}
