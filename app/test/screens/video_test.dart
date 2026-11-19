import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';
import 'package:famchat/chat/chat_sync.dart';
import 'package:famchat/chat/db/chat_db.dart';
import 'package:famchat/chat/plaintext.dart';
import 'package:famchat/chat/ulid.dart';
import 'package:famchat/crypto/media.dart';
import 'package:famchat/main.dart';
import 'package:famchat/media/photo_picker.dart';
import 'package:famchat/media/providers.dart';
import 'package:famchat/router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:material_ui/material_ui.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import '../support/chat_harness.dart';
import '../support/fake_chat_backend.dart';
import '../support/fake_media.dart';
import '../support/fake_video.dart';

final png = Uint8List.fromList(img.encodePng(img.Image(width: 8, height: 6)));

void main() {
  late FakeChatBackend backend;
  late TestDevice alice, bob;
  late FakeVideoPlatform platform;

  setUp(() async {
    backend = FakeChatBackend();
    alice = await backend.addUser('Alice');
    bob = await backend.addUser('Bob');
    platform = FakeVideoPlatform();
    VideoPlayerPlatform.instance = platform;
  });

  Future<String> open(WidgetTester tester, {List<PickedMedia> picks = const [], List<Uri>? released}) async {
    setWindow(tester, const Size(400, 800));
    await pumpChatApp(tester, alice, picker: (source) async => picks, videoFiles: fakeVideoFiles(released: released));
    final chatId = await inApp(tester, () => ChatSync(db: alice.db, api: alice.api, hub: alice.hub, me: alice.me).openDirect(bob.userId));
    ProviderScope.containerOf(tester.element(find.byType(FamChatApp))).read(routerProvider).go('/chats/$chatId');
    await settle(tester);
    return chatId;
  }

  /// Bob's video: blobs on the server, the message in Alice's database.
  Future<(VideoBody, String)> bobsVideo(WidgetTester tester, String chatId, Uint8List file, {Uint8List? poster}) =>
      inApp(tester, () async {
        final key = newMediaKey();
        final fileBlob = await encryptMedia(key: key, plaintext: file, purpose: MediaPurpose.file);
        final thumbBlob = poster == null ? null : await encryptMedia(key: key, plaintext: poster, purpose: MediaPurpose.thumb);
        final body = VideoBody(
          mediaKey: newUlid(),
          key: key,
          sha256: await sha256Of(fileBlob),
          thumbKey: poster == null ? null : newUlid(),
          thumbSha256: thumbBlob == null ? null : await sha256Of(thumbBlob),
          width: 1280,
          height: 720,
          durationMs: 75000,
          bytes: file.length,
        );
        await bob.media.upload(key: body.mediaKey, chatId: chatId, kind: 'video', bytes: fileBlob);
        if (thumbBlob != null) await bob.media.upload(key: body.thumbKey!, chatId: chatId, kind: 'thumb', bytes: thumbBlob);
        final id = newUlid();
        await alice.db.insertMessageIfAbsent(MessageRow(
          id: id,
          chatId: chatId,
          seq: 1,
          senderUserId: bob.userId,
          senderDeviceId: bob.deviceId,
          kind: 'video',
          body: jsonEncode(body.toJson()),
          targetId: null,
          envelope: null,
          createdAt: DateTime.now().millisecondsSinceEpoch,
          state: 'sent',
        ));
        return (body, id);
      });

  chatTestWidgets('a picked video is processed and sent as a video message', (tester) async {
    final chatId = await open(tester, picks: [PickedVideo(XFile.fromData(photoBytes(3000), path: '/videos/clip.mp4'))]);
    await tester.tap(find.byTooltip('Attach'));
    await settle(tester);
    await tester.tap(find.text('Photos and videos'));
    await settle(tester);
    final sent = (await inApp(tester, () => alice.db.pendingOutbox(alice.deviceId))).single;
    expect(sent.kind, 'video');
    final body = Plaintext.decode(utf8.encode(sent.body!)) as VideoBody;
    expect((body.width, body.height, body.durationMs, body.bytes), (1280, 720, 12000, 3000));
    expect(body.thumbKey, isNotNull);
    expect(find.byKey(Key('video-${sent.id}')), findsOneWidget);
    expect(find.text('0:12'), findsOneWidget);
    expect(sent.chatId, chatId);
  });

  chatTestWidgets('a video too large to send says so; others in the pick still go', (tester) async {
    await open(tester, picks: [
      PickedVideo(XFile.fromData(photoBytes(10), path: '/videos/long.huge')),
      PickedVideo(XFile.fromData(photoBytes(500), path: '/videos/short.mp4')),
    ]);
    await tester.tap(find.byTooltip('Attach'));
    await settle(tester);
    await tester.tap(find.text('Photos and videos'));
    await settle(tester);
    expect(find.text('That video is too large to send (64 MB max).'), findsOneWidget);
    expect((await inApp(tester, () => alice.db.pendingOutbox(alice.deviceId))).single.kind, 'video');
  });

  chatTestWidgets("Bob's video shows its poster and length; tapping plays it full screen", (tester) async {
    final released = <Uri>[];
    final chatId = await open(tester, released: released);
    final file = photoBytes(2000, 3);
    final (_, id) = await bobsVideo(tester, chatId, file, poster: png);
    await settle(tester);
    expect(find.byKey(const Key('video-poster')), findsOneWidget);
    expect(find.text('1:15'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('Video, 1:15')), findsOneWidget);

    await tester.tap(find.byKey(Key('video-$id')));
    await settle(tester);
    expect(find.byKey(const Key('video-player')), findsOneWidget);
    expect(platform.created.single, startsWith('https://video.test/$id-'));
    expect(platform.played, isNotEmpty);

    await tester.tap(find.byTooltip('Close'));
    await settle(tester);
    expect(find.byKey(const Key('video-player')), findsNothing);
    // The player lets go in the background after the viewer closes.
    for (var i = 0; i < 20 && platform.disposed.isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump();
    }
    expect(platform.disposed, isNotEmpty);
    expect(released.map((u) => '$u'), [platform.created.single]);
  });

  chatTestWidgets('a video without a poster still shows a tile with its length', (tester) async {
    final chatId = await open(tester);
    await bobsVideo(tester, chatId, photoBytes(100));
    await settle(tester);
    expect(find.byKey(const Key('video-poster')), findsNothing);
    expect(find.text('1:15'), findsOneWidget);
  });

  chatTestWidgets('closing while the video is still being written leaves no decrypted file behind', (tester) async {
    final released = <Uri>[], written = <Uri>[];
    final gate = Completer<void>();
    setWindow(tester, const Size(400, 800));
    await pumpChatApp(tester, alice,
        videoFiles: VideoFiles(
          playable: (id, bytes) async {
            await gate.future;
            final uri = Uri.parse('https://video.test/$id.mp4');
            written.add(uri);
            return uri;
          },
          release: (uri) async => released.add(uri),
          controllerFor: VideoPlayerController.networkUrl,
        ));
    final chatId = await inApp(tester, () => ChatSync(db: alice.db, api: alice.api, hub: alice.hub, me: alice.me).openDirect(bob.userId));
    ProviderScope.containerOf(tester.element(find.byType(FamChatApp))).read(routerProvider).go('/chats/$chatId');
    await settle(tester);
    final (_, id) = await bobsVideo(tester, chatId, photoBytes(100));
    await settle(tester);
    await tester.tap(find.byKey(Key('video-$id')));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50)); // the spinner never settles while it loads
    }
    await tester.tap(find.byTooltip('Close'));
    await settle(tester);
    gate.complete();
    await settle(tester);
    expect(written, hasLength(1));
    expect(released, written);
    expect(platform.created, isEmpty, reason: 'no player for a closed viewer');
  });

  chatTestWidgets('two viewers of one video never share a file', (tester) async {
    final chatId = await open(tester);
    final (_, id) = await bobsVideo(tester, chatId, photoBytes(100));
    await settle(tester);
    for (var i = 0; i < 2; i++) {
      await tester.tap(find.byKey(Key('video-$id')));
      await settle(tester);
      await tester.tap(find.byTooltip('Close'));
      await settle(tester);
    }
    expect(platform.created.toSet(), hasLength(2));
  });
}
