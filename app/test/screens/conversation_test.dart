import 'package:famchat/chat/db/chat_db.dart';
import 'package:famchat/chat/directory.dart';
import 'package:famchat/chat/wire.dart';
import 'package:famchat/main.dart';
import 'package:famchat/router.dart';
import 'package:famchat/widgets/link_text.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
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

  Future<ScriptedHubLink> open(WidgetTester tester, {List<MessageRow> messages = const []}) async {
    setWindow(tester, const Size(400, 800));
    final hub = await pumpChatApp(tester, alice);
    await inApp(tester, () async {
      await alice.db.upsertChat(direct(alice.userId, bob.userId));
      for (final m in messages) {
        await alice.db.insertMessageIfAbsent(m);
      }
    });
    ProviderScope.containerOf(tester.element(find.byType(FamChatApp))).read(routerProvider).go('/chats/$chatId');
    await settle(tester);
    return hub;
  }

  chatTestWidgets('a direct chat with a former peer shows the read-only footer instead of the composer', (tester) async {
    backend.markFormer(bob.userId);
    await open(tester);
    expect(find.byKey(const Key('no-shared-family')), findsOneWidget);
    expect(find.byKey(const Key('composer')), findsNothing);
    expect(find.text("You're no longer in a family together"), findsOneWidget);
  });

  chatTestWidgets('a direct chat with a deleted peer keeps the composer', (tester) async {
    backend.markDeleted(bob.userId);
    await open(tester);
    expect(find.byKey(const Key('composer')), findsOneWidget);
    expect(find.byKey(const Key('no-shared-family')), findsNothing);
  });

  chatTestWidgets('a group with a former member keeps the composer', (tester) async {
    final carol = await backend.addUser('Carol');
    backend.markFormer(bob.userId);
    setWindow(tester, const Size(400, 800));
    await pumpChatApp(tester, alice);
    await inApp(tester, () async {
      await alice.db.upsertChat(ChatDto(
        id: chatId,
        kind: 'group',
        title: 'G',
        createdBy: alice.userId,
        currentEpoch: 1,
        epochReady: true,
        lastSeq: 0,
        lastMessageAt: null,
        createdAt: 1,
        members: [
          for (final u in [alice, bob, carol]) MemberDto(userId: u.userId, joinedSeq: 0, lastReadSeq: 0),
        ],
      ));
    });
    ProviderScope.containerOf(tester.element(find.byType(FamChatApp))).read(routerProvider).go('/chats/$chatId');
    await settle(tester);
    expect(find.byKey(const Key('composer')), findsOneWidget);
    expect(find.byKey(const Key('no-shared-family')), findsNothing);
  });

  chatTestWidgets('sending shows the message pending, then sent', (tester) async {
    final hub = await open(tester);
    await tester.enterText(find.byKey(const Key('composer')), 'hello there');
    await tester.pump(); // Send replaces the mic once there is text
    await tester.tap(find.byTooltip('Send'));
    await settle(tester);
    expect(find.text('hello there'), findsOneWidget);
    expect(find.byKey(const Key('pending-icon')), findsOneWidget);
    expect(tester.widget<TextField>(find.byKey(const Key('composer'))).controller!.text, isEmpty);
    final pending = (await inApp(tester, () => alice.db.pendingOutbox(alice.deviceId))).single;
    hub.emit({'type': 'ack', 'id': pending.id, 'seq': 1, 'createdAt': 5});
    await settle(tester);
    expect(find.byKey(const Key('pending-icon')), findsNothing);
  });

  chatTestWidgets('incoming message appears and is marked read', (tester) async {
    await open(tester);
    await inApp(tester, () => alice.db.insertMessageIfAbsent(row('m1', 1, bob.userId, 'knock knock')));
    await settle(tester);
    expect(find.text('knock knock'), findsOneWidget);
    expect((await inApp(tester, () => alice.db.chatById(chatId)))!.myLastReadSeq, 1);
  });

  chatTestWidgets('long-press reacts and the count shows', (tester) async {
    await open(tester, messages: [row('m1', 1, bob.userId, 'cake?')]);
    await tester.longPress(find.text('cake?'));
    await settle(tester);
    await tester.tap(find.text('👍'));
    await settle(tester);
    expect(find.text('👍 1'), findsOneWidget);
    final pending = (await inApp(tester, () => alice.db.pendingOutbox(alice.deviceId))).single;
    expect((pending.kind, pending.targetId), ('reaction', 'm1'));
  });

  chatTestWidgets('Seen appears once the other member read it', (tester) async {
    await open(tester, messages: [row('m1', 1, alice.userId, 'did you see?')]);
    expect(find.text('Seen'), findsNothing);
    await inApp(tester, () => alice.db.setMemberRead(chatId, bob.userId, 1));
    await settle(tester);
    expect(find.text('Seen'), findsOneWidget);
  });

  chatTestWidgets('typing indicator shows the other member', (tester) async {
    // The dots loop while someone types; with reduced motion they hold still, so the UI can settle.
    tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    final hub = await open(tester);
    hub.emit({'type': 'typing', 'chatId': chatId, 'userId': bob.userId});
    await settle(tester);
    expect(find.text('Bob is typing…'), findsOneWidget);
    await tester.pump(const Duration(seconds: 6));
    await settle(tester);
    expect(find.text('Bob is typing…'), findsNothing);
  });

  chatTestWidgets('identity change banner can be acknowledged', (tester) async {
    await open(tester);
    await inApp(tester, () async {
      await backend.resetUser(bob.userId);
      await Directory(alice.db, alice.api, alice.me).refresh();
    });
    await settle(tester);
    expect(find.textContaining("Bob's security key changed"), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'OK'));
    await settle(tester);
    expect(find.textContaining("Bob's security key changed"), findsNothing);
  });

  chatTestWidgets('a verified reset shows a banner that can be dismissed, and no key-change banner', (tester) async {
    await open(tester);
    await inApp(tester, () async {
      backend.setAdmin(alice.userId);
      final resetId = await backend.adminReset(bob.userId, by: alice.userId);
      await backend.claimReset(bob.userId, resetId);
      await Directory(alice.db, alice.api, alice.me).refresh();
    });
    await settle(tester);
    expect(find.text("Bob's account was reset by Alice. Their old devices were signed out."), findsOneWidget);
    expect(find.textContaining("Bob's security key changed"), findsNothing);
    await tester.tap(find.widgetWithText(TextButton, 'OK'));
    await settle(tester);
    expect(find.textContaining('account was reset'), findsNothing);
  });

  chatTestWidgets('a new message eases in once; earlier ones stay put', (tester) async {
    await open(tester, messages: [row('m1', 1, bob.userId, 'first')]);
    double opacityOf(String text) => tester
        .widget<FadeTransition>(find.ancestor(of: find.text(text), matching: find.byType(FadeTransition)).first)
        .opacity
        .value;
    expect(opacityOf('first'), 1, reason: 'history on screen when the chat opens does not animate');
    await inApp(tester, () => alice.db.insertMessageIfAbsent(row('m2', 2, bob.userId, 'second')));
    await tester.pump(const Duration(milliseconds: 20));
    expect(opacityOf('second'), lessThan(1));
    await settle(tester);
    expect(opacityOf('second'), 1);
    await inApp(tester, () => alice.db.insertMessageIfAbsent(row('m3', 3, bob.userId, 'third')));
    await tester.pump(const Duration(milliseconds: 20));
    expect(opacityOf('third'), lessThan(1));
    expect(opacityOf('second'), 1, reason: 'an earlier arrival does not replay its entrance');
    await settle(tester);
  });

  chatTestWidgets('a failed message can be retried', (tester) async {
    await open(tester, messages: [row('m9', null, alice.userId, 'oops', state: 'failed').copyWith(senderDeviceId: alice.deviceId)]);
    await tester.tap(find.text('Not sent. Tap to retry'));
    await settle(tester);
    expect((await inApp(tester, () => alice.db.messageById('m9')))!.state, 'pending');
  });

  // Once focused, the platform's text input delivers the following keys (not simulated here).
  chatTestWidgets('typing while the composer is unfocused moves focus there and keeps the key', (tester) async {
    await open(tester);
    FocusManager.instance.primaryFocus?.unfocus();
    await settle(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyH, character: 'h');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyH);
    await settle(tester);
    final field = tester.widget<TextField>(find.byKey(const Key('composer')));
    expect(field.controller!.text, 'h');
    expect(field.focusNode!.hasFocus, isTrue);
  });

  chatTestWidgets('shortcuts with Ctrl are not typed into the composer', (tester) async {
    await open(tester);
    FocusManager.instance.primaryFocus?.unfocus();
    await settle(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyB, character: 'b');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyB);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await settle(tester);
    final field = tester.widget<TextField>(find.byKey(const Key('composer')));
    expect(field.controller!.text, isNot(contains('b')));
    expect(field.focusNode!.hasFocus, isFalse);
  });

  chatTestWidgets('hovering a link in a message shows the link cursor', (tester) async {
    await open(tester, messages: [row('m1', 1, bob.userId, 'look at https://example.com today')]);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    final text = find.byType(LinkText);
    // The test font's glyphs are squares of the font size: character 12 is inside the link.
    final box = tester.getRect(text);
    await mouse.moveTo(Offset(box.left + 16 * 12.5, box.top + 8));
    await tester.pump();
    expect(RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1), SystemMouseCursors.click);
  });
}
