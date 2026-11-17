import 'dart:convert';
import 'dart:typed_data';

import 'package:famchat/chat/chat_sync.dart';
import 'package:famchat/chat/plaintext.dart';
import 'package:famchat/chat/wire.dart';
import 'package:famchat/main.dart';
import 'package:famchat/router.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:material_ui/material_ui.dart';

import '../support/chat_harness.dart';
import '../support/fake_chat_backend.dart';

final png = Uint8List.fromList(img.encodePng(img.Image(width: 16, height: 9)));

void main() {
  late FakeChatBackend backend;
  late TestDevice alice, bob;

  setUp(() async {
    backend = FakeChatBackend();
    alice = await backend.addUser('Alice');
    bob = await backend.addUser('Bob');
    backend.previews['https://youtu.be/cat'] =
        FetchedPreview(url: 'https://youtu.be/cat', title: 'Cat jumps', description: 'Cats Inc', siteName: 'YouTube', image: png);
  });

  Future<String> open(WidgetTester tester) async {
    setWindow(tester, const Size(400, 800));
    await pumpChatApp(tester, alice);
    final chatId = await inApp(tester, () => ChatSync(db: alice.db, api: alice.api, hub: alice.hub, me: alice.me).openDirect(bob.userId));
    ProviderScope.containerOf(tester.element(find.byType(FamChatApp))).read(routerProvider).go('/chats/$chatId');
    await settle(tester);
    return chatId;
  }

  Future<void> type(WidgetTester tester, String text) async {
    await tester.enterText(find.byKey(const Key('composer')), text);
    await tester.pump(const Duration(milliseconds: 700)); // the preview waits for typing to pause
    await settle(tester);
  }

  chatTestWidgets('typing a link shows its preview; sending carries it; the bubble shows the card', (tester) async {
    await open(tester);
    await type(tester, 'look https://youtu.be/cat');
    expect(find.byKey(const Key('composer-preview')), findsOneWidget);
    expect(find.text('Cat jumps'), findsOneWidget);
    await tester.tap(find.byTooltip('Send'));
    await settle(tester);
    final sent = (await inApp(tester, () => alice.db.pendingOutbox(alice.deviceId))).single;
    final body = Plaintext.decode(utf8.encode(sent.body!)) as TextBody;
    expect((body.preview!.title, body.preview!.siteName), ('Cat jumps', 'YouTube'));
    expect(body.preview!.image, isNotNull);
    expect(find.byKey(const Key('composer-preview')), findsNothing);
    expect(find.byKey(Key('link-preview-${sent.id}')), findsOneWidget);
    expect(find.text('YouTube'), findsOneWidget);
  });

  chatTestWidgets('a removed preview stays off; links without one send plain', (tester) async {
    await open(tester);
    await type(tester, 'https://youtu.be/cat');
    await tester.tap(find.byTooltip('Remove preview'));
    await tester.pump();
    await type(tester, 'https://youtu.be/cat !');
    expect(find.byKey(const Key('composer-preview')), findsNothing);
    await tester.tap(find.byTooltip('Send'));
    await settle(tester);
    await type(tester, 'https://unknown.example/');
    expect(find.byKey(const Key('composer-preview')), findsNothing);
    await tester.tap(find.byTooltip('Send'));
    await settle(tester);
    final sent = await inApp(tester, () => alice.db.pendingOutbox(alice.deviceId));
    expect(sent.map((r) => (Plaintext.decode(utf8.encode(r.body!)) as TextBody).preview), [null, null]);
  });

  chatTestWidgets('hovering a preview card shows the link cursor', (tester) async {
    await open(tester);
    await type(tester, 'look https://youtu.be/cat');
    await tester.tap(find.byTooltip('Send'));
    await settle(tester);
    final sent = (await inApp(tester, () => alice.db.pendingOutbox(alice.deviceId))).single;
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.byKey(Key('link-preview-${sent.id}'))));
    await tester.pump();
    expect(RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1), SystemMouseCursors.click);
  });

  chatTestWidgets('sending right after pasting a link waits for its preview', (tester) async {
    await open(tester);
    await tester.enterText(find.byKey(const Key('composer')), 'look https://youtu.be/cat');
    await tester.pump(); // no pause: the preview hasn't been asked for yet
    await tester.tap(find.byTooltip('Send'));
    await settle(tester);
    final sent = (await inApp(tester, () => alice.db.pendingOutbox(alice.deviceId))).single;
    expect((Plaintext.decode(utf8.encode(sent.body!)) as TextBody).preview?.title, 'Cat jumps');
  });
}
