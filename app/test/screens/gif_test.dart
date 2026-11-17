import 'dart:convert';

import 'package:famchat/chat/db/chat_db.dart';
import 'package:famchat/gifs/gif_picker.dart';
import 'package:famchat/gifs/klipy.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:famchat/chat/wire.dart';
import 'package:famchat/main.dart';
import 'package:famchat/router.dart';
import 'package:drift/drift.dart' show Value;
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

  chatTestWidgets('no GIF button without a KLIPY key', (tester) async {
    await open(tester);
    expect(find.byTooltip('GIF'), findsNothing);
  });

  chatTestWidgets('picking a GIF sends it and tells KLIPY it was shared', (tester) async {
    final shared = <String>[];
    await open(tester, gifs: fakeKlipy(shared));
    await tester.tap(find.byTooltip('GIF'));
    await settle(tester);
    expect(find.text('Search KLIPY'), findsOneWidget);
    expect(find.text('Powered by KLIPY'), findsOneWidget);
    await tester.tap(find.byKey(const Key('gif-party-1')));
    await settle(tester);
    final p = (await inApp(tester, () => alice.db.pendingOutbox(alice.deviceId))).single;
    expect(p.kind, 'gif');
    expect((jsonDecode(p.body!) as Map)['url'], 'https://static.klipy.com/x/party-md.webp');
    expect(shared, ['party-1']);
    expect(tester.widget<GifView>(find.byType(GifView)).body.title, 'Party time');
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
