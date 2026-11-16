import 'package:famchat/router.dart';
import 'package:famchat/screens/chats/conversation_view.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:famchat/main.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/chat_harness.dart';
import '../support/fake_chat_backend.dart';

void main() {
  late FakeChatBackend backend;
  late TestDevice alice, bob, carol;

  setUp(() async {
    backend = FakeChatBackend();
    alice = await backend.addUser('Alice');
    bob = await backend.addUser('Bob');
    carol = await backend.addUser('Carol');
  });

  void go(WidgetTester tester, String path) =>
      ProviderScope.containerOf(tester.element(find.byType(FamChatApp))).read(routerProvider).go(path);

  chatTestWidgets('picking one person opens a direct chat', (tester) async {
    setWindow(tester, const Size(400, 800));
    await pumpChatApp(tester, alice);
    go(tester, '/new');
    await settle(tester);
    expect(find.text('Alice'), findsNothing); // not yourself
    await tester.tap(find.text('Bob'));
    await settle(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Chat'));
    await settle(tester);
    final chat = backend.chatDto((await tester.runAsync(() => bob.api.chats()))!.single.id);
    expect(chat.kind, 'direct');
    expect(find.byType(ConversationView), findsOneWidget);
  });

  chatTestWidgets('deleted accounts are not offered', (tester) async {
    setWindow(tester, const Size(400, 800));
    backend.markDeleted(carol.userId);
    await pumpChatApp(tester, alice);
    go(tester, '/new');
    await settle(tester);
    expect(find.text('Bob'), findsOneWidget);
    expect(find.text('Carol'), findsNothing);
  });

  chatTestWidgets('picking two asks for a title and creates a group', (tester) async {
    setWindow(tester, const Size(400, 800));
    await pumpChatApp(tester, alice);
    go(tester, '/new');
    await settle(tester);
    await tester.tap(find.text('Bob'));
    await tester.tap(find.text('Carol'));
    await settle(tester);
    final title = find.byKey(const Key('group-title'));
    expect(tester.widget<TextField>(title).controller!.text, 'Bob, Carol');
    await tester.enterText(title, 'Cousins');
    await tester.tap(find.widgetWithText(FilledButton, 'Create group'));
    await settle(tester);
    final chats = (await tester.runAsync(() => carol.api.chats()))!;
    expect(chats.single.title, 'Cousins');
    expect(chats.single.members, hasLength(3));
    expect(find.byType(ConversationView), findsOneWidget);
  });

  chatTestWidgets('preselected people start checked', (tester) async {
    setWindow(tester, const Size(400, 800));
    await pumpChatApp(tester, alice);
    go(tester, '/new?with=${bob.userId}');
    await settle(tester);
    expect(tester.widget<CheckboxListTile>(find.widgetWithText(CheckboxListTile, 'Bob')).value, isTrue);
  });
}
