import 'dart:async';
import 'dart:convert';

import 'package:famchat/media/photo_picker.dart';
import 'package:famchat/chat/chat_sync.dart';
import 'package:famchat/chat/db/chat_db.dart';
import 'package:famchat/chat/plaintext.dart';
import 'package:famchat/chat/ulid.dart';
import 'package:famchat/crypto/media.dart';
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

  void go(WidgetTester tester, String path) =>
      ProviderScope.containerOf(tester.element(find.byType(FamChatApp))).read(routerProvider).go(path);

  /// Pumps Alice's app with a direct chat to Bob that exists on the server, and opens it.
  Future<(ScriptedHubLink, String)> open(WidgetTester tester, {List<Uint8List> picks = const []}) async {
    setWindow(tester, const Size(400, 800));
    final hub = await pumpChatApp(tester, alice, picker: (source) async => [for (final p in picks) PickedPhoto(p)]);
    final chatId = await inApp(tester, () => ChatSync(db: alice.db, api: alice.api, hub: alice.hub, me: alice.me).openDirect(bob.userId));
    go(tester, '/chats/$chatId');
    await settle(tester);
    return (hub, chatId);
  }

  /// Bob's photo: blobs on the server, the message in Alice's database.
  Future<PhotoBody> bobsPhoto(WidgetTester tester, String chatId, {Uint8List? full, bool tamperThumb = false}) =>
      inApp(tester, () async {
        final key = newMediaKey();
        final thumbBlob = await encryptMedia(key: key, plaintext: png, purpose: MediaPurpose.thumb);
        final fullBlob = await encryptMedia(key: key, plaintext: full ?? png, purpose: MediaPurpose.file);
        final body = PhotoBody(
          mediaKey: newUlid(),
          thumbKey: newUlid(),
          key: key,
          sha256: await sha256Of(fullBlob),
          thumbSha256: await sha256Of(thumbBlob),
          width: 8,
          height: 6,
          bytes: (full ?? png).length,
        );
        await bob.media.upload(key: body.thumbKey, chatId: chatId, kind: 'thumb', bytes: thumbBlob);
        await bob.media.upload(key: body.mediaKey, chatId: chatId, kind: 'photo', bytes: fullBlob);
        if (tamperThumb) backend.tamperMedia(body.thumbKey, Uint8List(64));
        await alice.db.insertMessageIfAbsent(MessageRow(
          id: newUlid(),
          chatId: chatId,
          seq: 1,
          senderUserId: bob.userId,
          senderDeviceId: bob.deviceId,
          kind: 'photo',
          body: jsonEncode(body.toJson()),
          targetId: null,
          envelope: null,
          createdAt: DateTime.now().millisecondsSinceEpoch,
          state: 'sent',
        ));
        return body;
      });

  chatTestWidgets('own photo shows its thumbnail and upload progress', (tester) async {
    final (hub, _) = await open(tester, picks: [png]);
    alice.media.hold = Completer<void>();
    hub.setConnected(true);
    await settle(tester);
    await tester.tap(find.byTooltip('Attach'));
    await settle(tester);
    if (find.text('Photos and videos').evaluate().isNotEmpty) {
      await tester.tap(find.text('Photos and videos'));
      await settle(tester);
    }
    expect(find.byKey(const Key('photo-thumb')), findsNothing, reason: 'waiting in the tray');
    await tester.tap(find.byTooltip('Send'));
    await settle(tester);
    expect(find.byKey(const Key('photo-thumb')), findsOneWidget);
    expect(find.byKey(const Key('upload-progress')), findsOneWidget);
    expect(find.byKey(const Key('pending-icon')), findsOneWidget);
    expect(hub.sent.where((f) => f['type'] == 'send'), isEmpty);
    alice.media.hold!.complete();
    alice.media.hold = null;
    await settle(tester);
    expect(find.byKey(const Key('upload-progress')), findsNothing);
    expect(hub.sent.where((f) => f['type'] == 'send'), hasLength(1));
    final sentId = hub.sent.firstWhere((f) => f['type'] == 'send')['id'] as String;
    final row = (await inApp(tester, () => alice.db.messageById(sentId)))!;
    expect(row.kind, 'photo');
  });

  chatTestWidgets('incoming photo thumbnail opens the viewer with the full image', (tester) async {
    final (_, chatId) = await open(tester);
    await bobsPhoto(tester, chatId);
    await settle(tester);
    expect(find.byKey(const Key('photo-thumb')), findsOneWidget);
    await tester.tap(find.byKey(const Key('photo-thumb')));
    await settle(tester);
    expect(find.byKey(const Key('photo-full')), findsOneWidget);
    // The photo gets the whole window, not the close button's corner.
    expect(tester.getSize(find.byType(InteractiveViewer)), const Size(400, 800));
    await tester.tap(find.byTooltip('Close'));
    await settle(tester);
    expect(find.byKey(const Key('photo-full')), findsNothing);
    expect(find.byKey(const Key('photo-thumb')), findsOneWidget);
  });

  chatTestWidgets('on desktop the viewer has a zoom bar; keys and double-tap zoom too', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      final (_, chatId) = await open(tester);
      await bobsPhoto(tester, chatId);
      await settle(tester);
      await tester.tap(find.byKey(const Key('photo-thumb')));
      await settle(tester);
      String percent() => tester.widget<Text>(find.byKey(const Key('photo-zoom-percent'))).data!;
      Matrix4 matrix() => tester.widget<InteractiveViewer>(find.byKey(const Key('photo-zoom'))).transformationController!.value;
      expect(percent(), '100%');
      await tester.tap(find.byTooltip('Zoom in'));
      await tester.pump();
      expect(percent(), '150%');
      // Zooming keeps the middle in place and the photo over the whole window.
      expect(matrix().getTranslation().x, closeTo(-200 * 0.5, 0.01));
      await tester.tap(find.byTooltip('Fit to screen'));
      await tester.pump();
      expect(percent(), '100%');
      await tester.sendKeyEvent(LogicalKeyboardKey.equal);
      await tester.sendKeyEvent(LogicalKeyboardKey.equal);
      await tester.pump();
      expect(percent(), '225%');
      await tester.sendKeyEvent(LogicalKeyboardKey.digit0);
      await tester.pump();
      expect(percent(), '100%');
      // Double-tap zooms in where tapped: at the left edge, the left edge stays put.
      final at = tester.getTopLeft(find.byKey(const Key('photo-zoom'))) + const Offset(0, 300);
      await tester.tapAt(at);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(at);
      await settle(tester);
      expect(percent(), '250%');
      expect(matrix().getTranslation().x, 0);
      // The slider's far end is the most zoom.
      await tester.drag(find.byKey(const Key('photo-zoom-slider')), const Offset(400, 0));
      await tester.pump();
      expect(percent(), '800%');
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  chatTestWidgets('phones have no zoom bar (they pinch)', (tester) async {
    final (_, chatId) = await open(tester);
    await bobsPhoto(tester, chatId);
    await settle(tester);
    await tester.tap(find.byKey(const Key('photo-thumb')));
    await settle(tester);
    expect(find.byKey(const Key('photo-full')), findsOneWidget);
    expect(find.byKey(const Key('photo-zoom-bar')), findsNothing);
  });

  chatTestWidgets('expired photo shows Photo expired', (tester) async {
    final (_, chatId) = await open(tester);
    await inApp(tester, () async {}); // let the open settle
    final body = await bobsPhoto(tester, chatId);
    backend.expireMedia([body.mediaKey, body.thumbKey]); // Alice's hub is scripted: she learns via 410
    await settle(tester);
    expect(find.byKey(const Key('media-expired')), findsOneWidget);
    expect(find.text('Photo expired'), findsOneWidget);
    await tester.tap(find.byKey(const Key('media-expired')));
    await settle(tester);
    expect(find.byKey(const Key('photo-full')), findsNothing);
  });

  chatTestWidgets('a photo that fails verification offers a retry', (tester) async {
    final (_, chatId) = await open(tester);
    final body = await bobsPhoto(tester, chatId, tamperThumb: true);
    await settle(tester);
    expect(find.byKey(const Key('photo-error')), findsOneWidget);
    expect(find.byKey(const Key('photo-thumb')), findsNothing);
    // The server serves the right blob again: tapping retries.
    final good = await inApp(tester, () => encryptMedia(key: body.key, plaintext: png, purpose: MediaPurpose.thumb));
    backend.tamperMedia(body.thumbKey, good);
    await tester.tap(find.byKey(const Key('photo-error')));
    await settle(tester);
    // A fresh encryption has a different hash than the message pins: still refused.
    expect(find.byKey(const Key('photo-error')), findsOneWidget);
    expect(alice.media.downloads.where((k) => k == body.thumbKey), hasLength(2));
  });

  chatTestWidgets('chat list previews a photo', (tester) async {
    final (_, chatId) = await open(tester);
    await bobsPhoto(tester, chatId);
    go(tester, '/');
    await settle(tester);
    expect(find.text('📷 Photo'), findsOneWidget);
  });

  chatTestWidgets('admin opens Storage and sees usage', (tester) async {
    setWindow(tester, const Size(400, 800));
    await pumpChatApp(tester, alice, admin: true);
    await inApp(tester, () async {
      final chatId = await ChatSync(db: alice.db, api: alice.api, hub: alice.hub, me: alice.me).openDirect(bob.userId);
      await alice.media.upload(key: newUlid(), chatId: chatId, kind: 'photo', bytes: Uint8List(3 * 1024 * 1024));
    });
    await tester.tap(find.byTooltip('Settings'));
    await settle(tester);
    await tester.tap(find.byKey(const Key('settings-families')));
    await settle(tester);
    await tester.tap(find.byKey(const Key('family-tile-1')));
    await settle(tester);
    await tester.ensureVisible(find.text('Media storage'));
    await settle(tester);
    await tester.tap(find.text('Media storage'));
    await settle(tester);
    expect(find.text('Media storage'), findsOneWidget);
    expect(find.text('3.0 MB of 8.0 GB used'), findsOneWidget);
    expect(find.text('1 file stored'), findsOneWidget);
    expect(find.byKey(const Key('storage-meter')), findsOneWidget);
  });

  chatTestWidgets("members don't see Storage", (tester) async {
    setWindow(tester, const Size(400, 800));
    await pumpChatApp(tester, alice);
    await tester.tap(find.byTooltip('Settings'));
    await settle(tester);
    await tester.tap(find.byKey(const Key('settings-families')));
    await settle(tester);
    expect(find.text('Media storage'), findsNothing);
    go(tester, '/settings/storage');
    await settle(tester);
    expect(find.text('Media storage'), findsNothing);
  });
}
