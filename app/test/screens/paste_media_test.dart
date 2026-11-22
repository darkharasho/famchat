import 'package:famchat/chat/chat_sync.dart';
import 'package:famchat/media/photo_picker.dart';
import 'package:famchat/main.dart';
import 'package:famchat/router.dart';
import 'package:flutter/foundation.dart';
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

  ProviderContainer c(WidgetTester tester) => ProviderScope.containerOf(tester.element(find.byType(FamChatApp)));

  Future<void> type(WidgetTester tester, String text) async {
    await tester.enterText(find.byKey(const Key('composer')), text);
    await settle(tester);
  }

  chatTestWidgets('a pasted photo waits in the tray, then goes with the message as its caption', (tester) async {
    final hub = await open(tester, () => [PickedPhoto(png), PickedPhoto(png)]);
    await ctrlV(tester);
    expect(find.byKey(const Key('staged-tray')), findsOneWidget);
    expect(find.text('2 items · your message goes with them'), findsOneWidget);
    expect(sends(hub), 0);
    await type(tester, 'beach day');
    await tester.tap(find.byTooltip('Send'));
    await settle(tester);
    expect(find.byKey(const Key('staged-tray')), findsNothing);
    expect(tester.widget<TextField>(find.byKey(const Key('composer'))).controller!.text, isEmpty);
    expect(find.byKey(const Key('photo-thumb')), findsNWidgets(2));
    expect(find.text('beach day'), findsOneWidget, reason: 'under the last photo');
    expect(sends(hub), 2);
    final ids = [for (final f in hub.sent.where((f) => f['type'] == 'send')) f['id'] as String];
    final photos = [for (final id in ids) (await inApp(tester, () => alice.db.messageById(id)))!];
    expect(photos.map((r) => r.kind), ['photo', 'photo']);
    expect(photos.first.body, isNot(contains('caption')));
    expect(photos.last.body, contains('"caption":"beach day"'));
  });

  chatTestWidgets('✕ takes a photo out of the tray; removing the last sends nothing', (tester) async {
    final hub = await open(tester, () => [PickedPhoto(png)]);
    await ctrlV(tester);
    expect(find.byKey(const Key('staged-tray')), findsOneWidget);
    await tester.tap(find.byKey(const Key('staged-remove-0')));
    await settle(tester);
    expect(find.byKey(const Key('staged-tray')), findsNothing);
    expect(find.byTooltip('Send'), findsNothing, reason: 'the mic is back');
    expect(sends(hub), 0);
  });

  chatTestWidgets('with nothing typed, Send (and Enter on a computer) sends the photos alone', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final hub = await open(tester, () => [PickedPhoto(png)]);
    await ctrlV(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settle(tester);
    expect(find.byKey(const Key('photo-thumb')), findsOneWidget);
    expect(sends(hub), 1);
    debugDefaultTargetPlatformOverride = null;
  });

  chatTestWidgets('staged photos stay when leaving the chat and coming back', (tester) async {
    await open(tester, () => [PickedPhoto(png)]);
    await ctrlV(tester);
    final chatId = c(tester).read(routerProvider).state.pathParameters['id'];
    c(tester).read(routerProvider).go('/');
    await settle(tester);
    c(tester).read(routerProvider).go('/chats/$chatId');
    await settle(tester);
    expect(find.byKey(const Key('staged-tray')), findsOneWidget);
  });

  chatTestWidgets('a caption can be edited like a text', (tester) async {
    final hub = await open(tester, () => [PickedPhoto(png)]);
    await ctrlV(tester);
    await type(tester, 'beach');
    await tester.tap(find.byTooltip('Send'));
    await settle(tester);
    await tester.longPress(find.text('beach'));
    await settle(tester);
    await tester.tap(find.text('Edit'));
    await settle(tester);
    await type(tester, 'beach day');
    await tester.tap(find.byTooltip('Save edit'));
    await settle(tester);
    expect(find.text('beach day'), findsOneWidget);
    expect(find.text('edited'), findsOneWidget);
    expect(sends(hub), 2);
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

  chatTestWidgets('photos sent together show as one album: 4 tiles, "+1", and the caption under it', (tester) async {
    await open(tester, () => [for (var i = 0; i < 5; i++) PickedPhoto(png)]);
    await ctrlV(tester);
    await type(tester, 'beach day');
    await tester.tap(find.byTooltip('Send'));
    await settle(tester);
    expect(find.byKey(const Key('album')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('album')), matching: find.byKey(const Key('photo-thumb'))), findsNWidgets(4));
    expect(find.text('+1'), findsOneWidget);
    expect(find.text('beach day'), findsOneWidget);
  });
}
