import 'dart:convert';

import 'package:famchat/chat/db/chat_db.dart';
import 'package:famchat/chat/message_changes.dart';
import 'package:famchat/chat/wire.dart';
import 'package:famchat/main.dart';
import 'package:famchat/router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../support/chat_harness.dart';
import '../support/fake_chat_backend.dart';

const directId = '01JC0000000000000000000001';
const groupId = '01JC0000000000000000000002';

ChatDto chat(String id, String kind, List<String> members) => ChatDto(
      id: id,
      kind: kind,
      title: kind == 'group' ? 'Cousins' : null,
      createdBy: members.first,
      currentEpoch: 1,
      epochReady: true,
      lastSeq: 0,
      lastMessageAt: null,
      createdAt: 1,
      members: [for (final m in members) MemberDto(userId: m, joinedSeq: 0, lastReadSeq: 0)],
    );

MessageRow text(String id, String chatId, String from, String body, {bool forwarded = false}) => MessageRow(
      id: id,
      chatId: chatId,
      seq: 1,
      senderUserId: from,
      senderDeviceId: 'x',
      kind: 'text',
      body: jsonEncode({'kind': 'text', 'text': body, if (forwarded) 'forwarded': true}),
      targetId: null,
      envelope: null,
      createdAt: DateTime.now().millisecondsSinceEpoch,
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

  Future<void> open(WidgetTester tester, List<MessageRow> messages) async {
    setWindow(tester, const Size(400, 800));
    await pumpChatApp(tester, alice);
    await inApp(tester, () async {
      await alice.db.upsertChat(chat(directId, 'direct', [alice.userId, bob.userId]));
      await alice.db.upsertChat(chat(groupId, 'group', [alice.userId, bob.userId, carol.userId]));
      for (final m in messages) {
        await alice.db.insertMessageIfAbsent(m);
      }
    });
    ProviderScope.containerOf(tester.element(find.byType(FamChatApp))).read(routerProvider).go('/chats/$directId');
    await settle(tester);
  }

  chatTestWidgets('Forward sends a copy to the chat picked, marked forwarded', (tester) async {
    await open(tester, [text('m1', directId, bob.userId, 'cake at 5')]);
    await tester.longPress(find.text('cake at 5'));
    await settle(tester);
    await tester.tap(find.text('Forward'));
    await settle(tester);
    expect(find.text('Forward to…'), findsOneWidget);
    expect(find.byKey(const Key('forward-to-$directId')), findsNothing, reason: 'not the chat it is in');
    await tester.tap(find.byKey(const Key('forward-to-$groupId')));
    await settle(tester);
    expect(find.text('Forwarded to Cousins'), findsOneWidget);
    final sent = (await inApp(tester, () => alice.db.pendingOutbox(alice.deviceId))).single;
    expect(sent.chatId, groupId);
    expect(isForwarded(sent), isTrue);
    expect(jsonDecode(sent.body!)['text'], 'cake at 5');
  });

  chatTestWidgets('a forwarded message says so', (tester) async {
    await open(tester, [text('m1', directId, bob.userId, 'from elsewhere', forwarded: true)]);
    expect(find.text('Forwarded'), findsOneWidget);
  });
}
