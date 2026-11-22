import 'dart:async';

import 'package:clock/clock.dart';
import 'package:famchat/chat/db/chat_db.dart';
import 'package:famchat/chat/providers.dart';
import 'package:famchat/chat/unread_total.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final t0 = DateTime.utc(2026, 11, 18, 12);

ChatListItem item(String id, int unread, {DateTime? mutedUntil}) => ChatListItem(
      chat: ChatRow(
        id: id,
        kind: 'group',
        createdBy: 'me',
        currentEpoch: 1,
        epochReady: true,
        lastSeq: 10,
        createdAt: 0,
        myLastReadSeq: 0,
        markedUnread: false,
        syncedSeq: 0,
        mutedUntil: mutedUntil?.millisecondsSinceEpoch,
      ),
      members: const [],
      last: null,
      unread: unread,
    );

void main() {
  test('unreadTotal sums the chats that are not muted now', () {
    final items = [
      item('a', 3),
      item('b', 4, mutedUntil: t0.add(const Duration(hours: 1))),
      item('c', 2, mutedUntil: t0.subtract(const Duration(minutes: 1))), // the mute ended
      item('d', 0),
    ];
    expect(unreadTotal(items, t0), 5);
    expect(unreadTotal(items, t0.add(const Duration(hours: 1))), 9);
    expect(unreadTotal(const [], t0), 0);
  });

  test('the provider is 0 until the chat list loads, then follows it', () async {
    final list = StreamController<List<ChatListItem>>();
    final c = ProviderContainer(overrides: [chatListProvider.overrideWith((ref) => list.stream)]);
    addTearDown(c.dispose);
    final seen = <int>[];
    c.listen(unreadTotalProvider, (_, n) => seen.add(n), fireImmediately: true);
    expect(seen, [0]);
    list.add([item('a', 2), item('b', 1)]);
    await pumpEventQueue();
    list.add([item('a', 0), item('b', 1)]);
    await pumpEventQueue();
    list.add([item('a', 0), item('b', 0)]);
    await pumpEventQueue();
    expect(seen, [0, 3, 1, 0]);
  });

  test('the provider counts a muted chat again once its mute ends', () {
    fakeAsync((async) {
      withClock(async.getClock(t0), () {
        final c = ProviderContainer(overrides: [
          chatListProvider.overrideWith(
            (ref) => Stream.value([item('a', 1), item('b', 4, mutedUntil: t0.add(const Duration(minutes: 30)))]),
          ),
        ]);
        final seen = <int>[];
        c.listen(unreadTotalProvider, (_, n) => seen.add(n), fireImmediately: true);
        async.elapse(const Duration(seconds: 1));
        expect(seen, [0, 1]);
        async.elapse(const Duration(minutes: 28));
        expect(seen.last, 1);
        async.elapse(const Duration(minutes: 2));
        expect(seen.last, 5);
        c.dispose();
      });
    });
  });
}
