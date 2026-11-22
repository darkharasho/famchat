// How a conversation is laid out: day separators, and runs of messages from one person that
// render as one stack of bubbles.
import '../../chat/db/chat_db.dart';

/// Messages from one sender at most this far apart (and on the same day) form one run.
const groupGap = Duration(minutes: 5);

sealed class TimelineEntry {
  const TimelineEntry();
}

/// "Today", "Yesterday", … before the first message of each local day.
final class DayEntry extends TimelineEntry {
  const DayEntry(this.day);

  /// Local midnight.
  final DateTime day;
}

/// "New messages": the line above the first message that was unread when the chat was opened.
final class UnreadEntry extends TimelineEntry {
  const UnreadEntry();
}

final class MessageEntry extends TimelineEntry {
  const MessageEntry(this.message, {required this.firstInGroup, required this.lastInGroup});

  final MessageRow message;
  final bool firstInGroup, lastInGroup;
}

/// Photos and videos sent together (one album id, one sender, nothing in between): one bubble.
/// [items] oldest first; the last carries the caption.
final class AlbumEntry extends TimelineEntry {
  const AlbumEntry(this.items, {required this.firstInGroup, required this.lastInGroup});

  final List<MessageRow> items;
  final bool firstInGroup, lastInGroup;
}

DateTime _at(MessageRow m) => DateTime.fromMillisecondsSinceEpoch(m.createdAt);
DateTime _dayOf(DateTime t) => DateTime(t.year, t.month, t.day);

/// Game cards, game event lines and pin lines stand alone; bubbles either side of them start or end a run.
bool _standsAlone(MessageRow m) => m.kind == 'game' || m.kind == 'move' || m.kind == 'pin';

bool _sameRun(MessageRow a, MessageRow b) {
  if (_standsAlone(a) || _standsAlone(b)) return false;
  final ta = _at(a), tb = _at(b);
  return a.senderUserId == b.senderUserId && _dayOf(ta) == _dayOf(tb) && tb.difference(ta).abs() <= groupGap;
}

/// [visible] oldest first → the entries to draw, oldest first. [unreadFrom]: the id of the message
/// to put the "New messages" line above (after its day's separator); a run never spans the line.
/// [albumOf]: a message's album id (null for none, or for one that shouldn't group, e.g. deleted).
List<TimelineEntry> buildTimeline(List<MessageRow> visible, {String? unreadFrom, String? Function(MessageRow)? albumOf}) {
  // Units: single messages, or albums of 2+.
  final units = <List<MessageRow>>[];
  for (final m in visible) {
    final album = albumOf?.call(m);
    final last = units.isEmpty ? null : units.last;
    if (album != null &&
        last != null &&
        m.id != unreadFrom &&
        albumOf!(last.last) == album &&
        last.last.senderUserId == m.senderUserId &&
        _dayOf(_at(last.last)) == _dayOf(_at(m))) {
      last.add(m);
    } else {
      units.add([m]);
    }
  }
  final out = <TimelineEntry>[];
  for (var i = 0; i < units.length; i++) {
    final u = units[i];
    final first = u.first, lastRow = u.last;
    final prev = i > 0 ? units[i - 1].last : null;
    final next = i + 1 < units.length ? units[i + 1].first : null;
    final day = _dayOf(_at(first));
    if (prev == null || _dayOf(_at(prev)) != day) out.add(DayEntry(day));
    final unread = first.id == unreadFrom;
    if (unread) out.add(const UnreadEntry());
    final firstInGroup = prev == null || unread || !_sameRun(prev, first);
    final lastInGroup = next == null || next.id == unreadFrom || !_sameRun(lastRow, next);
    out.add(u.length > 1
        ? AlbumEntry(List.unmodifiable(u), firstInGroup: firstInGroup, lastInGroup: lastInGroup)
        : MessageEntry(first, firstInGroup: firstInGroup, lastInGroup: lastInGroup));
  }
  return out;
}

const _weekdays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
const _months = [
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December',
];

/// "Today", "Yesterday", "Thursday" (this past week), "March 3", or "March 3, 2025".
String dayLabel(DateTime day, DateTime now) {
  final d = _dayOf(day), today = _dayOf(now);
  // Calendar days, not 24-hour spans (daylight saving moves midnight by an hour).
  final back = DateTime.utc(today.year, today.month, today.day)
      .difference(DateTime.utc(d.year, d.month, d.day))
      .inDays;
  if (back == 0) return 'Today';
  if (back == 1) return 'Yesterday';
  if (back > 1 && back < 7) return _weekdays[d.weekday - 1];
  final date = '${_months[d.month - 1]} ${d.day}';
  return d.year == today.year ? date : '$date, ${d.year}';
}
