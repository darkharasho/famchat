import 'package:famchat/chat/db/chat_db.dart';
import 'package:famchat/chat/wire.dart';
import 'package:famchat/main.dart';
import 'package:famchat/router.dart';
import 'package:famchat/screens/chats/message_bubble.dart';
import 'package:go_router/go_router.dart';
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

  setUp(() async {
    backend = FakeChatBackend();
    alice = await backend.addUser('Alice');
    bob = await backend.addUser('Bob');
  });

  Future<GoRouter> openSearch(WidgetTester tester, String path, List<MessageRow> messages) async {
    setWindow(tester, const Size(400, 800));
    await pumpChatApp(tester, alice);
    await inApp(tester, () async {
      await alice.db.upsertChat(direct(alice.userId, bob.userId));
      for (final m in messages) {
        await alice.db.insertMessageIfAbsent(m);
      }
    });
    final router = ProviderScope.containerOf(tester.element(find.byType(FamChatApp))).read(routerProvider);
    router.go(path);
    await settle(tester);
    return router;
  }

  chatTestWidgets('the chat list opens message search', (tester) async {
    setWindow(tester, const Size(400, 800));
    await pumpChatApp(tester, alice);
    await tester.tap(find.byTooltip(RegExp('^Search messages')));
    await settle(tester);
    expect(find.text('Search your messages'), findsOneWidget);
  });

  chatTestWidgets('typing finds messages and tapping one opens the chat at it', (tester) async {
    final router = await openSearch(tester, '/search', [
      row('m1', 1, bob.userId, 'dinner at grandmas on sunday'),
      for (var i = 2; i < 40; i++) row('f$i', i, bob.userId, 'filler $i'),
    ]);
    await tester.enterText(find.byKey(const Key('search-field')), 'grandma');
    await tester.pump(const Duration(milliseconds: 200)); // the search waits for typing to pause
    await settle(tester);
    expect(find.byKey(const Key('search-hit-m1')), findsOneWidget);
    expect(find.text('Bob'), findsOneWidget);
    await tester.tap(find.byKey(const Key('search-hit-m1')));
    await settle(tester);
    expect(router.state.uri.toString(), '/chats/$chatId?m=m1');
    expect(find.text('dinner at grandmas on sunday'), findsOneWidget);
    expect(tester.widget<MessageBubble>(find.ancestor(of: find.text('dinner at grandmas on sunday'), matching: find.byType(MessageBubble))).highlighted, isTrue);
  });

  chatTestWidgets('no matches says so', (tester) async {
    await openSearch(tester, '/search', [row('m1', 1, bob.userId, 'hello')]);
    await tester.enterText(find.byKey(const Key('search-field')), 'sushi');
    await tester.pump(const Duration(milliseconds: 200)); // the search waits for typing to pause
    await settle(tester);
    expect(find.text('No messages match "sushi"'), findsOneWidget);
  });

  chatTestWidgets('search in one chat from its header', (tester) async {
    setWindow(tester, const Size(400, 800));
    await pumpChatApp(tester, alice);
    await inApp(tester, () => alice.db.upsertChat(direct(alice.userId, bob.userId)));
    final router = ProviderScope.containerOf(tester.element(find.byType(FamChatApp))).read(routerProvider);
    router.go('/chats/$chatId');
    await settle(tester);
    await tester.tap(find.byTooltip(RegExp('^Search in this chat')));
    await settle(tester);
    expect(router.state.uri.toString(), '/search?chat=$chatId');
    expect(find.text('Search in Bob'), findsOneWidget);
  });
}
