import 'dart:convert';

import 'package:famchat/chat/db/chat_db.dart';
import 'package:famchat/chat/plaintext.dart';
import 'package:famchat/chat/wire.dart';
import 'package:famchat/main.dart';
import 'package:famchat/router.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../support/chat_harness.dart';
import '../support/fake_chat_backend.dart';

const groupId = '01JC0000000000000000000002';
const directId = '01JC0000000000000000000001';

ChatDto chat(String id, String kind, List<String> members) => ChatDto(
      id: id,
      kind: kind,
      title: kind == 'group' ? 'Family' : null,
      createdBy: members.first,
      currentEpoch: 1,
      epochReady: true,
      lastSeq: 0,
      lastMessageAt: null,
      createdAt: 1,
      members: [for (final m in members) MemberDto(userId: m, joinedSeq: 0, lastReadSeq: 0)],
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

  Future<void> open(WidgetTester tester, String id, {List<MessageRow> messages = const []}) async {
    setWindow(tester, const Size(400, 800));
    await pumpChatApp(tester, alice);
    await inApp(tester, () async {
      await alice.db.upsertChat(chat(groupId, 'group', [alice.userId, bob.userId, carol.userId]));
      await alice.db.upsertChat(chat(directId, 'direct', [alice.userId, bob.userId]));
      for (final m in messages) {
        await alice.db.insertMessageIfAbsent(m);
      }
    });
    ProviderScope.containerOf(tester.element(find.byType(FamChatApp))).read(routerProvider).go('/chats/$id');
    await settle(tester);
  }

  String composerText(WidgetTester tester) => tester.widget<TextField>(find.byKey(const Key('composer'))).controller!.text;

  chatTestWidgets('typing @ in a group suggests members; picking one mentions them', (tester) async {
    await open(tester, groupId);
    await tester.enterText(find.byKey(const Key('composer')), 'hey @');
    await tester.pump();
    expect(find.byKey(Key('mention-${bob.userId}')), findsOneWidget);
    expect(find.byKey(Key('mention-${carol.userId}')), findsOneWidget);
    expect(find.byKey(Key('mention-${alice.userId}')), findsNothing, reason: 'not yourself');

    await tester.enterText(find.byKey(const Key('composer')), 'hey @b');
    await tester.pump();
    expect(find.byKey(Key('mention-${carol.userId}')), findsNothing);
    await tester.tap(find.byKey(Key('mention-${bob.userId}')));
    await tester.pump();
    expect(composerText(tester), 'hey @Bob ');

    await tester.enterText(find.byKey(const Key('composer')), 'hey @Bob and @carol, dinner?');
    await tester.pump();
    await tester.tap(find.byTooltip('Send'));
    await settle(tester);
    final sent = (await inApp(tester, () => alice.db.pendingOutbox(alice.deviceId))).single;
    final body = Plaintext.decode(utf8.encode(sent.body!)) as TextBody;
    expect(body.mentions, unorderedEquals([bob.userId, carol.userId]));
  });

  chatTestWidgets('the keyboard picks a suggestion', (tester) async {
    await open(tester, groupId);
    await tester.enterText(find.byKey(const Key('composer')), '@');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(composerText(tester), '@Carol ', reason: '@everyone, then members by name: Bob, then Carol');
  });

  chatTestWidgets('@everyone mentions every other member', (tester) async {
    await open(tester, groupId);
    await tester.enterText(find.byKey(const Key('composer')), 'dinner @ev');
    await tester.pump();
    await tester.tap(find.byKey(const Key('mention-*everyone')));
    await tester.pump();
    expect(composerText(tester), 'dinner @everyone ');
    await tester.tap(find.byTooltip('Send'));
    await settle(tester);
    final sent = (await inApp(tester, () => alice.db.pendingOutbox(alice.deviceId))).single;
    final body = Plaintext.decode(utf8.encode(sent.body!)) as TextBody;
    expect(body.mentions, unorderedEquals([bob.userId, carol.userId]));
  });

  chatTestWidgets('no suggestions in a direct chat, and nothing is mentioned there', (tester) async {
    await open(tester, directId);
    await tester.enterText(find.byKey(const Key('composer')), 'hi @');
    await tester.pump();
    expect(find.byKey(Key('mention-${bob.userId}')), findsNothing);
  });

  chatTestWidgets('mentions stand out in the message', (tester) async {
    await open(tester, groupId, messages: [
      MessageRow(
        id: 'm1',
        chatId: groupId,
        seq: 1,
        senderUserId: bob.userId,
        senderDeviceId: 'x',
        kind: 'text',
        body: jsonEncode(TextBody('@Alice look at this', mentions: [alice.userId]).toJson()),
        targetId: null,
        envelope: null,
        createdAt: DateTime.now().millisecondsSinceEpoch,
        state: 'sent',
      ),
    ]);
    TextSpan? mention;
    for (final rich in tester.widgetList<RichText>(find.byType(RichText))) {
      rich.text.visitChildren((span) {
        if (span is TextSpan && span.text == '@Alice') mention = span;
        return true;
      });
    }
    expect(mention, isNotNull);
    expect(mention!.style?.fontWeight, FontWeight.w700);
  });
}
