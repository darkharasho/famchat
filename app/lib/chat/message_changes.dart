// Edits and deletes (docs/protocol.md "Plaintext"): messages that change an earlier one. They count
// only when sent by the earlier message's sender.
import 'dart:convert';

import 'db/chat_db.dart';
import 'plaintext.dart';

/// Kinds that change another message instead of showing as one (poll votes and ends included).
const changeKinds = {'reaction', 'edit', 'delete', 'pin', 'vote', 'poll_end', 'transcript'};

/// Kinds the timeline doesn't show as messages: changes, and game moves (which are sent non-silent
/// and count as activity and unread, unlike changes).
const timelineHiddenKinds = {...changeKinds, 'move'};

/// Kinds whose text is an optional caption (photos and videos).
const captionKinds = {'photo', 'video'};

/// The edits and deletes in force over a chat's messages.
class MessageChanges {
  MessageChanges._(this._texts, this._deleted, this._previews, this.pinned, this.pinEvents);

  /// Ids of the pinned messages, newest pin first, at most [maxPins].
  final List<String> pinned;

  /// The pin and unpin events that count (their target is here and not deleted), in order: the
  /// timeline shows each as a line.
  final List<MessageRow> pinEvents;

  final Map<String, String> _texts;
  final Set<String> _deleted;

  /// Link previews attached after sending (preview-only edits), by message id.
  final Map<String, LinkPreview> _previews;

  /// Ids of messages showing edited text.
  Set<String> get edited => _texts.keys.toSet();

  bool isDeleted(String id) => _deleted.contains(id);

  /// The text [m] shows now: its latest edit, its own text or caption, or null (deleted, not a text,
  /// or media without a caption).
  String? textOf(MessageRow m) {
    if (_deleted.contains(m.id)) return null;
    if (m.kind == 'text') return _texts[m.id] ?? _field(m, 'text');
    if (captionKinds.contains(m.kind)) return _texts[m.id] ?? _caption(m);
    return null;
  }

  /// [m]'s link preview (sent with it, or attached later), while the text it shows still has that
  /// link.
  LinkPreview? previewOf(MessageRow m) {
    final shown = m.kind == 'text' ? textOf(m) : null;
    if (shown == null) return null;
    final late = _previews[m.id];
    if (late != null && previewFits(shown, late.url)) return late;
    final p = _decode(m);
    final own = p is TextBody ? p.preview : null;
    return own != null && previewFits(shown, own.url) ? own : null;
  }
}

/// [rows] in display order (as `watchMessages` gives them). A change may come before its target
/// (sends can be stored out of order), so every row is indexed first.
MessageChanges messageChanges(Iterable<MessageRow> rows) {
  final byId = {for (final r in rows) r.id: r};
  final texts = <String, String>{};
  final deleted = <String>{};
  final previews = <String, LinkPreview>{};
  for (final r in rows) {
    if ((r.kind != 'edit' && r.kind != 'delete') || r.state == 'failed' || r.targetId == null) continue;
    final target = byId[r.targetId!];
    if (target == null || target.senderUserId != r.senderUserId || deleted.contains(target.id)) continue;
    if (r.kind == 'delete') {
      deleted.add(target.id);
      texts.remove(target.id);
      previews.remove(target.id);
    } else if (target.kind == 'text' || captionKinds.contains(target.kind)) {
      final edit = _decode(r);
      if (edit is! EditBody) continue;
      if (!edit.previewOnly) {
        texts[target.id] = edit.text;
        continue;
      }
      if (target.kind != 'text') continue;
      // A preview-only edit: it attaches its preview to the text as it stands (not marking it
      // edited); one made for other text is stale and ignored.
      final preview = edit.preview;
      if (preview != null &&
          edit.text == (texts[target.id] ?? _field(target, 'text')) &&
          previewFits(edit.text, preview.url)) {
        previews[target.id] = preview;
      }
    }
  }
  // Pins, in event order (rows are in order): pinning moves a target to the newest place, and
  // pinning past [maxPins] unpins the oldest for good (unpinning or deleting another later doesn't
  // bring it back). Deleted targets drop out at the end.
  final pinEvents = <MessageRow>[];
  final current = <String>[]; // oldest first
  for (final r in rows) {
    if (r.kind != 'pin' || r.state == 'failed' || r.targetId == null) continue;
    final target = byId[r.targetId!];
    if (target == null || timelineHiddenKinds.contains(target.kind)) continue;
    final p = _decode(r);
    if (p is! PinBody) continue;
    if (!deleted.contains(target.id)) pinEvents.add(r);
    current.remove(target.id);
    if (p.pinned) {
      current.add(target.id);
      if (current.length > maxPins) current.removeAt(0);
    }
  }
  final pinned = [for (final id in current.reversed) if (!deleted.contains(id)) id];
  return MessageChanges._(texts, deleted, previews, pinned, pinEvents);
}

/// The id [m] replies to, or null.
String? replyTargetOf(MessageRow m) =>
    m.kind == 'text' || m.kind == 'poll' || m.kind == 'file' || captionKinds.contains(m.kind) ? _field(m, 'replyTo') : null;

/// Whether a preview of [url] belongs with [text]: the text still has that link.
bool previewFits(String text, String url) => text.contains(url.replaceFirst(RegExp(r'/$'), ''));

Plaintext? _decode(MessageRow m) {
  if (m.body == null) return null;
  try {
    return Plaintext.decode(utf8.encode(m.body!));
  } on FormatException {
    return null;
  }
}

/// Whether [m] is a copy forwarded from another message.
bool isForwarded(MessageRow m) {
  if (m.body == null) return false;
  try {
    final j = jsonDecode(m.body!);
    return j is Map && j['forwarded'] == true;
  } on FormatException {
    return false;
  }
}

/// The users a text or caption @mentions (empty for other kinds).
List<String> mentionsOf(MessageRow m) {
  if ((m.kind != 'text' && !captionKinds.contains(m.kind)) || m.body == null) return const [];
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

/// [m]'s caption as sent, if it checks out (see `Captioned`).
String? _caption(MessageRow m) {
  final c = _field(m, 'caption');
  return c == null ? null : validMessageText(c);
}
