import 'package:emoji_picker_flutter/emoji_picker_flutter.dart' show EmojiPicker;
import 'package:famchat/chat/db/chat_db.dart';
import 'package:famchat/chat/emoji/shortcodes.dart';
import 'package:famchat/chat/wire.dart';
import 'package:famchat/main.dart';
import 'package:famchat/router.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/chat_harness.dart';
import '../support/fake_chat_backend.dart';

const chatId = '01JC0000000000000000000001';

void main() {
  late FakeChatBackend backend;
  late TestDevice alice, bob;

  setUp(() async {
    SharedPreferences.setMockInitialValues({}); // the picker keeps recently used emoji there
    backend = FakeChatBackend();
    alice = await backend.addUser('Alice');
    bob = await backend.addUser('Bob');
  });

  Future<void> open(WidgetTester tester, {Size size = const Size(400, 800), List<MessageRow> messages = const []}) async {
    setWindow(tester, size);
    await pumpChatApp(tester, alice);
    await inApp(tester, () async {
      await alice.db.upsertChat(ChatDto(
        id: chatId,
        kind: 'direct',
        title: null,
        createdBy: alice.userId,
        currentEpoch: 1,
        epochReady: true,
        lastSeq: 0,
        lastMessageAt: null,
        createdAt: 1,
        members: [
          MemberDto(userId: alice.userId, joinedSeq: 0, lastReadSeq: 0),
          MemberDto(userId: bob.userId, joinedSeq: 0, lastReadSeq: 0),
        ],
      ));
      for (final m in messages) {
        await alice.db.insertMessageIfAbsent(m);
      }
    });
    ProviderScope.containerOf(tester.element(find.byType(FamChatApp))).read(routerProvider).go('/chats/$chatId');
    await settle(tester);
  }

  final composer = find.byKey(const Key('composer'));
  TextEditingController text(WidgetTester tester) => tester.widget<TextField>(composer).controller!;

  group('picker', () {
    chatTestWidgets('on a phone it replaces the keyboard and inserts at the cursor', (tester) async {
      await open(tester);
      await tester.enterText(composer, 'hello world');
      text(tester).selection = const TextSelection.collapsed(offset: 5);
      await tester.pump();

      await tester.tap(find.byTooltip('Emoji'));
      await settle(tester);
      expect(find.byType(EmojiPicker), findsOneWidget);
      expect(find.byTooltip('Keyboard'), findsOneWidget, reason: 'the button now brings the keyboard back');

      await tester.tap(find.text('😀'));
      await settle(tester);
      expect(text(tester).text, 'hello😀 world');
      expect(text(tester).selection, const TextSelection.collapsed(offset: 7));

      // A selection is replaced.
      text(tester).selection = const TextSelection(baseOffset: 7, extentOffset: 13);
      await tester.tap(find.text('😀').last);
      await settle(tester);
      expect(text(tester).text, 'hello😀😀');

      // Tapping the field brings the keyboard back in place of the picker.
      await tester.tap(composer);
      await settle(tester);
      expect(find.byType(EmojiPicker), findsNothing);
      expect(find.byTooltip('Emoji'), findsOneWidget);
    });

    chatTestWidgets('on desktop it is a popover that closes after a pick', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      try {
        await open(tester, size: const Size(1000, 800));
        await tester.enterText(composer, 'party ');
        await tester.tap(find.byTooltip('Emoji'));
        await settle(tester);
        expect(find.byKey(const Key('emoji-popover')), findsOneWidget);

        await tester.tap(find.text('😀'));
        await settle(tester);
        expect(text(tester).text, 'party 😀');
        expect(find.byKey(const Key('emoji-popover')), findsNothing);

        // Search, and the recently used tab now leads with the last pick.
        await tester.tap(find.byTooltip('Emoji'));
        await settle(tester);
        final popover = find.byKey(const Key('emoji-popover'));
        expect(find.descendant(of: popover, matching: find.text('😀')), findsOneWidget);
        expect(find.descendant(of: popover, matching: find.text('😃')), findsNothing, reason: 'recents tab first');
        await tester.tap(find.descendant(of: popover, matching: find.byIcon(Icons.search)));
        await settle(tester);
        await tester.enterText(find.descendant(of: popover, matching: find.byType(EditableText)), 'pizza');
        await settle(tester);
        await tester.tap(find.text('🍕'));
        await settle(tester);
        expect(text(tester).text, 'party 😀🍕');

        // Esc closes it too.
        await tester.tap(find.byTooltip('Emoji'));
        await settle(tester);
        expect(find.byKey(const Key('emoji-popover')), findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await settle(tester);
        expect(find.byKey(const Key('emoji-popover')), findsNothing);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });

  group(':shortcode:', () {
    final suggestions = find.byKey(const Key('shortcode-suggestions'));

    chatTestWidgets('suggestions appear after two letters and a tap inserts one', (tester) async {
      await open(tester);
      await tester.enterText(composer, 'go :t');
      await settle(tester);
      expect(suggestions, findsNothing);

      await tester.enterText(composer, 'go :tad');
      await settle(tester);
      expect(suggestions, findsOneWidget);
      await tester.tap(find.byKey(const Key('shortcode-tada')));
      await settle(tester);
      expect(text(tester).text, 'go 🎉');
      expect(suggestions, findsNothing);
    });

    chatTestWidgets('arrow keys move through the list; Enter and Tab insert; Esc closes', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      try {
        await open(tester, size: const Size(1000, 800));
        final fi = searchShortcodes('fi', limit: 6);
        await tester.tap(composer);
        await tester.enterText(composer, 'nice :fi');
        await settle(tester);
        expect(suggestions, findsOneWidget);
        expect(find.byKey(Key('shortcode-${fi[0].name}')), findsOneWidget);

        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await settle(tester);
        expect(text(tester).text, 'nice ${fi[1].emoji}', reason: 'Enter inserts instead of sending');
        expect(await inApp(tester, () => alice.db.pendingOutbox(alice.deviceId)), isEmpty);

        await tester.enterText(composer, ':heart');
        await settle(tester);
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await settle(tester);
        expect(text(tester).text, '❤️');

        await tester.enterText(composer, 'a :smi');
        await settle(tester);
        expect(suggestions, findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await settle(tester);
        expect(suggestions, findsNothing);
        expect(text(tester).text, 'a :smi');
        expect(find.byKey(const Key('composer')), findsOneWidget, reason: 'Esc did not close the chat');
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    chatTestWidgets('a full :name: becomes the emoji as the closing colon is typed', (tester) async {
      await open(tester);
      await tester.enterText(composer, 'yes :thumbsup');
      await tester.enterText(composer, 'yes :thumbsup:');
      await settle(tester);
      expect(text(tester).text, 'yes 👍');
      expect(suggestions, findsNothing);
    });

    chatTestWidgets('URLs, times and mid-word colons stay as typed', (tester) async {
      await open(tester);
      for (final typed in ['http://example.com', 'at 10:30', 'a:b', 'a:smile:']) {
        await tester.enterText(composer, typed.substring(0, typed.length - 1));
        await tester.enterText(composer, typed);
        await settle(tester);
        expect(text(tester).text, typed);
        expect(suggestions, findsNothing, reason: typed);
      }
    });
  });

  chatTestWidgets('a message of only a few emoji shows bigger', (tester) async {
    MessageRow row(String id, int seq, String body) => MessageRow(
          id: id,
          chatId: chatId,
          seq: seq,
          senderUserId: bob.userId,
          senderDeviceId: 'x',
          kind: 'text',
          body: '{"kind":"text","text":"$body"}',
          targetId: null,
          envelope: null,
          createdAt: DateTime.now().millisecondsSinceEpoch,
          state: 'sent',
        );
    await open(tester, messages: [row('m1', 1, '🎉🎉'), row('m2', 2, 'hi 🎉'), row('m3', 3, '🎉🎉🎉🎉')]);
    double size(String s) => tester.widget<Text>(find.text(s)).style!.fontSize!;
    expect(size('🎉🎉'), greaterThan(size('hi 🎉') * 1.5));
    expect(size('🎉🎉🎉🎉'), size('hi 🎉'), reason: 'four or more stay normal size');
  });
}
