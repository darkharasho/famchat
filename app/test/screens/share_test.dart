import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';
import 'package:famchat/chat/chat_sync.dart';
import 'package:famchat/chat/plaintext.dart';
import 'package:famchat/media/photo_picker.dart';
import 'package:famchat/media/send_media.dart';
import 'package:famchat/share/share.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:material_ui/material_ui.dart';

import '../support/chat_harness.dart';
import '../support/fake_chat_backend.dart';

final png = Uint8List.fromList(img.encodePng(img.Image(width: 8, height: 6)));

class FakeShareSource implements ShareSource {
  IncomingShare? first;
  final _updates = StreamController<IncomingShare>.broadcast();
  var finished = 0;

  void share(IncomingShare s) => _updates.add(s);

  @override
  Future<IncomingShare?> initial() async => first;

  @override
  Stream<IncomingShare> get updates => _updates.stream;

  @override
  Future<void> done() async => finished++;
}

void main() {
  late FakeChatBackend backend;
  late TestDevice alice, bob;
  late FakeShareSource source;

  setUp(() async {
    backend = FakeChatBackend();
    alice = await backend.addUser('Alice');
    bob = await backend.addUser('Bob');
    source = FakeShareSource();
  });

  Future<String> start(WidgetTester tester) async {
    setWindow(tester, const Size(400, 800));
    await pumpChatApp(tester, alice, shares: source);
    final chatId = await inApp(tester, () => ChatSync(db: alice.db, api: alice.api, hub: alice.hub, me: alice.me).openDirect(bob.userId));
    await settle(tester);
    return chatId;
  }

  test('summaries and file sorting', () async {
    expect(shareSummary(IncomingShare(media: [PickedPhoto(png)])), 'a photo');
    expect(shareSummary(IncomingShare(media: [PickedPhoto(png), PickedPhoto(png), PickedVideo(XFile('/v.mp4'))])),
        '2 photos and a video');
    expect(shareSummary(const IncomingShare(text: 'https://x.io')), 'a message');
    expect(shareSummary(IncomingShare(media: [PickedVideo(XFile('/v.mp4'))], text: 'look')), 'a video and a message');
    final sorted = await pickedFromFiles([
      XFile.fromData(png, path: '/a.PNG'),
      XFile.fromData(png, path: '/b.mov'),
      XFile.fromData(png, path: '/c.pdf'),
    ]);
    expect(sorted.media.map((m) => m.runtimeType), [PickedPhoto, PickedVideo]);
    expect(sorted.skipped, 1);
  });

  chatTestWidgets('a photo shared from another app goes to the chat picked', (tester) async {
    final chatId = await start(tester);
    source.share(IncomingShare(media: [PickedPhoto(png)], text: 'from the beach'));
    await settle(tester);
    expect(find.text('Send to…'), findsOneWidget);
    expect(find.text('a photo and a message'), findsOneWidget);
    await tester.tap(find.byKey(Key('share-to-$chatId')));
    await settle(tester);
    final sent = (await inApp(tester, () => alice.db.pendingOutbox(alice.deviceId))).single;
    expect((sent.chatId, sent.kind), (chatId, 'photo'));
    expect(Plaintext.decode(utf8.encode(sent.body!)), isA<PhotoBody>());
    // The text waits in the composer, to edit before sending.
    expect(tester.widget<TextField>(find.byKey(const Key('composer'))).controller!.text, 'from the beach');
    expect(source.finished, 1);
  });

  chatTestWidgets('a share waiting at launch opens the picker; Cancel drops it', (tester) async {
    source.first = const IncomingShare(text: 'hello');
    await start(tester);
    await settle(tester);
    expect(find.text('Send to…'), findsOneWidget);
    await tester.tap(find.byTooltip('Cancel'));
    await settle(tester);
    expect(find.text('Send to…'), findsNothing);
    expect(source.finished, 1);
    expect(await inApp(tester, () => alice.db.pendingOutbox(alice.deviceId)), isEmpty);
  });
}
