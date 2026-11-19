import 'dart:convert';

import 'package:emoji_picker_flutter/emoji_picker_flutter.dart' show EmojiPicker;
import 'package:famchat/chat/db/chat_db.dart';
import 'package:famchat/gifs/gif_picker.dart';
import 'package:famchat/gifs/klipy.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:famchat/chat/wire.dart';
import 'package:famchat/main.dart';
import 'package:famchat/router.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
    SharedPreferences.setMockInitialValues({}); // the emoji picker keeps recently used emoji there
    backend = FakeChatBackend();
    alice = await backend.addUser('Alice');
    bob = await backend.addUser('Bob');
  });

  Future<ScriptedHubLink> open(WidgetTester tester, {List<MessageRow> messages = const [], KlipyClient? gifs}) async {
    setWindow(tester, const Size(400, 800));
    final hub = await pumpChatApp(tester, alice, gifs: gifs);
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

  KlipyClient fakeKlipy(List<String> shared) => KlipyClient(
        appKey: 'K',
        customerId: 'c',
        http: MockClient((req) async {
          if (req.method == 'POST') {
            shared.add(req.url.pathSegments.last);
            return http.Response('{}', 200);
          }
          final f = {
            'md': {'webp': {'url': 'https://static.klipy.com/x/party-md.webp', 'width': 400, 'height': 300}},
            'sm': {'webp': {'url': 'https://static.klipy.com/x/party-sm.webp', 'width': 200, 'height': 150}},
          };
          return http.Response(
            jsonEncode({
              'result': true,
              'data': {
                'data': [
                  {'slug': 'party-1', 'title': 'Party time', 'file': f},
                ],
                'has_next': false,
              },
            }),
            200,
          );
        }),
      );

  chatTestWidgets('no GIFs tab without a KLIPY key', (tester) async {
    await open(tester);
    expect(find.byTooltip('GIF'), findsNothing);
    await tester.tap(find.byTooltip('Emoji'));
    await settle(tester);
    expect(find.byType(EmojiPicker), findsOneWidget);
    expect(find.text('GIFs'), findsNothing);
  });

  chatTestWidgets("on a phone, picking from the emoji picker's GIFs tab sends it and closes the picker", (tester) async {
    final shared = <String>[];
    await open(tester, gifs: fakeKlipy(shared));
    expect(find.byTooltip('GIF'), findsNothing, reason: 'GIFs moved into the emoji picker');
    await tester.tap(find.byTooltip('Emoji'));
    await settle(tester);
    expect(find.text('Emoji'), findsOneWidget);
    await tester.tap(find.text('GIFs'));
    await settle(tester);
    expect(find.byType(EmojiPicker), findsNothing);
    expect(find.text('Search KLIPY'), findsOneWidget);
    expect(find.text('Powered by KLIPY'), findsOneWidget);
    await tester.tap(find.byKey(const Key('gif-party-1')));
    await settle(tester);
    expect(find.text('Search KLIPY'), findsNothing, reason: 'the picker closes');
    final p = (await inApp(tester, () => alice.db.pendingOutbox(alice.deviceId))).single;
    expect(p.kind, 'gif');
    expect((jsonDecode(p.body!) as Map)['url'], 'https://static.klipy.com/x/party-md.webp');
    expect(shared, ['party-1']);
    expect(tester.widget<GifView>(find.byType(GifView)).body.title, 'Party time');

    // The tab is remembered: the picker opens on GIFs again.
    await tester.tap(find.byTooltip('Emoji'));
    await settle(tester);
    expect(find.text('Search KLIPY'), findsOneWidget);
    await tester.tap(find.text('Emoji'));
    await settle(tester);
    expect(find.byType(EmojiPicker), findsOneWidget);
  });

  chatTestWidgets("on desktop, the emoji popover's GIFs tab sends a GIF and closes", (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      final shared = <String>[];
      await open(tester, gifs: fakeKlipy(shared));
      await tester.tap(find.byTooltip('Emoji'));
      await settle(tester);
      final popover = find.byKey(const Key('emoji-popover'));
      await tester.tap(find.descendant(of: popover, matching: find.text('GIFs')));
      await settle(tester);
      expect(find.descendant(of: popover, matching: find.text('Search KLIPY')), findsOneWidget);
      await tester.tap(find.byKey(const Key('gif-party-1')));
      await settle(tester);
      expect(popover, findsNothing);
      expect((await inApp(tester, () => alice.db.pendingOutbox(alice.deviceId))).single.kind, 'gif');
      expect(shared, ['party-1']);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  chatTestWidgets('no GIFs tab while editing', (tester) async {
    await open(tester, gifs: fakeKlipy([]), messages: [row('m1', 1, alice.userId, 'see you at 5')]);
    await tester.longPress(find.text('see you at 5'));
    await settle(tester);
    await tester.tap(find.text('Edit'));
    await settle(tester);
    await tester.tap(find.byTooltip('Emoji'));
    await settle(tester);
    expect(find.byType(EmojiPicker), findsOneWidget);
    expect(find.text('GIFs'), findsNothing);
  });

  chatTestWidgets('a received GIF shows, and lists as GIF', (tester) async {
    await open(tester, messages: [
      row('g1', 1, bob.userId, '').copyWith(
        kind: 'gif',
        body: const Value('{"kind":"gif","slug":"s","title":"Wave","url":"https://static.klipy.com/a.webp","width":200,"height":200}'),
      ),
    ]);
    expect(tester.widget<GifView>(find.byType(GifView)).body.title, 'Wave');
  });
}
