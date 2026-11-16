import 'package:famchat/chat/providers.dart';
import 'package:famchat/main.dart';
import 'package:famchat/router.dart';
import 'package:famchat/screens/chats/new_chat_screen.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../support/chat_harness.dart';
import '../support/fake_chat_backend.dart';

void main() {
  late FakeChatBackend backend;
  late TestDevice alice, bob, carol, dan;

  setUp(() async {
    backend = FakeChatBackend();
    alice = await backend.addUser('Alice');
    bob = await backend.addUser('Bob');
    carol = await backend.addUser('Carol');
    dan = await backend.addUser('Dan');
  });

  ProviderContainer c(WidgetTester tester) => ProviderScope.containerOf(tester.element(find.byType(FamChatApp)));

  Future<String> openInfo(WidgetTester tester, Future<String> Function(ProviderContainer) make) async {
    setWindow(tester, const Size(400, 800));
    await pumpChatApp(tester, alice);
    final id = await inApp(tester, () => make(c(tester)));
    c(tester).read(routerProvider).go('/chats/$id/info');
    await settle(tester);
    return id;
  }

  chatTestWidgets('members are listed and the creator can remove one', (tester) async {
    final id = await openInfo(tester, (c) => c.read(chatSyncProvider)!.createGroup('Cousins', [bob.userId, carol.userId]));
    expect(find.text('Cousins'), findsWidgets);
    expect(find.text('Alice (you)'), findsOneWidget);
    expect(find.text('Bob'), findsOneWidget);
    await tester.tap(find.byTooltip('Remove Carol'));
    await settle(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
    await settle(tester);
    expect(backend.chatDto(id).members.map((m) => m.userId), isNot(contains(carol.userId)));
    expect(backend.chatDto(id).currentEpoch, 2);
    expect(find.text('Carol'), findsNothing);
  });

  chatTestWidgets('leaving returns to the chat list', (tester) async {
    final id = await openInfo(tester, (c) => c.read(chatSyncProvider)!.createGroup('Cousins', [bob.userId, carol.userId]));
    await tester.tap(find.text('Leave group'));
    await settle(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Leave'));
    await settle(tester);
    expect(backend.chatDto(id).members.map((m) => m.userId), isNot(contains(alice.userId)));
    expect(find.text('No chats yet'), findsOneWidget);
  });

  chatTestWidgets('adding people to a group', (tester) async {
    final id = await openInfo(tester, (c) => c.read(chatSyncProvider)!.createGroup('Cousins', [bob.userId]));
    await tester.tap(find.text('Add people'));
    await settle(tester);
    expect(find.text('Bob'), findsNothing); // already a member
    await tester.tap(find.text('Dan'));
    await settle(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await settle(tester);
    expect(backend.chatDto(id).members.map((m) => m.userId), contains(dan.userId));
    expect(backend.hasWrap(id, 1, dan.deviceId), isTrue);
  });

  chatTestWidgets('adding from a 1:1 starts a new group with that person', (tester) async {
    await openInfo(tester, (c) => c.read(chatSyncProvider)!.openDirect(bob.userId));
    expect(find.text('Leave group'), findsNothing);
    await tester.tap(find.text('Add people'));
    await settle(tester);
    expect(find.byType(NewChatScreen), findsOneWidget);
    expect(tester.widget<CheckboxListTile>(find.widgetWithText(CheckboxListTile, 'Bob')).value, isTrue);
  });
}
