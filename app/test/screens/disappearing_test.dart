import 'package:famchat/chat/providers.dart';
import 'package:famchat/main.dart';
import 'package:famchat/router.dart';
import 'package:famchat/screens/chats/disappearing_sheet.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../support/chat_harness.dart';
import '../support/fake_chat_backend.dart';

void main() {
  late FakeChatBackend backend;
  late TestDevice alice, bob;

  setUp(() async {
    backend = FakeChatBackend();
    alice = await backend.addUser('Alice');
    bob = await backend.addUser('Bob');
  });

  ProviderContainer c(WidgetTester tester) => ProviderScope.containerOf(tester.element(find.byType(FamChatApp)));

  Future<(ScriptedHubLink, String)> openChat(WidgetTester tester, {String path = ''}) async {
    setWindow(tester, const Size(400, 800));
    final hub = await pumpChatApp(tester, alice);
    final id = await inApp(tester, () => c(tester).read(chatSyncProvider)!.openDirect(bob.userId));
    c(tester).read(routerProvider).go('/chats/$id$path');
    await settle(tester);
    return (hub, id);
  }

  test('labels', () {
    expect([for (final s in [null, 86400, 604800, 7776000]) disappearLabel(s)], ['Off', '24 hours', '7 days', '90 days']);
  });

  chatTestWidgets('chat info: the sheet sets the timer for everyone and the chat shows the line and the icon', (tester) async {
    final (_, id) = await openChat(tester, path: '/info');
    expect(find.text('Disappearing messages'), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('disappearing-messages')), matching: find.text('Off')), findsOneWidget);

    await tester.tap(find.byKey(const Key('disappearing-messages')));
    await settle(tester);
    expect(find.textContaining("Screenshots and copying aren't blocked"), findsOneWidget);
    for (final label in ['Off', '24 hours', '7 days', '90 days']) {
      expect(find.widgetWithText(ListTile, label), findsWidgets);
    }
    await tester.tap(find.byKey(const Key('disappear-604800')));
    await settle(tester);

    expect(backend.calls, contains('PATCH /chats/$id'));
    expect(backend.chatDto(id).disappearSecs, 604800);
    expect((await inApp(tester, () => alice.db.chatById(id)))!.disappearSecs, 604800);
    expect(find.descendant(of: find.byKey(const Key('disappearing-messages')), matching: find.text('7 days')), findsOneWidget);

    c(tester).read(routerProvider).go('/chats/$id');
    await settle(tester);
    expect(find.text('You turned on disappearing messages: 7 days'), findsOneWidget);
    expect(find.byKey(const Key('disappearing-icon')), findsOneWidget);
    expect(find.text('Say hello 👋'), findsNothing, reason: 'the line shows even with no messages yet');
  });

  chatTestWidgets("the chat's menu turns it off; the line follows the latest change", (tester) async {
    final (hub, id) = await openChat(tester);
    // Bob turns it on from his device; Alice's app hears of it from the `chat` event.
    await tester.runAsync(() => bob.api.setDisappearing(id, 86400));
    hub.emit({'type': 'chat', 'chatId': id});
    await settle(tester);
    expect(find.text('Bob turned on disappearing messages: 24 hours'), findsOneWidget);
    expect(find.byKey(const Key('disappearing-icon')), findsOneWidget);

    await tester.tap(find.byKey(const Key('chat-menu')));
    await settle(tester);
    await tester.tap(find.byKey(const Key('chat-menu-disappearing')));
    await settle(tester);
    // The current choice is marked.
    expect(find.descendant(of: find.byKey(const Key('disappear-86400')), matching: find.byIcon(Icons.check_rounded)), findsOneWidget);
    await tester.tap(find.byKey(const Key('disappear-off')));
    await settle(tester);

    expect(backend.chatDto(id).disappearSecs, isNull);
    expect(find.text('You turned off disappearing messages'), findsOneWidget);
    expect(find.textContaining('Bob turned on'), findsNothing, reason: 'only the latest change is kept');
    expect(find.byKey(const Key('disappearing-icon')), findsNothing);
  });

  chatTestWidgets('picking the current value changes nothing', (tester) async {
    final (_, id) = await openChat(tester, path: '/info');
    await tester.tap(find.byKey(const Key('disappearing-messages')));
    await settle(tester);
    await tester.tap(find.byKey(const Key('disappear-off')));
    await settle(tester);
    expect(backend.calls, isNot(contains('PATCH /chats/$id')));
  });
}
