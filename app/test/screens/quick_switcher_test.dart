import 'package:famchat/chat/wire.dart';
import 'package:famchat/screens/chats/conversation_view.dart';
import 'package:famchat/screens/chats/new_chat_screen.dart';
import 'package:famchat/screens/chats/quick_switcher.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../support/chat_harness.dart';
import '../support/fake_chat_backend.dart';

ChatDto dto(String id, String kind, List<String> members, {String? title, int at = 1}) => ChatDto(
      id: id,
      kind: kind,
      title: title,
      createdBy: members.first,
      currentEpoch: 1,
      epochReady: true,
      lastSeq: 0,
      lastMessageAt: at,
      createdAt: 1,
      members: [for (final m in members) MemberDto(userId: m, joinedSeq: 0, lastReadSeq: 0)],
    );

void main() {
  group('rankChats', () {
    final titles = ['Cousins', 'Bob', 'Grandma Rose', 'Robert', 'Book club'];
    List<String> rank(String q) => rankChats(q, titles, (t) => t);

    test('empty query keeps every chat in order', () => expect(rank('  '), titles));
    test('title prefix, then word prefix, then anywhere', () {
      expect(rank('bo'), ['Bob', 'Book club']);
      expect(rank('ro'), ['Robert', 'Grandma Rose']);
      expect(rank('ob'), ['Bob', 'Robert']);
    });
    test('case-insensitive, and nothing for no match', () {
      expect(rank('COUS'), ['Cousins']);
      expect(rank('zzz'), isEmpty);
    });
  });

  group('shortcuts', () {
    late FakeChatBackend backend;
    late TestDevice alice, bob, carol;

    setUp(() async {
      backend = FakeChatBackend();
      alice = await backend.addUser('Alice');
      bob = await backend.addUser('Bob');
      carol = await backend.addUser('Carol');
    });

    Future<void> seed(WidgetTester tester) => tester.runAsync(() async {
          await alice.db.bindDevice(alice.deviceId);
          await alice.db.upsertChat(dto('direct1', 'direct', [alice.userId, bob.userId], at: 100));
          await alice.db.upsertChat(dto('group1', 'group', [alice.userId, bob.userId, carol.userId], title: 'Cousins', at: 200));
        });

    Future<void> chord(WidgetTester tester, LogicalKeyboardKey key) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(key);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await settle(tester);
    }

    chatTestWidgets('Ctrl+K finds a chat and Enter opens it; Esc closes it', (tester) async {
      setWindow(tester, const Size(1000, 800));
      await seed(tester);
      await pumpChatApp(tester, alice);
      await chord(tester, LogicalKeyboardKey.keyK);
      expect(find.byKey(const Key('quick-switcher')), findsOneWidget);
      await tester.enterText(find.byKey(const Key('quick-switcher-field')), 'bo');
      await settle(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settle(tester);
      expect(find.byKey(const Key('quick-switcher')), findsNothing);
      expect(find.byType(ConversationView), findsOneWidget);
      expect(find.text('Pick a chat'), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      expect(find.byType(ConversationView), findsNothing);
      expect(find.text('Pick a chat'), findsOneWidget);
    });

    chatTestWidgets('Enter with no match does nothing', (tester) async {
      setWindow(tester, const Size(1000, 800));
      await seed(tester);
      await pumpChatApp(tester, alice);
      await chord(tester, LogicalKeyboardKey.keyK);
      await tester.enterText(find.byKey(const Key('quick-switcher-field')), 'zzz');
      await settle(tester);
      expect(find.text('No chat matches'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settle(tester);
      expect(find.byKey(const Key('quick-switcher')), findsOneWidget);
    });

    chatTestWidgets('Ctrl+N starts a new chat', (tester) async {
      setWindow(tester, const Size(1000, 800));
      await seed(tester);
      await pumpChatApp(tester, alice);
      await chord(tester, LogicalKeyboardKey.keyN);
      expect(find.byType(NewChatScreen), findsOneWidget);
      expect(find.byKey(const Key('quick-switcher')), findsNothing);
    });
  });
}
