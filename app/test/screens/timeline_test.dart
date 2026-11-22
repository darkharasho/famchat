import 'package:drift/drift.dart' show Value;
import 'package:famchat/chat/db/chat_db.dart';
import 'package:famchat/screens/chats/timeline.dart';
import 'package:flutter_test/flutter_test.dart';

MessageRow msg(String id, String from, DateTime at) => MessageRow(
      id: id,
      chatId: 'C',
      seq: 1,
      senderUserId: from,
      senderDeviceId: 'D',
      kind: 'text',
      body: '{"kind":"text","text":"x"}',
      targetId: null,
      envelope: null,
      createdAt: at.millisecondsSinceEpoch,
      state: 'sent',
    );

String describe(List<TimelineEntry> t) => t
    .map((e) => switch (e) {
          DayEntry(:final day) => '[${day.month}/${day.day}]',
          UnreadEntry() => '|new|',
          NoteEntry(:final afterSeq) => '(note $afterSeq)',
          MessageEntry(:final message, :final firstInGroup, :final lastInGroup) =>
            '${message.id}${firstInGroup ? '<' : ''}${lastInGroup ? '>' : ''}',
          AlbumEntry(:final items, :final firstInGroup, :final lastInGroup) =>
            '{${items.map((m) => m.id).join(',')}}${firstInGroup ? '<' : ''}${lastInGroup ? '>' : ''}',
        })
    .join(' ');

void main() {
  group('buildTimeline', () {
    test('empty in, empty out', () => expect(buildTimeline(const []), isEmpty));

    test('the "New messages" line goes above its message, after the day, and splits the run', () {
      final t = buildTimeline([
        msg('a', 'u1', DateTime(2026, 3, 3, 9, 0)),
        msg('b', 'u1', DateTime(2026, 3, 3, 9, 1)),
        msg('c', 'u1', DateTime(2026, 3, 3, 9, 2)),
        msg('d', 'u1', DateTime(2026, 3, 4, 9, 0)),
      ], unreadFrom: 'b');
      expect(describe(t), '[3/3] a<> |new| b< c> [3/4] d<>');
      expect(describe(buildTimeline([msg('d', 'u1', DateTime(2026, 3, 4, 9, 0))], unreadFrom: 'd')), '[3/4] |new| d<>');
    });

    test('the disappearing line goes right after its seq, splits the run, and sits before the outbox', () {
      MessageRow s(String id, int? seq, DateTime at) => msg(id, 'u1', at).copyWith(seq: Value(seq));
      final day = DateTime(2026, 3, 3, 9);
      final rows = [
        s('a', 1, day),
        s('b', 2, day.add(const Duration(minutes: 1))),
        s('c', 4, day.add(const Duration(minutes: 2))), // seq 3 was a hidden change
        s('p', null, day.add(const Duration(minutes: 3))),
      ];
      expect(describe(buildTimeline(rows, note: const NoteEntry(3, 'x'))), '[3/3] a< b> (note 3) c< p>');
      expect(describe(buildTimeline(rows, note: const NoteEntry(0, 'x'))), '(note 0) [3/3] a< b c p>');
      expect(describe(buildTimeline(rows, note: const NoteEntry(9, 'x'))), '[3/3] a< b c> (note 9) p<>');
      expect(describe(buildTimeline(rows.take(3).toList(), note: const NoteEntry(9, 'x'))), '[3/3] a< b c> (note 9)');
      expect(describe(buildTimeline(const [], note: const NoteEntry(5, 'x'))), '(note 5)');
    });

    test('a lone message starts a day and is a group of one', () {
      expect(describe(buildTimeline([msg('a', 'u1', DateTime(2026, 3, 3, 9))])), '[3/3] a<>');
    });

    test('runs from one sender within five minutes group together', () {
      final t = buildTimeline([
        msg('a', 'u1', DateTime(2026, 3, 3, 9, 0)),
        msg('b', 'u1', DateTime(2026, 3, 3, 9, 4)),
        msg('c', 'u1', DateTime(2026, 3, 3, 9, 9)), // 5 min after b: still grouped
        msg('d', 'u1', DateTime(2026, 3, 3, 9, 15)), // 6 min gap: new group
        msg('e', 'u2', DateTime(2026, 3, 3, 9, 15)), // other sender
      ]);
      expect(describe(t), '[3/3] a< b c> d<> e<>');
    });

    test('midnight adds a day separator and breaks the group', () {
      final t = buildTimeline([
        msg('a', 'u1', DateTime(2026, 3, 3, 23, 58)),
        msg('b', 'u1', DateTime(2026, 3, 4, 0, 1)),
      ]);
      expect(describe(t), '[3/3] a<> [3/4] b<>');
    });
  });

  group('dayLabel', () {
    final now = DateTime(2026, 11, 16, 14); // a Monday
    test('today and yesterday', () {
      expect(dayLabel(DateTime(2026, 11, 16), now), 'Today');
      expect(dayLabel(DateTime(2026, 11, 15, 23), now), 'Yesterday');
    });
    test('weekday within the week', () {
      expect(dayLabel(DateTime(2026, 11, 12), now), 'Thursday');
      expect(dayLabel(DateTime(2026, 11, 10), now), 'Tuesday');
    });
    test('a date further back, with the year only when it differs', () {
      expect(dayLabel(DateTime(2026, 11, 9), now), 'November 9');
      expect(dayLabel(DateTime(2025, 3, 3), now), 'March 3, 2025');
    });
    test('a future date (clock skew) shows the date', () {
      expect(dayLabel(DateTime(2026, 11, 18), now), 'November 18');
    });
  });

  group('albums', () {
    final t0 = DateTime(2026, 11, 22, 10);
    MessageRow at(String id, String from, int sec) => msg(id, from, t0.add(Duration(seconds: sec)));
    const albums = {'a1': 'A', 'a2': 'A', 'a3': 'A', 'b1': 'B', 'b2': 'B'};
    String? albumOf(MessageRow m) => albums[m.id];

    test('items sent together become one entry, in a run with the messages around them', () {
      final t = buildTimeline([at('t1', 'x', 0), at('a1', 'x', 1), at('a2', 'x', 2), at('a3', 'x', 3), at('t2', 'x', 4)],
          albumOf: albumOf);
      expect(describe(t), '[11/22] t1< {a1,a2,a3} t2>');
    });

    test('an album interrupted by another message shows as two; a lone item is a plain message', () {
      final t = buildTimeline([at('a1', 'x', 0), at('a2', 'x', 1), at('y', 'y', 2), at('a3', 'x', 3), at('b1', 'x', 4)],
          albumOf: albumOf);
      expect(describe(t), '[11/22] {a1,a2}<> y<> a3< b1>');
    });

    test('albums never span the New messages line or two senders', () {
      final t = buildTimeline([at('a1', 'x', 0), at('a2', 'x', 1), at('a3', 'x', 2)], albumOf: albumOf, unreadFrom: 'a2');
      expect(describe(t), '[11/22] a1<> |new| {a2,a3}<>');
      final u = buildTimeline([at('b1', 'x', 0), at('b2', 'y', 1)], albumOf: albumOf);
      expect(describe(u), '[11/22] b1<> b2<>');
    });
  });
}
