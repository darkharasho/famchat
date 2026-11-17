// Edits and deletes (docs/protocol.md "Plaintext"): messages that change an earlier one. They count
// only when sent by the earlier message's sender.
import 'dart:convert';

import 'db/chat_db.dart';

/// Kinds that change another message instead of showing as one.
const changeKinds = {'reaction', 'edit', 'delete'};

/// The edits and deletes in force over a chat's messages.
class MessageChanges {
  MessageChanges._(this._texts, this._deleted);

  final Map<String, String> _texts;
  final Set<String> _deleted;

  /// Ids of messages showing edited text.
  Set<String> get edited => _texts.keys.toSet();

  bool isDeleted(String id) => _deleted.contains(id);

  /// The text [m] shows now: its latest edit, its own text, or null (deleted, or not a text).
  String? textOf(MessageRow m) {
    if (_deleted.contains(m.id) || m.kind != 'text') return null;
    return _texts[m.id] ?? _field(m, 'text');
  }
}

/// [rows] in display order (as `watchMessages` gives them). A change may come before its target
/// (sends can be stored out of order), so every row is indexed first.
MessageChanges messageChanges(Iterable<MessageRow> rows) {
  final byId = {for (final r in rows) r.id: r};
  final texts = <String, String>{};
  final deleted = <String>{};
  for (final r in rows) {
    if ((r.kind != 'edit' && r.kind != 'delete') || r.state == 'failed' || r.targetId == null) continue;
    final target = byId[r.targetId!];
    if (target == null || target.senderUserId != r.senderUserId || deleted.contains(target.id)) continue;
    if (r.kind == 'delete') {
      deleted.add(target.id);
      texts.remove(target.id);
    } else if (target.kind == 'text') {
      final text = _field(r, 'text');
      if (text != null) texts[target.id] = text;
    }
  }
  return MessageChanges._(texts, deleted);
}

/// The id [m] replies to, or null.
String? replyTargetOf(MessageRow m) => m.kind == 'text' ? _field(m, 'replyTo') : null;

/// The users a text @mentions (empty for other kinds).
List<String> mentionsOf(MessageRow m) {
  if (m.kind != 'text' || m.body == null) return const [];
  try {
    final j = jsonDecode(m.body!);
    final v = j is Map ? j['mentions'] : null;
    return v is List ? v.whereType<String>().toList() : const [];
  } on FormatException {
    return const [];
  }
}

String? _field(MessageRow m, String key) {
  if (m.body == null) return null;
  try {
    final j = jsonDecode(m.body!);
    final v = j is Map ? j[key] : null;
    return v is String ? v : null;
  } on FormatException {
    return null;
  }
}
