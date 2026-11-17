import 'package:famchat/chat/db/chat_db.dart';
import 'package:famchat/chat/wire.dart';
import 'package:famchat/main.dart';
import 'package:famchat/router.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
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

// Desktop spell checking. Its own file: the app's theme (and so which kind of text menu shows) is
// built once per test process, under the platform of the first test.
void main() {
  late FakeChatBackend backend;
  late TestDevice alice, bob;

  setUp(() async {
    backend = FakeChatBackend();
    alice = await backend.addUser('Alice');
    bob = await backend.addUser('Bob');
  });

  Future<void> open(WidgetTester tester) async {
    setWindow(tester, const Size(400, 800));
    await pumpChatApp(tester, alice);
    await inApp(tester, () => alice.db.upsertChat(direct(alice.userId, bob.userId)));
    ProviderScope.containerOf(tester.element(find.byType(FamChatApp))).read(routerProvider).go('/chats/$chatId');
    await settle(tester);
  }

  group('spelling on desktop', () {
    void desktopTest(String name, Future<void> Function(WidgetTester) body) => chatTestWidgets(name, (tester) async {
          debugDefaultTargetPlatformOverride = TargetPlatform.linux;
          try {
            await open(tester);
            await body(tester);
          } finally {
            debugDefaultTargetPlatformOverride = null;
          }
        });

    Offset at(WidgetTester tester, int offset) {
      final editable = tester.state<EditableTextState>(find.descendant(of: find.byKey(const Key('composer')), matching: find.byType(EditableText)));
      final r = editable.renderEditable;
      return r.localToGlobal(r.getLocalRectForCaret(TextPosition(offset: offset)).center);
    }

    Future<void> rightClick(WidgetTester tester, int offset) async {
      await tester.tapAt(at(tester, offset), buttons: kSecondaryMouseButton, kind: PointerDeviceKind.mouse);
      await settle(tester);
    }

    desktopTest('right-clicking a misspelled word offers corrections that replace it', (tester) async {
      await tester.enterText(find.byKey(const Key('composer')), 'i recieve it');
      await settle(tester);
      await rightClick(tester, 5);
      expect(find.text('receive'), findsOneWidget);
      expect(find.text('Add to dictionary'), findsOneWidget);
      await tester.tap(find.text('receive'));
      await settle(tester);
      expect(tester.widget<TextField>(find.byKey(const Key('composer'))).controller!.text, 'i receive it');
    });

    desktopTest('a word added to the dictionary is no longer flagged', (tester) async {
      await tester.enterText(find.byKey(const Key('composer')), 'the zorblax is here');
      await settle(tester);
      await rightClick(tester, 6);
      await tester.tap(find.text('Add to dictionary'));
      await settle(tester);
      await rightClick(tester, 6);
      expect(find.text('Add to dictionary'), findsNothing);
      expect(await inApp(tester, () => alice.db.metaValue('spelling.words')), contains('zorblax'));
    });

    desktopTest("family members' names are not flagged", (tester) async {
      await tester.enterText(find.byKey(const Key('composer')), 'hi Bob there');
      await settle(tester);
      await rightClick(tester, 4);
      expect(find.text('Add to dictionary'), findsNothing);
    });
  });
}
