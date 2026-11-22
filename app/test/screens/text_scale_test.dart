// Key screens at 200 % text on a phone: nothing overflows (an overflow fails the test), and every
// icon button says what it does.
import 'package:famchat/chat/db/chat_db.dart';
import 'package:famchat/chat/wire.dart';
import 'package:famchat/main.dart';
import 'package:famchat/router.dart';
import 'package:famchat/session/secure_kv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../support/app_harness.dart';
import '../support/chat_harness.dart';
import '../support/fake_chat_backend.dart';
import '../support/fake_server.dart';

ChatDto dto(String id, String kind, List<String> members, {String? title}) => ChatDto(
      id: id,
      kind: kind,
      title: title,
      createdBy: members.first,
      currentEpoch: 1,
      epochReady: true,
      lastSeq: 2,
      lastMessageAt: 1,
      createdAt: 1,
      members: [for (final m in members) MemberDto(userId: m, joinedSeq: 0, lastReadSeq: 0)],
    );

MessageRow text(String id, String chatId, int? seq, String from, String body, {String state = 'sent', String device = 'x'}) => MessageRow(
      id: id,
      chatId: chatId,
      seq: seq,
      senderUserId: from,
      senderDeviceId: device,
      kind: 'text',
      body: '{"kind":"text","text":"$body"}',
      targetId: null,
      envelope: null,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      state: state,
    );

void bigText(WidgetTester tester) {
  tester.platformDispatcher.textScaleFactorTestValue = 2;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

void expectLabelledIconButtons(WidgetTester tester) {
  for (final b in tester.widgetList<IconButton>(find.byType(IconButton))) {
    expect(b.tooltip, isNotNull, reason: 'icon button without a tooltip: ${b.icon}');
  }
}

void main() {
  testWidgets('join screen', (tester) async {
    setWindow(tester, const Size(400, 800));
    bigText(tester);
    await pumpApp(tester, server: FakeServer(), kv: MemorySecureKv());
    expect(find.text('Join FamChat'), findsOneWidget);
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -2000));
    await tester.pumpAndSettle();
    expectLabelledIconButtons(tester);
  });

  group('signed in', () {
    late FakeChatBackend backend;
    late TestDevice alice, bob, carol;

    setUp(() async {
      backend = FakeChatBackend();
      alice = await backend.addUser('Alice');
      bob = await backend.addUser('Bartholomew Montgomery-Fitzgerald the Third');
      carol = await backend.addUser('Carol');
    });

    Future<void> seed(WidgetTester tester) => tester.runAsync(() async {
          await alice.db.bindDevice(alice.deviceId);
          await alice.db.upsertChat(dto('direct1', 'direct', [alice.userId, bob.userId]));
          await alice.db.upsertChat(dto('group1', 'group', [alice.userId, bob.userId, carol.userId],
              title: 'The extended family reunion planning committee'));
          await alice.db.insertMessageIfAbsent(text('m1', 'group1', 1, bob.userId,
              'A long message that wraps over several lines when the text is twice as big as usual'));
          await alice.db.insertMessageIfAbsent(text('m2', 'group1', 2, alice.userId, 'Sounds good'));
          await alice.db.insertMessageIfAbsent(text('m3', 'group1', null, alice.userId, 'oops', state: 'failed', device: alice.deviceId));
          // Read already: a chat with unread messages opens at its "New messages" line instead.
          await alice.db.setMyLastRead('group1', 2);
        });

    void go(WidgetTester tester, String path) =>
        ProviderScope.containerOf(tester.element(find.byType(FamChatApp))).read(routerProvider).go(path);

    const shows = {
      '/': 'The extended family reunion',
      '/chats/group1': 'Not sent. Tap to retry',
      '/chats/direct1': 'Say hello 👋',
      '/chats/group1/info': 'Add people',
      '/settings': 'Devices',
      '/new': 'Carol',
    };
    for (final MapEntry(key: path, value: expected) in shows.entries) {
      chatTestWidgets(path, (tester) async {
        setWindow(tester, const Size(400, 800));
        bigText(tester);
        await seed(tester);
        await pumpChatApp(tester, alice, admin: true);
        go(tester, path);
        await settle(tester);
        expect(find.textContaining(expected), findsWidgets);
        expectLabelledIconButtons(tester);
      });
    }
  });
}
