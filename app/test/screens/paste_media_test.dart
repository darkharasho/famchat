import 'package:famchat/chat/chat_sync.dart';
import 'package:famchat/media/photo_picker.dart';
import 'package:famchat/main.dart';
import 'package:famchat/router.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:material_ui/material_ui.dart';

import '../support/chat_harness.dart';
import '../support/fake_chat_backend.dart';

final png = Uint8List.fromList(img.encodePng(img.Image(width: 8, height: 6)));

void main() {
  late FakeChatBackend backend;
  late TestDevice alice, bob;

  setUp(() async {
    backend = FakeChatBackend();
    alice = await backend.addUser('Alice');
    bob = await backend.addUser('Bob');
  });

  /// Opens Alice's chat with Bob, connected, with [clipboard] as what's on the clipboard.
  Future<ScriptedHubLink> open(WidgetTester tester, List<PickedMedia> Function() clipboard) async {
    setWindow(tester, const Size(400, 800));
    final hub = await pumpChatApp(tester, alice, clipboard: () async => clipboard());
    final chatId = await inApp(tester, () => ChatSync(db: alice.db, api: alice.api, hub: alice.hub, me: alice.me).openDirect(bob.userId));
    ProviderScope.containerOf(tester.element(find.byType(FamChatApp))).read(routerProvider).go('/chats/$chatId');
    await settle(tester);
    hub.setConnected(true);
    await tester.tap(find.byKey(const Key('composer')));
    await settle(tester);
    return hub;
  }

  Future<void> ctrlV(WidgetTester tester) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await settle(tester);
  }

  int sends(ScriptedHubLink hub) => hub.sent.where((f) => f['type'] == 'send').length;

  chatTestWidgets('pasting a photo asks first, then sends it', (tester) async {
    final hub = await open(tester, () => [PickedPhoto(png)]);
    await ctrlV(tester);
    expect(find.byKey(const Key('paste-confirm')), findsOneWidget);
    expect(find.text('Send this photo?'), findsOneWidget);
    expect(sends(hub), 0);
    await tester.tap(find.widgetWithText(FilledButton, 'Send'));
    await settle(tester);
    expect(find.byKey(const Key('photo-thumb')), findsOneWidget);
    expect(sends(hub), 1);
  });

  chatTestWidgets('cancelling a pasted photo sends nothing', (tester) async {
    final hub = await open(tester, () => [PickedPhoto(png), PickedPhoto(png)]);
    await ctrlV(tester);
    expect(find.text('Send 2 photos?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await settle(tester);
    expect(find.byKey(const Key('paste-confirm')), findsNothing);
    expect(find.byKey(const Key('photo-thumb')), findsNothing);
    expect(sends(hub), 0);
  });

  chatTestWidgets('with no photo on the clipboard, text pastes as usual', (tester) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') return {'text': 'hello there'};
      if (call.method == 'Clipboard.hasStrings') return {'value': true};
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    final hub = await open(tester, () => const []);
    await ctrlV(tester);
    expect(find.byKey(const Key('paste-confirm')), findsNothing);
    expect(tester.widget<TextField>(find.byKey(const Key('composer'))).controller!.text, 'hello there');
    expect(sends(hub), 0);
  });
}
