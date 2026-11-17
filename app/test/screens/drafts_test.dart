import 'package:famchat/chat/wire.dart';
import 'package:famchat/main.dart';
import 'package:famchat/router.dart';
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

void main() {
  late FakeChatBackend backend;
  late TestDevice alice, bob;

  setUp(() async {
    backend = FakeChatBackend();
    alice = await backend.addUser('Alice');
    bob = await backend.addUser('Bob');
  });

  void go(WidgetTester tester, String to) =>
      ProviderScope.containerOf(tester.element(find.byType(FamChatApp))).read(routerProvider).go(to);

  Future<void> open(WidgetTester tester) async {
    setWindow(tester, const Size(400, 800));
    await pumpChatApp(tester, alice);
    await inApp(tester, () => alice.db.upsertChat(direct(alice.userId, bob.userId)));
    go(tester, '/chats/$chatId');
    await settle(tester);
  }

  chatTestWidgets('an unsent message stays in its chat as a draft, shown in the chat list', (tester) async {
    await open(tester);
    await tester.enterText(find.byKey(const Key('composer')), 'see you at');
    await tester.pump(const Duration(milliseconds: 600));
    go(tester, '/');
    await settle(tester);
    expect(find.text('Draft: see you at'), findsOneWidget);

    go(tester, '/chats/$chatId');
    await settle(tester);
    expect(tester.widget<TextField>(find.byKey(const Key('composer'))).controller!.text, 'see you at');

    await tester.enterText(find.byKey(const Key('composer')), 'see you at 6');
    await tester.tap(find.byTooltip('Send'));
    await settle(tester);
    expect(await inApp(tester, () => alice.db.draftOf(chatId)), isNull);
  });

  chatTestWidgets('leaving at once still saves the draft', (tester) async {
    await open(tester);
    await tester.enterText(find.byKey(const Key('composer')), 'quick');
    go(tester, '/');
    await settle(tester);
    expect(await inApp(tester, () => alice.db.draftOf(chatId)), 'quick');
  });

  chatTestWidgets('editing a message sets the draft aside and brings it back after', (tester) async {
    await open(tester);
    await tester.enterText(find.byKey(const Key('composer')), 'first');
    await tester.pump();
    await tester.tap(find.byTooltip('Send'));
    await settle(tester);
    await tester.enterText(find.byKey(const Key('composer')), 'half written');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.longPress(find.text('first'));
    await settle(tester);
    await tester.tap(find.text('Edit'));
    await settle(tester);
    expect(tester.widget<TextField>(find.byKey(const Key('composer'))).controller!.text, 'first');
    expect(await inApp(tester, () => alice.db.draftOf(chatId)), 'half written', reason: 'edit text is not the draft');
    await tester.tap(find.byTooltip('Cancel edit'));
    await settle(tester);
    expect(tester.widget<TextField>(find.byKey(const Key('composer'))).controller!.text, 'half written');
  });

  chatTestWidgets('typing survives the window changing layout at once', (tester) async {
    await open(tester);
    await tester.enterText(find.byKey(const Key('composer')), 'mid-sentence');
    setWindow(tester, const Size(1000, 800)); // the conversation moves beside the list: a new state
    await settle(tester);
    expect(tester.widget<TextField>(find.byKey(const Key('composer'))).controller!.text, 'mid-sentence');
  });
}
