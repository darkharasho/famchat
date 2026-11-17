import 'package:drift/drift.dart' show Value;
import 'package:famchat/chat/db/chat_db.dart';
import 'package:famchat/chat/wire.dart';
import 'package:famchat/screens/chats/conversation_view.dart';
import 'package:famchat/main.dart';
import 'package:famchat/router.dart';
import 'package:famchat/screens/chats/new_chat_screen.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/chat_harness.dart';
import '../support/fake_chat_backend.dart';

ChatDto dto(String id, String kind, List<String> members, {String? title, int at = 1}) => ChatDto(
      id: id,
      kind: kind,
      title: title,
      createdBy: members.first,
      currentEpoch: 1,
      epochReady: true,
      lastSeq: 0,
      lastMessageAt: at,
      createdAt: 1,
      members: [for (final m in members) MemberDto(userId: m, joinedSeq: 0, lastReadSeq: 0)],
    );

MessageRow text(String id, String chatId, int seq, String from, String body) => MessageRow(
      id: id,
      chatId: chatId,
      seq: seq,
      senderUserId: from,
      senderDeviceId: 'x',
      kind: 'text',
      body: '{"kind":"text","text":"$body"}',
      targetId: null,
      envelope: null,
      createdAt: 100 + seq,
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

  Future<void> seed(WidgetTester tester) => tester.runAsync(() async {
        final db = alice.db;
        await db.bindDevice(alice.deviceId);
        await db.upsertChat(dto('direct1', 'direct', [alice.userId, bob.userId], at: 100));
        await db.upsertChat(dto('group1', 'group', [alice.userId, bob.userId, carol.userId], title: 'Cousins', at: 200));
        await db.insertMessageIfAbsent(text('m1', 'direct1', 1, bob.userId, 'hi'));
        await db.insertMessageIfAbsent(text('m2', 'direct1', 2, bob.userId, 'you there?'));
      });

  chatTestWidgets('chat list shows chats newest first with unread badges', (tester) async {
    setWindow(tester, const Size(400, 800));
    await seed(tester);
    await pumpChatApp(tester, alice);
    expect(find.text('Cousins'), findsOneWidget);
    expect(find.text('Bob'), findsOneWidget);
    expect(tester.getTopLeft(find.text('Bob')).dy, greaterThan(tester.getTopLeft(find.text('Cousins')).dy));
    expect(find.text('you there?'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
  });

  chatTestWidgets('a muted chat shows a muted bell; the preview shows edits and deletes', (tester) async {
    setWindow(tester, const Size(400, 800));
    await seed(tester);
    await tester.runAsync(() async {
      await alice.db.setMutedUntil('group1', DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch);
      await alice.db.insertMessageIfAbsent(text('m3', 'group1', 1, carol.userId, 'pizza?'));
      await alice.db.insertMessageIfAbsent(text('m4', 'group1', 2, carol.userId, 'x').copyWith(
            kind: 'edit',
            body: const Value('{"kind":"edit","target":"m3","text":"tacos?"}'),
            targetId: const Value('m3'),
          ));
      await alice.db.insertMessageIfAbsent(text('m5', 'direct1', 3, bob.userId, 'x').copyWith(
            kind: 'delete',
            body: const Value('{"kind":"delete","target":"m2"}'),
            targetId: const Value('m2'),
          ));
    });
    await pumpChatApp(tester, alice);
    expect(find.byIcon(Icons.notifications_off_outlined), findsOneWidget);
    expect(find.text('tacos?'), findsOneWidget);
    expect(find.text('Deleted a message'), findsOneWidget);
    expect(find.text('1'), findsWidgets, reason: 'edits and deletes are not unread');
  });

  chatTestWidgets('tapping a chat opens it full screen on a phone', (tester) async {
    setWindow(tester, const Size(400, 800));
    await seed(tester);
    await pumpChatApp(tester, alice);
    await tester.tap(find.text('Bob'));
    await settle(tester);
    expect(find.byType(ConversationView), findsOneWidget);
    expect(find.text('Cousins'), findsNothing);
  });

  chatTestWidgets('a chat opens on top of the list: back (or the swipe) pops to it', (tester) async {
    setWindow(tester, const Size(400, 800));
    await seed(tester);
    await pumpChatApp(tester, alice);
    await tester.tap(find.text('Bob'));
    await settle(tester);
    final router = ProviderScope.containerOf(tester.element(find.byType(FamChatApp))).read(routerProvider);
    expect(router.canPop(), isTrue);
    await tester.binding.handlePopRoute(); // the system back gesture
    await settle(tester);
    expect(find.byType(ConversationView), findsNothing);
    expect(find.text('Cousins'), findsOneWidget);
  });

  chatTestWidgets('wide windows show the conversation beside the list', (tester) async {
    setWindow(tester, const Size(1000, 800));
    await seed(tester);
    await pumpChatApp(tester, alice);
    expect(find.text('Pick a chat'), findsOneWidget);
    await tester.tap(find.text('Bob'));
    await settle(tester);
    expect(find.byType(ConversationView), findsOneWidget);
    expect(find.text('Cousins'), findsOneWidget);
  });

  chatTestWidgets('empty state offers New chat', (tester) async {
    setWindow(tester, const Size(400, 800));
    await pumpChatApp(tester, alice);
    expect(find.text('No chats yet'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'New chat'));
    await settle(tester);
    expect(find.byType(NewChatScreen), findsOneWidget);
  });
}
