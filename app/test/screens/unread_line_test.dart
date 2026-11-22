// The "New messages" line, and who read my messages in a group.
import 'package:famchat/chat/db/chat_db.dart';
import 'package:famchat/chat/wire.dart';
import 'package:famchat/main.dart';
import 'package:famchat/router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../support/chat_harness.dart';
import '../support/fake_chat_backend.dart';

const chatId = '01JC0000000000000000000001';

ChatDto chatOf(String kind, List<String> ids, {int readSeq = 0}) => ChatDto(
      id: chatId,
      kind: kind,
      title: kind == 'group' ? 'G' : null,
      createdBy: ids.first,
      currentEpoch: 1,
      epochReady: true,
      lastSeq: 0,
      lastMessageAt: null,
      createdAt: 1,
      members: [
        for (final (i, u) in ids.indexed) MemberDto(userId: u, joinedSeq: 0, lastReadSeq: i == 0 ? readSeq : 0),
      ],
    );

MessageRow row(String id, int seq, String from, String text) => MessageRow(
      id: id,
      chatId: chatId,
      seq: seq,
      senderUserId: from,
      senderDeviceId: 'x',
      kind: 'text',
      body: '{"kind":"text","text":"$text"}',
      targetId: null,
      envelope: null,
      // A minute apart, so every message has its own bubble and time.
      createdAt: DateTime.now().subtract(Duration(minutes: 100 - seq)).millisecondsSinceEpoch,
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

  Future<void> open(WidgetTester tester, ChatDto chat, List<MessageRow> messages) async {
    setWindow(tester, const Size(400, 800));
    await pumpChatApp(tester, alice);
    await inApp(tester, () async {
      await alice.db.upsertChat(chat);
      for (final m in messages) {
        await alice.db.insertMessageIfAbsent(m);
      }
    });
    ProviderScope.containerOf(tester.element(find.byType(FamChatApp))).read(routerProvider).go('/chats/$chatId');
    await settle(tester);
  }

  chatTestWidgets('the line sits above the first message unread on opening, and stays after it is read', (tester) async {
    await open(tester, chatOf('direct', [alice.userId, bob.userId], readSeq: 2), [
      row('m1', 1, bob.userId, 'one'),
      row('m2', 2, alice.userId, 'two'),
      row('m3', 3, bob.userId, 'three'),
      row('m4', 4, bob.userId, 'four'),
    ]);
    expect(find.text('New messages'), findsOneWidget);
    final line = tester.getTopLeft(find.text('New messages')).dy;
    expect(line, greaterThan(tester.getTopLeft(find.text('two')).dy));
    expect(line, lessThan(tester.getTopLeft(find.text('three')).dy));
    expect((await inApp(tester, () => alice.db.chatById(chatId)))!.myLastReadSeq, 4);
    await inApp(tester, () => alice.db.insertMessageIfAbsent(row('m5', 5, bob.userId, 'five')));
    await settle(tester);
    expect(find.text('New messages'), findsOneWidget, reason: 'it stays where it was');
  });

  chatTestWidgets('no line when everything was read', (tester) async {
    await open(tester, chatOf('direct', [alice.userId, bob.userId], readSeq: 2), [
      row('m1', 1, bob.userId, 'one'),
      row('m2', 2, alice.userId, 'two'),
    ]);
    expect(find.text('New messages'), findsNothing);
  });

  chatTestWidgets('with many unread, the chat opens at the line instead of the bottom', (tester) async {
    await open(tester, chatOf('direct', [alice.userId, bob.userId], readSeq: 1), [
      row('m1', 1, bob.userId, 'old'),
      for (var i = 2; i <= 40; i++) row('m$i', i, bob.userId, 'unread $i'),
    ]);
    expect(find.text('New messages'), findsOneWidget);
    final top = tester.getTopLeft(find.text('New messages')).dy;
    expect(top, greaterThan(0));
    expect(top, lessThan(800));
    expect(find.text('unread 40'), findsNothing, reason: 'the newest are below, still to read');
  });

  chatTestWidgets('in a group, my message shows who read it', (tester) async {
    await open(tester, chatOf('group', [alice.userId, bob.userId, carol.userId]), [
      row('m1', 1, alice.userId, 'dinner at 6?'),
    ]);
    await inApp(tester, () => alice.db.setMemberRead(chatId, bob.userId, 1));
    await settle(tester);
    expect(find.byKey(const Key('read-icon')), findsOneWidget);
    await tester.tap(find.byKey(const Key('read-icon')));
    await settle(tester);
    final sheet = find.byKey(const Key('readers-sheet'));
    expect(sheet, findsOneWidget);
    expect(find.descendant(of: sheet, matching: find.text('Read by')), findsOneWidget);
    expect(find.descendant(of: sheet, matching: find.text('Bob')), findsOneWidget);
    expect(find.descendant(of: sheet, matching: find.text('Not read yet')), findsOneWidget);
    expect(find.descendant(of: sheet, matching: find.text('Carol')), findsOneWidget);
  });

  chatTestWidgets('a direct chat has no "Read by" action', (tester) async {
    await open(tester, chatOf('direct', [alice.userId, bob.userId]), [row('m1', 1, alice.userId, 'hey')]);
    await tester.longPress(find.text('hey'));
    await settle(tester);
    expect(find.text('Read by'), findsNothing);
  });
}
