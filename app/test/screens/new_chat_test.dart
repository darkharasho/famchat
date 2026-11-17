import 'package:famchat/chat/wire.dart';
import 'package:famchat/router.dart';
import 'package:famchat/screens/chats/conversation_view.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:famchat/chat/providers.dart';
import 'package:famchat/main.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/chat_harness.dart';
import '../support/fake_chat_backend.dart';
import '../support/fake_server.dart';

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

  /// Alice is in two families: 1 ("Hearth") and 10 ("Smiths"). Bob is in both, Carol in 1, Dan in 10.
  FakeServer twoFamilies() {
    final server = FakeServer()..family1Name = 'Hearth';
    server.extraFamilies.add({
      'id': 10, 'name': 'Smiths', 'status': 'approved', 'role': 'member', 'owner': false, 'ownerId': 'x', 'memberCount': 3, 'createdAt': 1,
    });
    for (final t in [alice, bob, dan]) {
      backend.addFamilyRole(t.userId, const FamilyRoleDto(id: 10, admin: false));
    }
    backend.removeFamilyRole(dan.userId, 1);
    return server;
  }

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

  chatTestWidgets('former people are not offered', (tester) async {
    setWindow(tester, const Size(400, 800));
    backend.markFormer(carol.userId);
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

  chatTestWidgets('alone (a reviewer), you can start a note to self', (tester) async {
    setWindow(tester, const Size(400, 800));
    final lone = FakeChatBackend();
    final me = await lone.addUser('Reviewer');
    await pumpChatApp(tester, me);
    go(tester, '/new');
    await settle(tester);
    expect(find.text('No one else here yet'), findsOneWidget);
    await tester.tap(find.byKey(const Key('note-to-self')));
    await settle(tester);
    final chats = (await tester.runAsync(() => me.api.chats()))!;
    expect(chats.single.title, 'Note to self');
    expect(chats.single.kind, 'group');
    expect(chats.single.members.map((m) => m.userId), [me.userId]);
    expect(find.byType(ConversationView), findsOneWidget);
    expect(find.text('Only you'), findsOneWidget);
  });

  chatTestWidgets('with others to pick, there is no note-to-self button', (tester) async {
    setWindow(tester, const Size(400, 800));
    await pumpChatApp(tester, alice);
    go(tester, '/new');
    await settle(tester);
    expect(find.byKey(const Key('note-to-self')), findsNothing);
  });

  chatTestWidgets('preselected people start checked', (tester) async {
    setWindow(tester, const Size(400, 800));
    await pumpChatApp(tester, alice);
    go(tester, '/new?with=${bob.userId}');
    await settle(tester);
    expect(tester.widget<CheckboxListTile>(find.widgetWithText(CheckboxListTile, 'Bob')).value, isTrue);
  });

  chatTestWidgets('two families: each person is labeled with the families you share', (tester) async {
    setWindow(tester, const Size(400, 800));
    await pumpChatApp(tester, alice, server: twoFamilies());
    go(tester, '/new');
    await settle(tester);
    expect(find.descendant(of: find.widgetWithText(CheckboxListTile, 'Bob'), matching: find.text('Hearth, Smiths')), findsOneWidget);
    expect(find.descendant(of: find.widgetWithText(CheckboxListTile, 'Carol'), matching: find.text('Hearth')), findsOneWidget);
    expect(find.descendant(of: find.widgetWithText(CheckboxListTile, 'Dan'), matching: find.text('Smiths')), findsOneWidget);
  });

  chatTestWidgets('one family: no labels and no group step', (tester) async {
    setWindow(tester, const Size(400, 800));
    await pumpChatApp(tester, alice);
    go(tester, '/new');
    await settle(tester);
    expect(find.text('Family'), findsNothing);
    expect(find.byKey(const Key('new-group')), findsNothing);
    await tester.tap(find.text('Bob'));
    await tester.tap(find.text('Carol'));
    await settle(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Create group'));
    await settle(tester);
    expect(backend.requestedFamily.values.single, 1, reason: 'the only family is sent');
  });

  chatTestWidgets('two families: a new group picks the family first, then only its members', (tester) async {
    setWindow(tester, const Size(400, 800));
    await pumpChatApp(tester, alice, server: twoFamilies());
    go(tester, '/new');
    await settle(tester);
    await tester.tap(find.byKey(const Key('new-group')));
    await settle(tester);
    expect(find.text('Bob'), findsNothing, reason: 'the family step comes first');
    expect(find.text('Hearth'), findsOneWidget);
    await tester.tap(find.text('Smiths'));
    await settle(tester);
    expect(find.text('Bob'), findsOneWidget);
    expect(find.text('Dan'), findsOneWidget);
    expect(find.text('Carol'), findsNothing);
    await tester.tap(find.text('Bob'));
    await tester.tap(find.text('Dan'));
    await settle(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Create group'));
    await settle(tester);
    final id = backend.requestedFamily.keys.single;
    expect(backend.requestedFamily[id], 10);
    expect(backend.chatDto(id).familyId, 10);
    expect(find.byType(ConversationView), findsOneWidget);
  });

  chatTestWidgets('note to self sends no family', (tester) async {
    setWindow(tester, const Size(400, 800));
    final lone = FakeChatBackend();
    final me = await lone.addUser('Reviewer');
    await pumpChatApp(tester, me);
    go(tester, '/new');
    await settle(tester);
    await tester.tap(find.byKey(const Key('note-to-self')));
    await settle(tester);
    expect(lone.requestedFamily.values.single, isNull);
  });

  chatTestWidgets('adding people lists only the group\'s family', (tester) async {
    setWindow(tester, const Size(400, 800));
    await pumpChatApp(tester, alice, server: twoFamilies());
    final id = await inApp(tester, () => ProviderScope.containerOf(tester.element(find.byType(FamChatApp))).read(chatSyncProvider)!.createGroup('Smiths only', [bob.userId], familyId: 10));
    go(tester, '/chats/$id/info/add');
    await settle(tester);
    expect(find.text('Dan'), findsOneWidget);
    expect(find.text('Carol'), findsNothing);
  });

  chatTestWidgets('two families: picking a second person in the default list goes through the family step', (tester) async {
    setWindow(tester, const Size(400, 800));
    await pumpChatApp(tester, alice, server: twoFamilies());
    go(tester, '/new');
    await settle(tester);
    await tester.tap(find.text('Bob'));
    await tester.tap(find.text('Carol'));
    await settle(tester);
    expect(find.widgetWithText(FilledButton, 'Create group'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Create group')).onPressed, isNull,
        reason: 'no group without a family');
    expect(backend.requestedFamily, isEmpty);
    await tester.tap(find.text('Hearth'));
    await settle(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Create group'));
    await settle(tester);
    expect(backend.requestedFamily.values.single, 1);
  });
}
