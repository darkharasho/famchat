// Sending staged photos and videos with the message typed alongside (the caption).
import 'dart:convert';
import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';
import 'package:famchat/chat/chat_sync.dart';
import 'package:famchat/chat/db/chat_db.dart';
import 'package:famchat/chat/message_changes.dart';
import 'package:famchat/media/media_db.dart';
import 'package:famchat/media/media_service.dart';
import 'package:famchat/media/photo_picker.dart';
import 'package:famchat/media/send_media.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_chat_backend.dart';
import '../support/fake_media.dart';

/// Bytes [FakeProcessor] refuses to decode.
final badImage = Uint8List.fromList([0xff, 0x00, 1, 2]);

void main() {
  late FakeChatBackend backend;
  late TestDevice alice;
  late ChatSync sync;
  late MediaDb mediaDb;
  late MediaService media;
  late String chatId;

  setUp(() async {
    backend = FakeChatBackend();
    alice = await backend.addUser('Alice');
    final bob = await backend.addUser('Bob');
    sync = ChatSync(db: alice.db, api: alice.api, hub: alice.hub, me: alice.me);
    mediaDb = memoryMediaDb();
    media = MediaService(db: mediaDb, api: alice.media, sync: sync, processor: FakeProcessor());
    await sync.start();
    await media.start();
    chatId = await sync.openDirect(bob.userId);
    await sync.idle;
  });

  tearDown(() async {
    await media.stop();
    await sync.stop();
    await mediaDb.close();
    await alice.dispose();
  });

  Future<List<MessageRow>> rows() async => (await alice.db.watchMessages(chatId).first)
      .where((r) => !timelineHiddenKinds.contains(r.kind))
      .toList();
  Map<String, Object?> json(MessageRow r) => jsonDecode(r.body!) as Map<String, Object?>;

  test('the caption, reply and mentions go on the last item only', () async {
    final report = await sendMedia(
      media,
      FakeVideoProcessor(),
      chatId,
      [PickedPhoto(photoBytes(100)), PickedVideo(XFile.fromData(photoBytes(200), path: '/v/a.mp4'))],
      caption: '  beach @Bob  ',
      replyTo: 'r1',
      mentions: ['bob'],
    );
    expect(report.problem, isNull);
    final sent = await rows();
    expect(sent.map((r) => r.kind), ['photo', 'video']);
    expect(json(sent[0]).keys, isNot(contains('caption')));
    expect(json(sent[1]), containsPair('caption', 'beach @Bob'));
    expect(json(sent[1]), containsPair('replyTo', 'r1'));
    expect(json(sent[1])['mentions'], ['bob']);
    expect(report.captionSentAsText, isFalse);
  });

  test('a blank caption sends the media alone', () async {
    await sendMedia(media, FakeVideoProcessor(), chatId, [PickedPhoto(photoBytes(100))], caption: '   ');
    final sent = await rows();
    expect(sent.single.kind, 'photo');
    expect(json(sent.single).keys, isNot(contains('caption')));
  });

  test('when the last item fails, the caption goes out as a text with its reply and mentions', () async {
    final report = await sendMedia(
      media,
      FakeVideoProcessor(),
      chatId,
      [PickedPhoto(photoBytes(100)), PickedPhoto(badImage)],
      caption: 'look @Bob',
      replyTo: 'r1',
      mentions: ['bob'],
    );
    expect(report.badImages, 1);
    expect(report.captionSentAsText, isTrue);
    final sent = await rows();
    expect(sent.map((r) => r.kind), ['photo', 'text']);
    expect(json(sent[1]), allOf(containsPair('text', 'look @Bob'), containsPair('replyTo', 'r1')));
    expect(json(sent[1])['mentions'], ['bob']);
  });

  test('when everything fails, the caption still goes out as a text', () async {
    final report = await sendMedia(
      media,
      FakeVideoProcessor(),
      chatId,
      [PickedVideo(XFile.fromData(photoBytes(10), path: '/v/x.bad'))],
      caption: 'sorry',
    );
    expect(report.badVideos, 1);
    expect((await rows()).map((r) => r.kind), ['text']);
  });

  test('items sent together share an album id; one alone has none', () async {
    await sendMedia(media, FakeVideoProcessor(), chatId,
        [PickedPhoto(photoBytes(100)), PickedVideo(XFile.fromData(photoBytes(200), path: '/v/a.mp4'))]);
    await sendMedia(media, FakeVideoProcessor(), chatId, [PickedPhoto(photoBytes(50))]);
    final sent = await rows();
    final album = json(sent[0])['album'];
    expect(album, isA<String>());
    expect(json(sent[1])['album'], album);
    expect(json(sent[2]).keys, isNot(contains('album')));
  });
}
