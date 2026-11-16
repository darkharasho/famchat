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
          MessageEntry(:final message, :final firstInGroup, :final lastInGroup) =>
            '${message.id}${firstInGroup ? '<' : ''}${lastInGroup ? '>' : ''}',
        })
    .join(' ');

void main() {
  group('buildTimeline', () {
    test('empty in, empty out', () => expect(buildTimeline(const []), isEmpty));

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
}
