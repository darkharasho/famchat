import 'dart:convert';

import 'package:famchat/chat/db/chat_db.dart';
import 'package:famchat/chat/wire.dart';
import 'package:famchat/main.dart';
import 'package:famchat/router.dart';
import 'package:drift/drift.dart' show Value;
import 'package:famchat/widgets/link_text.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../support/chat_harness.dart';
import '../support/fake_chat_backend.dart';

const chatId = '01JC0000000000000000000001';

ChatDto direct(String a, String b) => ChatDto(
      id: chatId,
      kind: 'direct',
      title: null,
      createdBy: a,
      currentEpoch: 1,
      epochReady: true,
      lastSeq: 0,
      lastMessageAt: null,
      createdAt: 1,
      members: [MemberDto(userId: a, joinedSeq: 0, lastReadSeq: 0), MemberDto(userId: b, joinedSeq: 0, lastReadSeq: 0)],
    );

MessageRow row(String id, int? seq, String from, String text, {String state = 'sent'}) => MessageRow(
      id: id,
      chatId: chatId,
      seq: seq,
      senderUserId: from,
      senderDeviceId: 'x',
      kind: 'text',
      body: '{"kind":"text","text":"$text"}',
      targetId: null,
      envelope: null,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      state: state,
    );

void main() {
  late FakeChatBackend backend;
  late TestDevice alice, bob;
  WidgetTester? tester0;

  setUp(() async {
    backend = FakeChatBackend();
    alice = await backend.addUser('Alice');
    bob = await backend.addUser('Bob');
  });

  Future<ScriptedHubLink> open(WidgetTester tester, {List<MessageRow> messages = const []}) async {
    setWindow(tester, const Size(400, 800));
    final hub = await pumpChatApp(tester, alice);
    await inApp(tester, () async {
      await alice.db.upsertChat(direct(alice.userId, bob.userId));
      for (final m in messages) {
        await alice.db.insertMessageIfAbsent(m);
      }
    });
    ProviderScope.containerOf(tester.element(find.byType(FamChatApp))).read(routerProvider).go('/chats/$chatId');
    await settle(tester);
    return hub;
  }

  Future<MessageRow> pendingOne() async => (await inApp(tester0!, () => alice.db.pendingOutbox(alice.deviceId))).single;

  chatTestWidgets("long-press offers reply and copy on others' messages; edit and delete only on mine", (tester) async {
    tester0 = tester;
    await open(tester, messages: [row('m1', 1, bob.userId, 'cake?'), row('m2', 2, alice.userId, 'yes!')]);
    await tester.longPress(find.text('cake?'));
    await settle(tester);
    expect(find.text('Reply'), findsOneWidget);
    expect(find.text('Copy'), findsOneWidget);
    expect(find.text('Edit'), findsNothing);
    expect(find.text('Delete'), findsNothing);
    await tester.tapAt(const Offset(10, 10)); // closes the sheet
    await settle(tester);
    await tester.longPress(find.text('yes!'));
    await settle(tester);
    expect(find.text('Edit'), findsOneWidget);
    expect(find.text('Delete'), findsOneWidget);
  });

  chatTestWidgets('copy puts the text on the clipboard', (tester) async {
    tester0 = tester;
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
      return null;
    });
    await open(tester, messages: [row('m1', 1, bob.userId, 'the code is 1234')]);
    await tester.longPress(find.text('the code is 1234'));
    await settle(tester);
    await tester.tap(find.text('Copy'));
    await settle(tester);
    expect(copied, 'the code is 1234');
  });

  chatTestWidgets('reply quotes the message, and the sent reply points at it', (tester) async {
    tester0 = tester;
    await open(tester, messages: [row('m1', 1, bob.userId, 'cake?')]);
    await tester.longPress(find.text('cake?'));
    await settle(tester);
    await tester.tap(find.text('Reply'));
    await settle(tester);
    expect(find.text('Replying to Bob'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('composer')), 'yes please');
    await tester.pump();
    await tester.tap(find.byTooltip('Send'));
    await settle(tester);
    expect(find.text('Replying to Bob'), findsNothing);
    final p = await pendingOne();
    expect((jsonDecode(p.body!) as Map)['replyTo'], 'm1');
    expect(find.byKey(const Key('reply-quote-m1')), findsOneWidget);
    expect(find.text('cake?'), findsNWidgets(2)); // the message and the quote in the reply
  });

  chatTestWidgets('cancelling a reply sends a plain message', (tester) async {
    tester0 = tester;
    await open(tester, messages: [row('m1', 1, bob.userId, 'cake?')]);
    await tester.longPress(find.text('cake?'));
    await settle(tester);
    await tester.tap(find.text('Reply'));
    await settle(tester);
    await tester.tap(find.byTooltip('Cancel reply'));
    await settle(tester);
    expect(find.text('Replying to Bob'), findsNothing);
    await tester.enterText(find.byKey(const Key('composer')), 'hm');
    await tester.pump();
    await tester.tap(find.byTooltip('Send'));
    await settle(tester);
    expect((jsonDecode((await pendingOne()).body!) as Map).containsKey('replyTo'), isFalse);
  });

  chatTestWidgets('edit fills the composer and the message shows the new text, marked edited', (tester) async {
    tester0 = tester;
    await open(tester, messages: [row('m2', 2, alice.userId, 'see you at 5')]);
    await tester.longPress(find.text('see you at 5'));
    await settle(tester);
    await tester.tap(find.text('Edit'));
    await settle(tester);
    expect(find.text('Editing message'), findsOneWidget);
    final field = find.byKey(const Key('composer'));
    expect(tester.widget<TextField>(field).controller!.text, 'see you at 5');
    await tester.enterText(field, 'see you at 6');
    await tester.pump();
    await tester.tap(find.byTooltip('Save edit'));
    await settle(tester);
    final p = await pendingOne();
    expect((p.kind, p.targetId), ('edit', 'm2'));
    expect(find.text('see you at 6'), findsOneWidget);
    expect(find.text('see you at 5'), findsNothing);
    expect(find.text('edited'), findsOneWidget);
    expect(tester.widget<TextField>(field).controller!.text, isEmpty);
  });

  chatTestWidgets('delete asks first, then the message shows as deleted', (tester) async {
    tester0 = tester;
    await open(tester, messages: [row('m2', 2, alice.userId, 'oops wrong chat')]);
    await tester.longPress(find.text('oops wrong chat'));
    await settle(tester);
    await tester.tap(find.text('Delete'));
    await settle(tester);
    expect(find.text('Delete for everyone?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await settle(tester);
    final p = await pendingOne();
    expect((p.kind, p.targetId), ('delete', 'm2'));
    expect(find.text('oops wrong chat'), findsNothing);
    expect(find.text('This message was deleted.'), findsOneWidget);
  });

  chatTestWidgets('links in messages are tappable', (tester) async {
    tester0 = tester;
    await open(tester, messages: [row('m1', 1, bob.userId, 'menu: https://example.com/menu')]);
    expect(find.byType(LinkText), findsOneWidget);
    final rich = tester.widget<RichText>(find.descendant(of: find.byType(LinkText), matching: find.byType(RichText)));
    expect(rich.text.toPlainText(), 'menu: https://example.com/menu');
  });

  chatTestWidgets('a reply in progress does not follow you into another chat', (tester) async {
    tester0 = tester;
    await open(tester, messages: [row('m1', 1, bob.userId, 'cake?')]);
    await tester.longPress(find.text('cake?'));
    await settle(tester);
    await tester.tap(find.text('Reply'));
    await settle(tester);
    expect(find.text('Replying to Bob'), findsOneWidget);
    const other = '01JC0000000000000000000002';
    final carol = await backend.addUser('Carol');
    await inApp(tester, () => alice.db.upsertChat(ChatDto(
          id: other,
          kind: 'direct',
          title: null,
          createdBy: alice.userId,
          currentEpoch: 1,
          epochReady: true,
          lastSeq: 0,
          lastMessageAt: null,
          createdAt: 1,
          members: [
            MemberDto(userId: alice.userId, joinedSeq: 0, lastReadSeq: 0),
            MemberDto(userId: carol.userId, joinedSeq: 0, lastReadSeq: 0),
          ],
        )));
    ProviderScope.containerOf(tester.element(find.byType(FamChatApp))).read(routerProvider).go('/chats/$other');
    await settle(tester);
    expect(find.text('Replying to Bob'), findsNothing);
  });

  chatTestWidgets('saving an edit to a message deleted meanwhile says so and sends nothing', (tester) async {
    tester0 = tester;
    await open(tester, messages: [row('m2', 2, alice.userId, 'see you at 5')]);
    await tester.longPress(find.text('see you at 5'));
    await settle(tester);
    await tester.tap(find.text('Edit'));
    await settle(tester);
    // Deleted from Alice's other device.
    await inApp(tester, () => alice.db.insertMessageIfAbsent(row('d1', 3, alice.userId, '').copyWith(
          kind: 'delete',
          body: const Value('{"kind":"delete","target":"m2"}'),
          targetId: const Value('m2'),
        )));
    await settle(tester);
    await tester.enterText(find.byKey(const Key('composer')), 'see you at 6');
    await tester.pump();
    await tester.tap(find.byTooltip('Save edit'));
    await settle(tester);
    expect(find.text('That message was deleted.'), findsOneWidget);
    expect(await inApp(tester, () => alice.db.pendingOutbox(alice.deviceId)), isEmpty);
    expect(find.text('Editing message'), findsNothing);
  });
}
