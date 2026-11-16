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

final class MessageEntry extends TimelineEntry {
  const MessageEntry(this.message, {required this.firstInGroup, required this.lastInGroup});

  final MessageRow message;
  final bool firstInGroup, lastInGroup;
}

DateTime _at(MessageRow m) => DateTime.fromMillisecondsSinceEpoch(m.createdAt);
DateTime _dayOf(DateTime t) => DateTime(t.year, t.month, t.day);

bool _sameRun(MessageRow a, MessageRow b) {
  final ta = _at(a), tb = _at(b);
  return a.senderUserId == b.senderUserId && _dayOf(ta) == _dayOf(tb) && tb.difference(ta).abs() <= groupGap;
}

/// [visible] oldest first → the entries to draw, oldest first.
List<TimelineEntry> buildTimeline(List<MessageRow> visible) {
  final out = <TimelineEntry>[];
  for (var i = 0; i < visible.length; i++) {
    final m = visible[i];
    final prev = i > 0 ? visible[i - 1] : null;
    final next = i + 1 < visible.length ? visible[i + 1] : null;
    final day = _dayOf(_at(m));
    if (prev == null || _dayOf(_at(prev)) != day) out.add(DayEntry(day));
    out.add(MessageEntry(
      m,
      firstInGroup: prev == null || !_sameRun(prev, m),
      lastInGroup: next == null || !_sameRun(m, next),
    ));
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
