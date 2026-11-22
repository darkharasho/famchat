// Chat info → Media, links and starred; Settings → Starred messages.
import 'dart:convert';
import 'dart:typed_data';

import 'package:famchat/chat/db/chat_db.dart';
import 'package:famchat/chat/plaintext.dart';
import 'package:famchat/chat/wire.dart';
import 'package:famchat/main.dart';
import 'package:famchat/router.dart';
import 'package:famchat/screens/chats/chat_media_screen.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../support/chat_harness.dart';
import '../support/fake_chat_backend.dart';

const chatA = '01JC0000000000000000000001', chatB = '01JC0000000000000000000002';
final now = DateTime.now();

MessageRow row(String chatId, String id, int seq, String from, Plaintext p, {DateTime? at}) => MessageRow(
      id: id,
      chatId: chatId,
      seq: seq,
      senderUserId: from,
      senderDeviceId: 'x',
      kind: p.kind,
      body: jsonEncode(p.toJson()),
      targetId: p is DeleteBody ? p.target : null,
      envelope: null,
      createdAt: (at ?? now.subtract(Duration(minutes: 100 - seq))).millisecondsSinceEpoch,
      state: 'sent',
    );

PhotoBody photo() => PhotoBody(
      mediaKey: '01JMEDAA000000000000000000',
      thumbKey: '01JTHMB0000000000000000000',
      key: Uint8List.fromList(List.filled(32, 1)),
      sha256: Uint8List.fromList(List.filled(32, 2)),
      thumbSha256: Uint8List.fromList(List.filled(32, 3)),
      width: 20,
      height: 10,
      bytes: 500,
    );

void main() {
  late FakeChatBackend backend;
  late TestDevice alice, bob;

  setUp(() async {
    backend = FakeChatBackend();
    alice = await backend.addUser('Alice');
    bob = await backend.addUser('Bob');
  });

  ChatDto chat(String id, String title) => ChatDto(
        id: id,
        kind: 'group',
        title: title,
        createdBy: alice.userId,
        currentEpoch: 1,
        epochReady: true,
        lastSeq: 9,
        lastMessageAt: null,
        createdAt: 1,
        members: [
          MemberDto(userId: alice.userId, joinedSeq: 0, lastReadSeq: 9),
          MemberDto(userId: bob.userId, joinedSeq: 0, lastReadSeq: 0),
        ],
      );

  Future<GoRouter> start(WidgetTester tester, Map<String, List<MessageRow>> chats) async {
    setWindow(tester, const Size(400, 800));
    await pumpChatApp(tester, alice);
    await inApp(tester, () async {
      for (final e in chats.entries) {
        await alice.db.upsertChat(chat(e.key, e.key == chatA ? 'Cousins' : 'Book club'));
        for (final m in e.value) {
          await alice.db.insertMessageIfAbsent(m);
        }
      }
    });
    return ProviderScope.containerOf(tester.element(find.byType(FamChatApp))).read(routerProvider);
  }

  test('gallery groups: this week, earlier this month, then months', () {
    final n = DateTime(2026, 11, 22);
    expect(galleryGroup(DateTime(2026, 11, 20), n), 'This week');
    expect(galleryGroup(DateTime(2026, 11, 3), n), 'Earlier this month');
    expect(galleryGroup(DateTime(2026, 10, 3), n), 'October');
    expect(galleryGroup(DateTime(2025, 10, 3), n), 'October 2025');
  });

  chatTestWidgets('media: photos newest first under date headers; deleted ones left out', (tester) async {
    final router = await start(tester, {
      chatA: [
        row(chatA, 'p1', 1, bob.userId, photo(), at: DateTime(now.year - 1, 3, 4)),
        row(chatA, 'p2', 2, bob.userId, photo()),
        row(chatA, 'p3', 3, alice.userId, photo()),
        row(chatA, 'd3', 4, alice.userId, const DeleteBody('p3')),
        row(chatA, 't1', 5, bob.userId, const TextBody('hi')),
      ],
    });
    router.go('/chats/$chatA/media');
    await settle(tester);
    expect(find.byKey(const Key('gallery-p2')), findsOneWidget);
    expect(find.byKey(const Key('gallery-p1')), findsOneWidget);
    expect(find.byKey(const Key('gallery-p3')), findsNothing);
    expect(find.text('THIS WEEK'), findsOneWidget);
    expect(find.text('MARCH ${now.year - 1}'), findsOneWidget);
    expect(tester.getTopLeft(find.byKey(const Key('gallery-p2'))).dy,
        lessThan(tester.getTopLeft(find.byKey(const Key('gallery-p1'))).dy));
  });

  chatTestWidgets('links: texts and captions with a link', (tester) async {
    final router = await start(tester, {
      chatA: [
        row(chatA, 't1', 1, bob.userId, const TextBody('menu at https://pizza.example/menu tonight')),
        row(chatA, 't2', 2, bob.userId, const TextBody('no link here')),
      ],
    });
    router.go('/chats/$chatA/media');
    await settle(tester);
    await tester.tap(find.byKey(const Key('links-tab')));
    await settle(tester);
    expect(find.byKey(const Key('link-t1')), findsOneWidget);
    expect(find.text('https://pizza.example/menu'), findsOneWidget);
    expect(find.byKey(const Key('link-t2')), findsNothing);
  });

  chatTestWidgets("starred: this chat's in its tab, every chat's in settings; tapping opens the message", (tester) async {
    final router = await start(tester, {
      chatA: [row(chatA, 'a1', 1, bob.userId, const TextBody('gate code 4471')), row(chatA, 'a2', 2, bob.userId, const TextBody('ok'))],
      chatB: [row(chatB, 'b1', 1, bob.userId, const TextBody('chapter 3 by Friday'))],
    });
    await inApp(tester, () async {
      await alice.db.setStar(chatA, 'a1', starred: true, at: 1, pending: false);
      await alice.db.setStar(chatB, 'b1', starred: true, at: 2, pending: false);
    });
    router.go('/chats/$chatA/media');
    await settle(tester);
    await tester.tap(find.byKey(const Key('starred-tab')));
    await settle(tester);
    expect(find.byKey(const Key('starred-a1')), findsOneWidget);
    expect(find.byKey(const Key('starred-b1')), findsNothing);

    router.go('/settings/starred');
    await settle(tester);
    expect(find.byKey(const Key('starred-a1')), findsOneWidget);
    expect(find.byKey(const Key('starred-b1')), findsOneWidget);
    expect(find.textContaining('Book club'), findsOneWidget);
    expect(tester.getTopLeft(find.byKey(const Key('starred-b1'))).dy,
        lessThan(tester.getTopLeft(find.byKey(const Key('starred-a1'))).dy), reason: 'newest star first');
    await tester.tap(find.byKey(const Key('starred-b1')));
    await settle(tester);
    expect(router.state.uri.toString(), '/chats/$chatB?m=b1');
  });
}
