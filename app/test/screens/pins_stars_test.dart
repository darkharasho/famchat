// Pinned messages (for everyone) and starred messages (mine) in a conversation.
import 'dart:convert';

import 'package:famchat/chat/db/chat_db.dart';
import 'package:famchat/chat/providers.dart';
import 'package:famchat/chat/wire.dart';
import 'package:famchat/main.dart';
import 'package:famchat/router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../support/chat_harness.dart';
import '../support/fake_chat_backend.dart';

const chatId = '01JC0000000000000000000001';

MessageRow row(String id, int seq, String from, String kind, Map<String, Object?> body, {String? target}) => MessageRow(
      id: id,
      chatId: chatId,
      seq: seq,
      senderUserId: from,
      senderDeviceId: 'x',
      kind: kind,
      body: jsonEncode({'kind': kind, ...body}),
      targetId: target,
      envelope: null,
      createdAt: DateTime.now().subtract(Duration(minutes: 100 - seq)).millisecondsSinceEpoch,
      state: 'sent',
    );

MessageRow text(String id, int seq, String from, String t) => row(id, seq, from, 'text', {'text': t});

void main() {
  late FakeChatBackend backend;
  late TestDevice alice, bob;

  setUp(() async {
    backend = FakeChatBackend();
    alice = await backend.addUser('Alice');
    bob = await backend.addUser('Bob');
  });

  Future<void> open(WidgetTester tester, List<MessageRow> messages) async {
    setWindow(tester, const Size(400, 800));
    await pumpChatApp(tester, alice);
    await inApp(tester, () async {
      await alice.db.upsertChat(ChatDto(
        id: chatId,
        kind: 'direct',
        title: null,
        createdBy: alice.userId,
        currentEpoch: 1,
        epochReady: true,
        lastSeq: messages.length,
        lastMessageAt: null,
        createdAt: 1,
        members: [
          MemberDto(userId: alice.userId, joinedSeq: 0, lastReadSeq: messages.length),
          MemberDto(userId: bob.userId, joinedSeq: 0, lastReadSeq: 0),
        ],
      ));
      for (final m in messages) {
        await alice.db.insertMessageIfAbsent(m);
      }
    });
    ProviderScope.containerOf(tester.element(find.byType(FamChatApp))).read(routerProvider).go('/chats/$chatId');
    await settle(tester);
  }

  Future<void> act(WidgetTester tester, String message, String action) async {
    await tester.longPress(find.text(message));
    await settle(tester);
    await tester.tap(find.text(action));
    await settle(tester);
  }

  String barText(WidgetTester tester) => tester.widget<Text>(find.byKey(const Key('pin-bar-text'))).data!;

  chatTestWidgets('pinning shows the bar and a line; the bar steps through pins; unpinning removes one', (tester) async {
    await open(tester, [
      text('m1', 1, bob.userId, 'reunion Sat at 2'),
      text('m2', 2, bob.userId, 'gate code 4471'),
      text('m3', 3, bob.userId, 'see you'),
    ]);
    expect(find.byKey(const Key('pin-bar')), findsNothing);
    await act(tester, 'gate code 4471', 'Pin for everyone');
    expect(find.byKey(const Key('pin-bar')), findsOneWidget);
    expect(find.text('Pinned message'), findsOneWidget);
    expect(barText(tester), 'gate code 4471');
    expect(find.text('You pinned a message'), findsOneWidget);

    await act(tester, 'reunion Sat at 2', 'Pin for everyone');
    expect(find.text('Pinned message 2 of 2'), findsOneWidget);
    expect(barText(tester), 'reunion Sat at 2');
    await tester.tap(find.byKey(const Key('pin-bar')));
    await settle(tester);
    expect(find.text('Pinned message 1 of 2'), findsOneWidget);
    expect(barText(tester), 'gate code 4471');

    await act(tester, 'reunion Sat at 2', 'Unpin');
    expect(find.text('Pinned message'), findsOneWidget);
    expect(barText(tester), 'gate code 4471');
    expect(find.text('You unpinned a message'), findsOneWidget);
  });

  chatTestWidgets("someone else's pin shows the same way", (tester) async {
    await open(tester, [
      text('m1', 1, alice.userId, 'dinner at 6'),
      row('p1', 2, bob.userId, 'pin', {'target': 'm1', 'pinned': true}, target: 'm1'),
    ]);
    expect(barText(tester), 'dinner at 6');
    expect(find.text('Bob pinned a message'), findsOneWidget);
  });

  chatTestWidgets('starring shows a star by the time, for me only, and unstarring removes it', (tester) async {
    setWindow(tester, const Size(400, 800));
    await pumpChatApp(tester, alice);
    final container = ProviderScope.containerOf(tester.element(find.byType(FamChatApp)));
    final direct = await inApp(tester, () async {
      final id = await container.read(chatSyncProvider)!.openDirect(bob.userId);
      backend.injectMessage(id, id: 'm1', senderUserId: bob.userId, senderDeviceId: bob.deviceId, envelope: const {}, fanOut: false);
      await alice.db.insertMessageIfAbsent(text('m1', 1, bob.userId, 'gate code 4471').copyWith(chatId: id));
      await alice.db.setMyLastRead(id, 1);
      return id;
    });
    container.read(routerProvider).go('/chats/$direct');
    await settle(tester);
    await act(tester, 'gate code 4471', 'Star');
    expect(find.byKey(const Key('star-m1')), findsOneWidget);
    expect(backend.stars[alice.userId]?.keys, ['m1']);
    expect(backend.stars[bob.userId], isNull);
    await act(tester, 'gate code 4471', 'Unstar');
    expect(find.byKey(const Key('star-m1')), findsNothing);
    expect(backend.stars[alice.userId], isEmpty);
  });
}
