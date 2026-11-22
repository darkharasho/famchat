// Polls in a conversation: making one, voting, see votes, ending, and the chat list.
import 'dart:convert';

import 'package:famchat/chat/db/chat_db.dart';
import 'package:famchat/chat/wire.dart';
import 'package:famchat/main.dart';
import 'package:famchat/router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../support/chat_harness.dart';
import '../support/fake_chat_backend.dart';

const chatId = '01JC0000000000000000000001';

MessageRow row(String id, int seq, String from, String kind, Map<String, Object?> body, {String? target}) => MessageRow(
      id: id,
      chatId: chatId,
      seq: seq,
      senderUserId: from,
      senderDeviceId: 'x',
      kind: kind,
      body: jsonEncode({'kind': kind, ...body}),
      targetId: target,
      envelope: null,
      createdAt: DateTime.now().subtract(Duration(minutes: 100 - seq)).millisecondsSinceEpoch,
      state: 'sent',
    );

MessageRow poll(String id, int seq, String from, String q, List<String> options, {bool multi = false}) =>
    row(id, seq, from, 'poll', {'question': q, 'options': options, 'multi': multi});

MessageRow vote(String id, int seq, String from, String target, List<int> choices) =>
    row(id, seq, from, 'vote', {'target': target, 'choices': choices}, target: target);

void main() {
  late FakeChatBackend backend;
  late TestDevice alice, bob, carol;

  setUp(() async {
    backend = FakeChatBackend();
    alice = await backend.addUser('Alice');
    bob = await backend.addUser('Bob');
    carol = await backend.addUser('Carol');
  });

  Future<void> seed(WidgetTester tester, List<MessageRow> messages, {bool group = false, int read = -1}) => inApp(tester, () async {
        await alice.db.upsertChat(ChatDto(
          id: chatId,
          kind: group ? 'group' : 'direct',
          title: group ? 'Cousins' : null,
          createdBy: alice.userId,
          currentEpoch: 1,
          epochReady: true,
          lastSeq: messages.length,
          lastMessageAt: null,
          createdAt: 1,
          members: [
            MemberDto(userId: alice.userId, joinedSeq: 0, lastReadSeq: read < 0 ? messages.length : read),
            MemberDto(userId: bob.userId, joinedSeq: 0, lastReadSeq: 0),
            if (group) MemberDto(userId: carol.userId, joinedSeq: 0, lastReadSeq: 0),
          ],
        ));
        for (final m in messages) {
          await alice.db.insertMessageIfAbsent(m);
        }
      });

  Future<void> open(WidgetTester tester, List<MessageRow> messages, {bool group = false}) async {
    setWindow(tester, const Size(400, 800));
    await pumpChatApp(tester, alice);
    await seed(tester, messages, group: group);
    ProviderScope.containerOf(tester.element(find.byType(FamChatApp))).read(routerProvider).go('/chats/$chatId');
    await settle(tester);
  }

  Future<List<MessageRow>> rows(WidgetTester tester) => inApp(tester, () => alice.db.select(alice.db.localMessages).get());

  String count(WidgetTester tester, int i) => tester.widget<Text>(find.byKey(Key('poll-count-$i'))).data!;
  String summary(WidgetTester tester) => tester.widget<Text>(find.byKey(const Key('poll-summary'))).data!;

  Future<void> tapOption(WidgetTester tester, int i) async {
    await tester.tap(find.byKey(Key('poll-option-$i')));
    await settle(tester);
  }

  chatTestWidgets('making a single-choice poll from the + menu sends it and shows it', (tester) async {
    await open(tester, []);
    await tester.tap(find.byTooltip('Attach'));
    await settle(tester);
    await tester.tap(find.text('Poll'));
    await settle(tester);

    bool sendOn() => tester.widget<FilledButton>(find.byKey(const Key('poll-send'))).onPressed != null;
    expect(sendOn(), isFalse);
    expect(find.byKey(const Key('poll-remove-0')), findsNothing, reason: 'two options can not be removed');
    expect(tester.widget<SwitchListTile>(find.byKey(const Key('poll-multi'))).value, isFalse);
    expect(find.text('Off means everyone picks one'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('poll-question')), 'Thanksgiving dinner?');
    await tester.enterText(find.byKey(const Key('poll-option-field-0')), 'Thursday');
    await tester.enterText(find.byKey(const Key('poll-option-field-1')), 'thursday');
    await tester.pump();
    expect(sendOn(), isFalse, reason: 'two options alike');
    expect(find.text('Two options are the same.'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('poll-option-field-1')), 'Saturday');
    await tester.tap(find.byKey(const Key('poll-add-option')));
    await tester.pump();
    expect(find.byKey(const Key('poll-remove-2')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('poll-option-field-2')), 'Sunday');
    await tester.tap(find.byKey(const Key('poll-remove-2')));
    await tester.pump();
    expect(find.byKey(const Key('poll-option-field-2')), findsNothing);
    expect(sendOn(), isTrue);
    await tester.tap(find.byKey(const Key('poll-send')));
    await settle(tester);

    expect(find.text('Thanksgiving dinner?'), findsOneWidget);
    expect(summary(tester), 'Pick one · 0 voted');
    expect(find.text('Tap to vote'), findsOneWidget);
    final sent = (await rows(tester)).single;
    expect(sent.kind, 'poll');
    expect(jsonDecode(sent.body!), {'kind': 'poll', 'question': 'Thanksgiving dinner?', 'options': ['Thursday', 'Saturday'], 'multi': false});
  });

  chatTestWidgets("Bob's vote shows in the count and with his face", (tester) async {
    await open(tester, [
      poll('p1', 1, alice.userId, 'Pizza or tacos?', ['Pizza', 'Tacos']),
      vote('v1', 2, bob.userId, 'p1', [1]),
    ]);
    expect(summary(tester), 'Pick one · 1 voted');
    expect((count(tester, 0), count(tester, 1)), ('0', '1'));
    expect(find.byKey(Key('poll-face-1-${bob.userId}')), findsOneWidget);
    expect(find.byKey(Key('poll-face-0-${bob.userId}')), findsNothing);
    expect(find.byIcon(Icons.radio_button_unchecked_rounded), findsNWidgets(2), reason: 'round marks, nothing picked by me');
  });

  chatTestWidgets('a single-choice vote moves with each tap; tapping the pick again takes it back', (tester) async {
    await open(tester, [
      poll('p1', 1, bob.userId, 'Pizza or tacos?', ['Pizza', 'Tacos']),
      vote('v1', 2, bob.userId, 'p1', [1]),
    ]);
    await tapOption(tester, 0);
    expect((count(tester, 0), count(tester, 1)), ('1', '1'));
    expect(find.text('Tap to change'), findsOneWidget);
    expect(find.byKey(Key('poll-face-0-${alice.userId}')), findsOneWidget);

    await tapOption(tester, 1);
    expect((count(tester, 0), count(tester, 1)), ('0', '2'));
    expect(summary(tester), 'Pick one · 2 voted');

    await tapOption(tester, 1);
    expect((count(tester, 0), count(tester, 1)), ('0', '1'));
    expect(find.text('Tap to vote'), findsOneWidget);
    final votes = [for (final r in await rows(tester)) if (r.kind == 'vote' && r.senderUserId == alice.userId) jsonDecode(r.body!)['choices']];
    expect(votes, [[0], [1], []]);
  });

  chatTestWidgets('multiple choice: taps toggle each option in my set', (tester) async {
    await open(tester, [poll('p1', 1, bob.userId, 'Which days work?', ['Thu', 'Fri', 'Sat'], multi: true)]);
    expect(summary(tester), 'Pick one or more · 0 voted');
    expect(find.byIcon(Icons.check_box_outline_blank_rounded), findsNWidgets(3));
    await tapOption(tester, 0);
    await tapOption(tester, 2);
    expect([for (var i = 0; i < 3; i++) count(tester, i)], ['1', '0', '1']);
    expect(find.text('You picked 2'), findsOneWidget);
    expect(find.byIcon(Icons.check_box_rounded), findsNWidgets(2));
    await tapOption(tester, 0);
    expect([for (var i = 0; i < 3; i++) count(tester, i)], ['0', '0', '1']);
    expect(find.text('You picked 1'), findsOneWidget);
    expect(summary(tester), 'Pick one or more · 1 voted');
  });

  chatTestWidgets("multiple choice: a quick second tap keeps the first pick", (tester) async {
    await open(tester, [poll('p1', 1, bob.userId, 'Which days work?', ['Thu', 'Fri', 'Sat'], multi: true)]);
    await tester.tap(find.byKey(const Key('poll-option-0')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('poll-option-2')));
    await settle(tester);
    final votes = [for (final r in await rows(tester)) if (r.kind == 'vote') jsonDecode(r.body!)['choices']];
    expect(votes.last, [0, 2]);
    expect([for (var i = 0; i < 3; i++) count(tester, i)], ['1', '0', '1']);
  });

  chatTestWidgets("See votes lists who picked what, then who hasn't voted", (tester) async {
    await open(tester, [
      poll('p1', 1, bob.userId, 'Pizza or tacos?', ['Pizza', 'Tacos']),
      vote('v1', 2, bob.userId, 'p1', [0]),
    ], group: true);
    await tester.tap(find.byKey(const Key('poll-see-votes')));
    await settle(tester);
    final sheet = find.byKey(const Key('poll-votes-sheet'));
    expect(sheet, findsOneWidget);
    Finder inSheet(String text) => find.descendant(of: sheet, matching: find.text(text));
    expect(inSheet('Pizza'), findsOneWidget);
    expect(inSheet('Bob'), findsOneWidget);
    expect(inSheet("Hasn't voted:"), findsOneWidget);
    expect(inSheet('Carol'), findsOneWidget);
    expect(inSheet('You'), findsOneWidget);
    // In order: Pizza, Bob, Tacos, Hasn't voted, then the rest.
    double y(String t) => tester.getTopLeft(inSheet(t)).dy;
    expect(y('Pizza') < y('Bob') && y('Bob') < y('Tacos') && y('Tacos') < y("Hasn't voted:") && y("Hasn't voted:") < y('Carol'), isTrue);
  });

  chatTestWidgets("only the creator sees End poll; Bob's poll has none", (tester) async {
    await open(tester, [poll('p1', 1, bob.userId, 'Pizza or tacos?', ['Pizza', 'Tacos'])]);
    expect(find.byKey(const Key('poll-see-votes')), findsOneWidget);
    expect(find.byKey(const Key('poll-end')), findsNothing);
  });

  chatTestWidgets('ending my poll after confirming freezes it: ENDED, no marks, 🏆 on the winner', (tester) async {
    await open(tester, [
      poll('p1', 1, alice.userId, 'Pizza or tacos?', ['Pizza', 'Tacos']),
      vote('v1', 2, bob.userId, 'p1', [1]),
    ]);
    await tester.tap(find.byKey(const Key('poll-end')));
    await settle(tester);
    expect(find.text('End poll?'), findsOneWidget);
    expect(find.textContaining("can't be undone"), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await settle(tester);
    expect(find.byKey(const Key('poll-ended')), findsNothing);

    await tester.tap(find.byKey(const Key('poll-end')));
    await settle(tester);
    await tester.tap(find.byKey(const Key('poll-end-confirm')));
    await settle(tester);
    expect(find.text('ENDED'), findsOneWidget);
    expect(find.byKey(const Key('poll-end')), findsNothing);
    expect(find.text('Tacos 🏆'), findsOneWidget);
    expect(tester.widget<Text>(find.text('Tacos 🏆')).style?.fontWeight, FontWeight.w700);
    expect(find.text('Pizza'), findsOneWidget);
    expect(find.byIcon(Icons.radio_button_unchecked_rounded), findsNothing);
    expect(find.text('Tap to vote'), findsNothing);
    final before = (await rows(tester)).length;
    await tapOption(tester, 0);
    expect((await rows(tester)).length, before, reason: 'taps on an ended poll do nothing');
    expect((count(tester, 0), count(tester, 1)), ('0', '1'));
    final ends = [for (final r in await rows(tester)) if (r.kind == 'poll_end') r];
    expect(ends.single.targetId, 'p1');
  });

  chatTestWidgets("a poll's actions: reply, pin, star and delete, but no forward, edit or copy", (tester) async {
    await open(tester, [poll('p1', 1, alice.userId, 'Pizza or tacos?', ['Pizza', 'Tacos'])]);
    await tester.longPress(find.text('Pizza or tacos?'));
    await settle(tester);
    for (final a in ['Reply', 'Pin for everyone', 'Star', 'Delete']) {
      expect(find.text(a), findsOneWidget, reason: a);
    }
    for (final a in ['Forward', 'Edit', 'Copy']) {
      expect(find.text(a), findsNothing, reason: a);
    }
    await tester.tap(find.text('Reply'));
    await settle(tester);
    expect(find.text('📊 Pizza or tacos?'), findsOneWidget, reason: 'the reply banner quotes the question');

    // A poll sent now replies to it, and quotes it.
    await tester.tap(find.byTooltip('Attach'));
    await settle(tester);
    await tester.tap(find.text('Poll'));
    await settle(tester);
    await tester.enterText(find.byKey(const Key('poll-question')), 'Toppings?');
    await tester.enterText(find.byKey(const Key('poll-option-field-0')), 'Ham');
    await tester.enterText(find.byKey(const Key('poll-option-field-1')), 'Olives');
    await tester.tap(find.byKey(const Key('poll-multi')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('poll-send')));
    await settle(tester);
    final sent = (await rows(tester)).firstWhere((r) => r.id != 'p1' && r.kind == 'poll');
    expect(jsonDecode(sent.body!), containsPair('replyTo', 'p1'));
    expect(jsonDecode(sent.body!), containsPair('multi', true));
    expect(find.textContaining('Replying to'), findsNothing, reason: 'the reply is done');
    expect(find.text('📊 Pizza or tacos?'), findsOneWidget, reason: "the new poll's quote");
  });

  chatTestWidgets('a deleted poll shows as deleted', (tester) async {
    await open(tester, [
      poll('p1', 1, alice.userId, 'Pizza or tacos?', ['Pizza', 'Tacos']),
      row('d1', 2, alice.userId, 'delete', {'target': 'p1'}, target: 'p1'),
    ]);
    expect(find.text('This message was deleted.'), findsOneWidget);
    expect(find.byKey(const Key('poll-option-0')), findsNothing);
  });

  chatTestWidgets("the chat list shows the poll; votes aren't unread and aren't the preview", (tester) async {
    setWindow(tester, const Size(400, 800));
    await pumpChatApp(tester, alice);
    await seed(tester, [
      poll('p1', 1, bob.userId, 'Pizza or tacos?', ['Pizza', 'Tacos']),
      vote('v1', 2, bob.userId, 'p1', [0]),
      vote('v2', 3, carol.userId, 'p1', [1]),
    ], group: true, read: 0);
    await settle(tester);
    expect(find.text('Cousins'), findsOneWidget);
    expect(find.text('📊 Poll: Pizza or tacos?'), findsOneWidget);
    expect(find.text('1'), findsOneWidget, reason: 'the poll is unread, its votes are not');
    expect(find.text('3'), findsNothing);
  });

  chatTestWidgets("Bob's vote on my poll isn't unread and doesn't become the preview", (tester) async {
    setWindow(tester, const Size(400, 800));
    await pumpChatApp(tester, alice);
    await seed(tester, [
      poll('p1', 1, alice.userId, 'Pizza or tacos?', ['Pizza', 'Tacos']),
      vote('v1', 2, bob.userId, 'p1', [0]),
    ], read: 1);
    await settle(tester);
    expect(find.text('You: 📊 Poll: Pizza or tacos?'), findsOneWidget);
    expect(find.text('1'), findsNothing, reason: "Bob's vote is not unread");
  });
}
