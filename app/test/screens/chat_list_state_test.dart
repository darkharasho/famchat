// Pinned, archived and marked-unread chats in the chat list (docs/protocol.md "Chats").
import 'package:famchat/chat/db/chat_db.dart';
import 'package:famchat/chat/providers.dart';
import 'package:famchat/main.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../support/chat_harness.dart';
import '../support/fake_chat_backend.dart';

MessageRow text(String id, String chatId, int seq, String from, String body, {required int at}) => MessageRow(
      id: id,
      chatId: chatId,
      seq: seq,
      senderUserId: from,
      senderDeviceId: 'x',
      kind: 'text',
      body: '{"kind":"text","text":"$body"}',
      targetId: null,
      envelope: null,
      createdAt: at,
      state: 'sent',
    );

void main() {
  late FakeChatBackend backend;
  late TestDevice alice, bob, carol;

  setUp(() async {
    backend = FakeChatBackend();
    alice = await backend.addUser('Alice');
    bob = await backend.addUser('Bob');
    carol = await backend.addUser('Carol');
  });

  ProviderContainer c(WidgetTester tester) => ProviderScope.containerOf(tester.element(find.byType(FamChatApp)));

  /// A direct chat with Bob (older) and a group (newer), each with a message.
  Future<(String, String)> twoChats(WidgetTester tester) async {
    setWindow(tester, const Size(400, 800));
    await pumpChatApp(tester, alice);
    final ids = await inApp(tester, () async {
      final sync = c(tester).read(chatSyncProvider)!;
      final direct = await sync.openDirect(bob.userId);
      final group = await sync.createGroup('Cousins', [bob.userId, carol.userId]);
      final now = DateTime.now().millisecondsSinceEpoch;
      await alice.db.insertMessageIfAbsent(text('m1', direct, 1, bob.userId, 'hi', at: now - 2000));
      await alice.db.insertMessageIfAbsent(text('m2', group, 1, carol.userId, 'pizza?', at: now - 1000));
      await alice.db.setMyLastRead(direct, 1);
      await alice.db.setMyLastRead(group, 1);
      return (direct, group);
    });
    await settle(tester);
    return ids;
  }

  double top(WidgetTester tester, String text) => tester.getTopLeft(find.text(text)).dy;

  chatTestWidgets('pinning moves a chat to the top, on the server too, and unpinning puts it back', (tester) async {
    final (direct, _) = await twoChats(tester);
    expect(top(tester, 'Bob'), greaterThan(top(tester, 'Cousins')));

    await tester.longPress(find.text('Bob'));
    await settle(tester);
    await tester.tap(find.byKey(const Key('chat-action-pin')));
    await settle(tester);
    expect(top(tester, 'Bob'), lessThan(top(tester, 'Cousins')));
    expect(find.byIcon(Icons.push_pin_rounded), findsOneWidget);
    expect(backend.chatDto(direct, alice.userId).pinnedAt, isNotNull);
    expect(backend.chatDto(direct, bob.userId).pinnedAt, isNull, reason: 'only mine');

    await tester.longPress(find.text('Bob'));
    await settle(tester);
    await tester.tap(find.byKey(const Key('chat-action-unpin')));
    await settle(tester);
    expect(top(tester, 'Bob'), greaterThan(top(tester, 'Cousins')));
    expect(backend.chatDto(direct, alice.userId).pinnedAt, isNull);
  });

  chatTestWidgets('an archived chat moves behind "Archived" and comes back when a message arrives', (tester) async {
    final (_, group) = await twoChats(tester);
    await tester.longPress(find.text('Cousins'));
    await settle(tester);
    await tester.tap(find.byKey(const Key('chat-action-archive')));
    await settle(tester);
    expect(find.text('Cousins'), findsNothing);
    expect(find.byKey(const Key('archived-chats')), findsOneWidget);
    expect(backend.chatDto(group, alice.userId).archivedAt, isNotNull);

    await tester.tap(find.byKey(const Key('archived-chats')));
    await settle(tester);
    expect(find.text('Cousins'), findsOneWidget);
    expect(find.text('Bob'), findsNothing);
    await tester.tap(find.byKey(const Key('archive-back')));
    await settle(tester);
    expect(find.text('Bob'), findsOneWidget);

    // A newer message brings it back.
    await inApp(tester, () async {
      final at = (await alice.db.chatById(group))!.archivedAt! + 1000;
      await alice.db.insertMessageIfAbsent(text('m3', group, 2, carol.userId, 'tacos?', at: at));
    });
    await settle(tester);
    expect(find.text('Cousins'), findsOneWidget);
    expect(find.byKey(const Key('archived-chats')), findsNothing);
  });

  chatTestWidgets('a muted archived chat stays archived when a message arrives', (tester) async {
    final (_, group) = await twoChats(tester);
    await inApp(tester, () async {
      final sync = c(tester).read(chatSyncProvider)!;
      await sync.archive(group, true);
      await sync.mute(group, DateTime.now().add(const Duration(days: 1)).millisecondsSinceEpoch);
      final at = (await alice.db.chatById(group))!.archivedAt! + 1000;
      await alice.db.insertMessageIfAbsent(text('m3', group, 2, carol.userId, 'tacos?', at: at));
    });
    await settle(tester);
    expect(find.text('Cousins'), findsNothing);
    expect(find.byKey(const Key('archived-chats')), findsOneWidget);
  });

  chatTestWidgets('mark as unread shows a dot until the chat is opened', (tester) async {
    final (direct, _) = await twoChats(tester);
    expect(find.byKey(const Key('marked-unread-dot')), findsNothing);
    await tester.longPress(find.text('Bob'));
    await settle(tester);
    await tester.tap(find.byKey(const Key('chat-action-markUnread')));
    await settle(tester);
    expect(find.byKey(const Key('marked-unread-dot')), findsOneWidget);
    expect(backend.chatDto(direct, alice.userId).markedUnread, isTrue);

    await tester.tap(find.text('Bob'));
    await settle(tester);
    expect((await inApp(tester, () => alice.db.chatById(direct)))!.markedUnread, isFalse);
    expect(backend.chatDto(direct, alice.userId).markedUnread, isFalse);
  });

  test('pinned chats sort first, newest pin first, then by activity', () {
    ChatListItem item(String id, {int? pinnedAt, int at = 0}) => ChatListItem(
          chat: ChatRow(
            id: id,
            kind: 'group',
            createdBy: 'me',
            currentEpoch: 1,
            epochReady: true,
            lastSeq: 0,
            createdAt: 0,
            lastMessageAt: at,
            myLastReadSeq: 0,
            syncedSeq: 0,
            pinnedAt: pinnedAt,
            markedUnread: false,
          ),
          members: const [],
          last: null,
          unread: 0,
        );
    final sorted = [
      item('a', at: 50),
      item('b', pinnedAt: 1, at: 1),
      item('c', at: 90),
      item('d', pinnedAt: 5, at: 2),
    ]..sort(compareChatListItems);
    expect(sorted.map((i) => i.chat.id), ['d', 'b', 'c', 'a']);
  });
}
