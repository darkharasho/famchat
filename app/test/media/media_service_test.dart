import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:famchat/api/models.dart';
import 'package:famchat/chat/chat_sync.dart';
import 'package:famchat/chat/db/chat_db.dart';
import 'package:famchat/chat/forward.dart';
import 'package:famchat/chat/message_changes.dart';
import 'package:famchat/chat/plaintext.dart';
import 'package:famchat/chat/wire.dart';
import 'package:famchat/crypto/encoding.dart';
import 'package:famchat/crypto/media.dart';
import 'package:famchat/media/media_db.dart';
import 'package:famchat/media/media_service.dart';
import 'package:famchat/media/video.dart';
import 'package:famchat/voice/waveform.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_chat_backend.dart';
import '../support/fake_media.dart';

class Node {
  Node(this.d, {int cacheBytes = 1 << 20})
      : db = memoryMediaDb(),
        sync = ChatSync(db: d.db, api: d.api, hub: d.hub, me: d.me) {
    media = MediaService(
      db: db,
      api: d.media,
      sync: sync,
      processor: processor,
      cacheBytes: cacheBytes,
      retryDelays: const [Duration(milliseconds: 20)],
    );
  }
  final TestDevice d;
  final MediaDb db;
  final ChatSync sync;
  final processor = FakeProcessor();
  late final MediaService media;

  Future<List<MessageRow>> rows(String chatId) => d.db.watchMessages(chatId).first;
  Future<MessageRow?> row(String id) => d.db.messageById(id);
  Future<List<VoiceBody>> voices(String chatId) async => [
        for (final r in await rows(chatId))
          if (r.kind == 'voice') Plaintext.decode(utf8.encode(r.body!)) as VoiceBody,
      ];
  Future<List<VideoBody>> videos(String chatId) async => [
        for (final r in await rows(chatId))
          if (r.kind == 'video') Plaintext.decode(utf8.encode(r.body!)) as VideoBody,
      ];
  Future<List<FileBody>> files(String chatId) async => [
        for (final r in await rows(chatId))
          if (r.kind == 'file') Plaintext.decode(utf8.encode(r.body!)) as FileBody,
      ];
  Future<List<PhotoBody>> photos(String chatId) async => [
        for (final r in await rows(chatId))
          if (r.kind == 'photo') Plaintext.decode(utf8.encode(r.body!)) as PhotoBody,
      ];
}

Future<void> until(FutureOr<bool> Function() cond, {String? reason}) async {
  final sw = Stopwatch()..start();
  while (!await cond()) {
    if (sw.elapsed > const Duration(seconds: 5)) fail('timed out waiting${reason == null ? '' : ' for $reason'}');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  late FakeChatBackend backend;
  final nodes = <Node>[];

  Future<Node> start(TestDevice d, {int cacheBytes = 1 << 20}) async {
    final n = Node(d, cacheBytes: cacheBytes);
    nodes.add(n);
    await n.sync.start();
    await n.media.start();
    await n.sync.idle;
    return n;
  }

  setUp(() => backend = FakeChatBackend());
  tearDown(() async {
    for (final n in nodes) {
      await n.media.stop();
      await n.sync.stop();
      await n.db.close();
      await n.d.dispose();
    }
    nodes.clear();
  });

  Future<(Node, Node, String)> pair() async {
    final alice = await start(await backend.addUser('Alice'));
    final bob = await start(await backend.addUser('Bob'));
    final chatId = await alice.sync.openDirect(bob.d.userId);
    await alice.sync.idle;
    await bob.sync.idle;
    return (alice, bob, chatId);
  }

  Future<String> sentPhoto(Node n, String chatId, Uint8List bytes) async {
    final id = await n.media.sendPhoto(chatId, bytes);
    await until(() async => (await n.row(id))?.state == 'sent', reason: 'photo sent');
    return id;
  }

  test('photo goes from Alice to Bob and decrypts with a matching hash', () async {
    final (alice, bob, chatId) = await pair();
    final original = photoBytes(3000);
    final id = await sentPhoto(alice, chatId, original);
    await until(() async => (await bob.photos(chatId)).isNotEmpty, reason: 'bob gets the photo');
    final p = (await bob.photos(chatId)).single;
    expect((p.width, p.height, p.bytes, p.mime), (4, 3, 3000, 'image/jpeg'));
    expect((await bob.row(id))!.kind, 'photo');
    // The server only ever saw ciphertext.
    expect(backend.mediaBlob(p.mediaKey), isNot(contains(original.sublist(0, 32))));
    expect(await sha256Matches(backend.mediaBlob(p.mediaKey)!, p.sha256), isTrue);
    expect(await bob.media.load(p.fullRef), original);
    expect(await bob.media.load(p.thumbRef), original.sublist(0, 16));
    // Cached: a second load doesn't download again.
    await bob.media.load(p.fullRef);
    expect(bob.d.media.downloads, [p.mediaKey, p.thumbKey]);
    // The sender shows it from its own cache without downloading.
    expect(await alice.media.load(p.fullRef), original);
    expect(alice.d.media.downloads, isEmpty);
  });

  group('video', () {
    ProcessedVideo clip({bool thumb = true, int n = 5000}) => ProcessedVideo(
          bytes: photoBytes(n, 5),
          thumb: thumb ? photoBytes(40, 9) : null,
          width: 1280,
          height: 720,
          duration: const Duration(seconds: 12),
        );

    test('a video and its poster frame go to Bob encrypted, sent after both upload', () async {
      final (alice, bob, chatId) = await pair();
      final v = clip();
      final id = await alice.media.sendVideo(chatId, v);
      await until(() async => (await alice.row(id))?.state == 'sent', reason: 'sent');
      await until(() async => (await bob.videos(chatId)).isNotEmpty, reason: 'bob gets it');
      final b = (await bob.videos(chatId)).single;
      expect((b.width, b.height, b.durationMs, b.bytes), (1280, 720, 12000, 5000));
      expect(backend.mediaBlob(b.mediaKey), isNot(contains(v.bytes.sublist(0, 32))));
      expect(await bob.media.load(b.ref), v.bytes);
      expect(await bob.media.load(b.thumbRef!), v.thumb);
    });

    test('a real-sized video (20 MiB) sends and decrypts', () async {
      final (alice, bob, chatId) = await pair();
      final big = Uint8List(20 * 1024 * 1024)..fillRange(0, 1000, 7);
      final id = await alice.media.sendVideo(
          chatId, ProcessedVideo(bytes: big, width: 1280, height: 720, duration: const Duration(minutes: 2)));
      await until(() async => (await alice.row(id))?.state == 'sent', reason: 'sent');
      await until(() async => (await bob.videos(chatId)).isNotEmpty);
      expect((await bob.media.load((await bob.videos(chatId)).single.ref))!.length, big.length);
    });

    test('a video without a poster frame still sends', () async {
      final (alice, bob, chatId) = await pair();
      await alice.media.sendVideo(chatId, clip(thumb: false));
      await until(() async => (await bob.videos(chatId)).isNotEmpty);
      final b = (await bob.videos(chatId)).single;
      expect(b.thumbRef, isNull);
      expect(await bob.media.load(b.ref), photoBytes(5000, 5));
    });

    test('too long or too large is refused before anything is queued', () async {
      final (alice, _, chatId) = await pair();
      expect(() => alice.media.sendVideo(chatId, ProcessedVideo(bytes: photoBytes(10), width: 1, height: 1, duration: Duration.zero)),
          throwsArgumentError);
      expect(
        () => alice.media.sendVideo(
            chatId, ProcessedVideo(bytes: Uint8List(maxVideoBytes + 1), width: 1, height: 1, duration: const Duration(seconds: 1))),
        throwsA(isA<VideoTooLargeException>()),
      );
      expect(await alice.rows(chatId), isEmpty);
    });
  });

  test('a text with a link preview: its image travels as an encrypted thumbnail', () async {
    final (alice, bob, chatId) = await pair();
    final id = await alice.media.sendTextWithPreview(
      chatId,
      'look https://shop.example/hose',
      FetchedPreview(url: 'https://shop.example/hose', title: 'Hose', siteName: 'Shop', image: photoBytes(900, 4)),
    );
    await until(() async => (await alice.row(id))?.state == 'sent', reason: 'sent after the image uploads');
    await until(() async => (await bob.rows(chatId)).isNotEmpty);
    final t = Plaintext.decode(utf8.encode((await bob.row(id))!.body!)) as TextBody;
    expect((t.text, t.preview!.title, t.preview!.siteName), ('look https://shop.example/hose', 'Hose', 'Shop'));
    // FakeProcessor's thumbnail is the first 16 bytes.
    expect(await bob.media.load(t.preview!.image!.ref), photoBytes(900, 4).sublist(0, 16));
  });

  test('a GIF link: the animation travels unmodified (over the thumbnail cap), marked animated', () async {
    final (alice, bob, chatId) = await pair();
    // GIF89a 498x476, a NETSCAPE2.0 loop block, then 1.5 MiB of frames.
    final gif = Uint8List.fromList([
      ...ascii.encode('GIF89a'), 0xf2, 0x01, 0xdc, 0x01, 0, 0, 0,
      0x21, 0xff, 0x0b, ...ascii.encode('NETSCAPE2.0'), 3, 1, 0, 0, 0,
      ...List.filled(1536 * 1024, 7), 0x3b,
    ]);
    const url = 'https://tenor.com/view/cat-1';
    final id = await alice.media.sendTextWithPreview(
        chatId, url, FetchedPreview(url: url, title: 'Cat GIF', siteName: 'Tenor', image: gif, animated: true));
    await until(() async => (await alice.row(id))?.state == 'sent', reason: 'sent after the GIF uploads');
    await until(() async => (await bob.rows(chatId)).isNotEmpty);
    final t = Plaintext.decode(utf8.encode((await bob.row(id))!.body!)) as TextBody;
    final image = t.preview!.image!;
    expect((image.animated, image.width, image.height), (true, 498, 476));
    expect(await bob.media.load(image.ref), gif);

    // Marked animated by the server but not a GIF: an ordinary thumbnail.
    final id2 = await alice.media.sendTextWithPreview(
        chatId, url, FetchedPreview(url: url, title: 'Cat GIF', image: photoBytes(900, 4), animated: true));
    await until(() async => (await bob.rows(chatId)).length == 2);
    final t2 = Plaintext.decode(utf8.encode((await bob.row(id2))!.body!)) as TextBody;
    expect(t2.preview!.image!.animated, isFalse);
    expect(await bob.media.load(t2.preview!.image!.ref), photoBytes(900, 4).sublist(0, 16));
  });

  test('a preview whose image does not decode still sends, without the image', () async {
    final (alice, bob, chatId) = await pair();
    final id = await alice.media.sendTextWithPreview(
        chatId, 'https://x.io', FetchedPreview(url: 'https://x.io', title: 'X', image: Uint8List.fromList([0xff, 0x00, 1])));
    await until(() async => (await bob.rows(chatId)).isNotEmpty);
    final t = Plaintext.decode(utf8.encode((await bob.row(id))!.body!)) as TextBody;
    expect((t.preview!.title, t.preview!.image), ('X', null));
  });

  group('late link previews', () {
    const url = 'https://shop.example/hose';
    FetchedPreview card() => FetchedPreview(url: url, title: 'Hose', siteName: 'Shop', image: photoBytes(900, 4));

    test('attached once the fetch finishes; Bob gets the card and its image', () async {
      final (alice, bob, chatId) = await pair();
      final id = await alice.sync.sendText(chatId, 'look $url');
      final edit = await alice.media.attachLatePreview(chatId, id, Future.value(card()));
      expect(edit, isNotNull);
      await until(() async => (await bob.rows(chatId)).length == 2, reason: 'the preview edit after its upload');
      final rows = await bob.rows(chatId);
      final c = messageChanges(rows);
      final m = rows.firstWhere((r) => r.id == id);
      expect(c.previewOf(m)?.title, 'Hose');
      expect(c.edited, isEmpty);
      expect(await bob.media.load(c.previewOf(m)!.image!.ref), photoBytes(900, 4).sublist(0, 16));
    });

    test('a message deleted while its preview is on the way gets nothing; staged images are dropped', () async {
      final (alice, _, chatId) = await pair();
      // Deleted while the fetch is still held.
      final a = await alice.sync.sendText(chatId, 'look $url');
      await until(() async => (await alice.row(a))?.state == 'sent');
      final fetch = Completer<FetchedPreview?>();
      final lateA = alice.media.attachLatePreview(chatId, a, fetch.future);
      await alice.sync.deleteMessage(chatId, a);
      fetch.complete(card());
      expect(await lateA, isNull);

      // Deleted while its image was being made (after the first check).
      final b = await alice.sync.sendText(chatId, 'look $url');
      await until(() async => (await alice.row(b))?.state == 'sent');
      final before = alice.processor.calls;
      final hold = alice.processor.hold = Completer<void>();
      final lateB = alice.media.attachLatePreview(chatId, b, Future.value(card()));
      await until(() => alice.processor.calls > before, reason: 'image processing started');
      await alice.sync.deleteMessage(chatId, b);
      hold.complete();
      expect(await lateB, isNull);
      expect(await alice.db.uploadMessageIds(), isEmpty);
      expect((await alice.rows(chatId)).where((r) => r.kind == 'edit'), isEmpty);
    });
  });

  group('forwarding', () {
    Future<(Node, Node, Node, String, String)> trio() async {
      final alice = await start(await backend.addUser('Alice'));
      final bob = await start(await backend.addUser('Bob'));
      final carol = await start(await backend.addUser('Carol'));
      final ab = await alice.sync.openDirect(bob.d.userId);
      final ac = await alice.sync.openDirect(carol.d.userId);
      for (final n in [alice, bob, carol]) {
        await n.sync.idle;
      }
      return (alice, bob, carol, ab, ac);
    }

    Future<String> forward(Node n, String fromChat, String id, String to) async {
      final rows = await n.rows(fromChat);
      return forwardMessage(
        message: rows.firstWhere((r) => r.id == id),
        changes: messageChanges(rows),
        toChatId: to,
        sync: n.sync,
        media: n.media,
      );
    }

    test('a received photo goes to another chat as a new upload, marked forwarded', () async {
      final (alice, bob, carol, ab, ac) = await trio();
      final original = photoBytes(500);
      final id = await sentPhoto(bob, ab, original);
      await until(() async => (await alice.photos(ab)).isNotEmpty, reason: 'alice gets it');
      final fwd = await forward(alice, ab, id, ac);
      await until(() async => (await carol.photos(ac)).isNotEmpty, reason: 'carol gets the forward');
      final p = (await carol.photos(ac)).single;
      final first = (await alice.photos(ab)).single;
      expect(p.mediaKey, isNot(first.mediaKey), reason: "media access follows the chat: Carol can't read Bob's upload");
      expect(b64url(p.key), isNot(b64url(first.key)));
      expect(await carol.media.load(p.fullRef), original);
      expect(isForwarded((await carol.row(fwd))!), isTrue);
      expect(isForwarded((await alice.row(id))!), isFalse);
    });

    test('a voice clip forwards with its length and waveform', () async {
      final (alice, bob, carol, ab, ac) = await trio();
      final clip = RecordedVoice(bytes: photoBytes(800, 3), duration: const Duration(seconds: 4), waveform: [1, 2, 3]);
      final id = await bob.media.sendVoice(ab, clip);
      await until(() async => (await alice.voices(ab)).isNotEmpty, reason: 'alice gets it');
      await forward(alice, ab, id, ac);
      await until(() async => (await carol.voices(ac)).isNotEmpty, reason: 'carol gets the forward');
      final v = (await carol.voices(ac)).single;
      expect(v.durationMs, 4000);
      expect(v.waveform, [1, 2, 3]);
      expect(await carol.media.load(v.ref), clip.bytes);
    });

    test("forwarding a voice clip copies its sender's transcript, as the forwarder's", () async {
      final (alice, bob, carol, ab, ac) = await trio();
      final clip = RecordedVoice(bytes: photoBytes(800, 3), duration: const Duration(seconds: 4), waveform: [1, 2, 3]);
      final id = await bob.media.sendVoice(ab, clip);
      await bob.sync.sendTranscript(ab, id, 'pick up milk');
      await until(() async => (await alice.rows(ab)).any((r) => r.kind == 'transcript'), reason: 'alice gets the transcript');
      final fwd = await forward(alice, ab, id, ac);
      String? carolSees(List<MessageRow> rows) {
        final m = rows.where((r) => r.id == fwd).firstOrNull;
        return m == null ? null : messageChanges(rows).transcriptOf(m);
      }

      await until(() async => carolSees(await carol.rows(ac)) != null, reason: 'carol gets the clip and its transcript');
      expect(carolSees(await carol.rows(ac)), 'pick up milk');
    });

    test('forwarding a clip without a transcript sends none', () async {
      final (alice, bob, _, ab, ac) = await trio();
      final clip = RecordedVoice(bytes: photoBytes(800, 3), duration: const Duration(seconds: 4), waveform: [1, 2, 3]);
      final id = await bob.media.sendVoice(ab, clip);
      await until(() async => (await alice.voices(ab)).isNotEmpty, reason: 'alice gets it');
      await forward(alice, ab, id, ac);
      expect((await alice.rows(ac)).where((r) => r.kind == 'transcript'), isEmpty);
    });

    test('a video forwards with its poster frame', () async {
      final (alice, bob, carol, ab, ac) = await trio();
      final v = ProcessedVideo(bytes: photoBytes(900, 2), thumb: photoBytes(30, 4), width: 640, height: 360, duration: const Duration(seconds: 3));
      final id = await bob.media.sendVideo(ab, v);
      await until(() async => (await alice.videos(ab)).isNotEmpty, reason: 'alice gets it');
      await forward(alice, ab, id, ac);
      await until(() async => (await carol.videos(ac)).isNotEmpty, reason: 'carol gets the forward');
      final c = (await carol.videos(ac)).single;
      expect((c.width, c.height, c.durationMs), (640, 360, 3000));
      expect(await carol.media.load(c.ref), v.bytes);
      expect(await carol.media.load(c.thumbRef!), v.thumb);
    });

    test('a file forwards under a new key with its name and type', () async {
      final (alice, bob, carol, ab, ac) = await trio();
      final bytes = photoBytes(1200, 6);
      final id = await bob.media.sendFile(ab, name: 'Tickets.pdf', bytes: bytes, mime: 'application/pdf');
      await until(() async => (await alice.files(ab)).isNotEmpty, reason: 'alice gets it');
      final fwd = await forward(alice, ab, id, ac);
      await until(() async => (await carol.files(ac)).isNotEmpty, reason: 'carol gets the forward');
      final c = (await carol.files(ac)).single;
      final first = (await alice.files(ab)).single;
      expect((c.name, c.mime, c.bytes), ('Tickets.pdf', 'application/pdf', 1200));
      expect(c.mediaKey, isNot(first.mediaKey));
      expect(b64url(c.key), isNot(b64url(first.key)));
      expect(await carol.media.load(c.ref), bytes);
      expect(isForwarded((await carol.row(fwd))!), isTrue);
    });

    test('a file whose media expired cannot be forwarded', () async {
      final (alice, bob, _, ab, ac) = await trio();
      final id = await bob.media.sendFile(ab, name: 'a.zip', bytes: photoBytes(300));
      await until(() async => (await alice.files(ab)).isNotEmpty);
      alice.d.hub.dropEventTypes.add('media_expired');
      backend.expireMedia([(await alice.files(ab)).single.mediaKey]);
      await expectLater(forward(alice, ab, id, ac), throwsA(isA<ForwardException>()));
      expect(await alice.rows(ac), isEmpty);
    });

    test('a text forwards its latest edit, without its reply or mentions', () async {
      final (alice, bob, carol, ab, ac) = await trio();
      final id = await bob.sync.sendText(ab, 'typo', replyTo: 'x', mentions: [alice.d.userId]);
      await bob.sync.editText(ab, id, 'fixed');
      await until(() async => (await alice.rows(ab)).length == 2, reason: 'alice gets both');
      final fwd = await forward(alice, ab, id, ac);
      await until(() async => (await carol.rows(ac)).isNotEmpty, reason: 'carol gets the forward');
      final body = Plaintext.decode(utf8.encode((await carol.row(fwd))!.body!)) as TextBody;
      expect((body.text, body.replyTo), ('fixed', null));
      expect(body.mentions, isEmpty);
    });

    test('a photo whose media expired cannot be forwarded', () async {
      final (alice, bob, _, ab, ac) = await trio();
      final id = await sentPhoto(bob, ab, photoBytes(300));
      await until(() async => (await alice.photos(ab)).isNotEmpty);
      final p = (await alice.photos(ab)).single;
      alice.d.hub.dropEventTypes.add('media_expired');
      backend.expireMedia([p.mediaKey, p.thumbKey]);
      await expectLater(forward(alice, ab, id, ac), throwsA(isA<ForwardException>()));
      expect(await alice.rows(ac), isEmpty);
    });
  });

  test('the message is sent only after both blobs uploaded', () async {
    final (alice, _, chatId) = await pair();
    alice.d.media.hold = Completer<void>();
    final id = await alice.media.sendPhoto(chatId, photoBytes(500));
    await until(() => alice.media.progressNow(id) != null, reason: 'upload starts');
    await alice.sync.idle;
    expect(alice.d.hub.sent.where((f) => f['type'] == 'send'), isEmpty);
    expect((await alice.row(id))!.state, 'pending');
    alice.d.media.hold!.complete();
    alice.d.media.hold = null;
    await until(() async => (await alice.row(id))!.state == 'sent', reason: 'sent after upload');
    expect(alice.d.media.uploads, hasLength(2));
    final p = (await alice.photos(chatId)).single;
    expect(alice.d.media.uploads, [p.thumbKey, p.mediaKey]);
    expect(await alice.db.hasUploads(id), isFalse);
  });

  test('progress reaches 1', () async {
    final (alice, _, chatId) = await pair();
    final seen = <double>[];
    alice.d.media.hold = Completer<void>();
    final id = await alice.media.sendPhoto(chatId, photoBytes(400));
    final sub = alice.media.progress(id).listen((v) => seen.add(v!));
    await until(() => alice.media.progressNow(id) != null);
    alice.d.media.hold!.complete();
    alice.d.media.hold = null;
    await until(() => alice.media.progressNow(id) == 1, reason: 'progress 1');
    await sub.cancel();
    expect(seen, isNotEmpty);
    expect(seen.last, 1);
    for (var i = 1; i < seen.length; i++) {
      expect(seen[i], greaterThanOrEqualTo(seen[i - 1]));
    }
  });

  test('upload resumes after a network failure and the message is sent once', () async {
    final (alice, bob, chatId) = await pair();
    alice.d.media.failUploads = 2;
    final id = await sentPhoto(alice, chatId, photoBytes(300));
    await until(() async => (await bob.photos(chatId)).isNotEmpty);
    expect(backend.storedMessages(chatId).where((m) => m.id == id), hasLength(1));
    expect(alice.d.media.uploads, hasLength(2));
  });

  test('pending blobs survive a restart and upload on the next start', () async {
    final (alice, bob, chatId) = await pair();
    alice.d.media.hold = Completer<void>();
    final id = await alice.media.sendPhoto(chatId, photoBytes(300));
    await until(() => alice.media.progressNow(id) != null);
    // The app quits mid-upload: nothing was stored server-side.
    await alice.media.stop();
    await alice.sync.stop();
    alice.d.media.hold = null;
    final again = Node(alice.d);
    // Reuse the same databases, as a restarted app would.
    final restarted = MediaService(db: alice.db, api: alice.d.media, sync: again.sync, processor: again.processor);
    nodes.add(again);
    await again.sync.start();
    await restarted.start();
    await until(() async => (await alice.d.db.messageById(id))!.state == 'sent', reason: 'sent after restart');
    await until(() async => (await bob.photos(chatId)).isNotEmpty);
    await restarted.stop();
  });

  test('without the media gate a photo message waits in the outbox', () async {
    final (alice, bob, chatId) = await pair();
    alice.d.media.hold = Completer<void>();
    final id = await alice.media.sendPhoto(chatId, photoBytes(200));
    await alice.media.stop(); // the app restarts; ChatSync flushes before MediaService starts
    alice.d.media.hold!.complete();
    alice.d.media.hold = null;
    alice.d.hub.drop();
    await alice.d.hub.connect();
    await alice.sync.idle;
    expect(alice.d.hub.sent.where((f) => f['type'] == 'send'), isEmpty);
    expect((await alice.row(id))!.state, 'pending');
    final restarted = MediaService(db: alice.db, api: alice.d.media, sync: alice.sync, processor: alice.processor);
    await restarted.start();
    await until(() async => (await alice.row(id))!.state == 'sent', reason: 'sent once the gate is back');
    await until(() async => (await bob.photos(chatId)).isNotEmpty);
    await restarted.stop();
  });

  test('a 413 marks the message failed and retry re-uploads', () async {
    final (alice, _, chatId) = await pair();
    alice.d.media.failUploads = 1;
    alice.d.media.failWith = const ApiException(413, 'too_large');
    final id = await alice.media.sendPhoto(chatId, photoBytes(300));
    await until(() async => (await alice.row(id))!.state == 'failed', reason: 'failed');
    expect(await alice.db.hasUploads(id), isTrue);
    await alice.sync.retry(id);
    await until(() async => (await alice.row(id))!.state == 'sent', reason: 'sent after retry');
  });

  test('a failed upload clears its progress', () async {
    final (alice, _, chatId) = await pair();
    alice.d.media.failUploads = 1;
    alice.d.media.failWith = const ApiException(413, 'too_large');
    final seen = <double?>[];
    final id = await alice.media.sendPhoto(chatId, photoBytes(300));
    final sub = alice.media.progress(id).listen(seen.add);
    await until(() async => (await alice.row(id))!.state == 'failed');
    await pump();
    await sub.cancel();
    expect(alice.media.progressNow(id), isNull);
    expect(seen.last, isNull);
  });

  test('a photo whose blobs are gone is failed, never sent', () async {
    final (alice, bob, chatId) = await pair();
    alice.d.media.hold = Completer<void>();
    final id = await alice.media.sendPhoto(chatId, photoBytes(300));
    await until(() => alice.media.progressNow(id) != null);
    await alice.media.stop();
    // The media database is lost (browser storage cleared) while the chat database survives.
    await alice.db.wipe();
    alice.d.media.hold!.complete();
    alice.d.media.hold = null;
    final restarted = MediaService(db: alice.db, api: alice.d.media, sync: alice.sync, processor: alice.processor);
    await restarted.start();
    await until(() async => (await alice.row(id))!.state == 'failed', reason: 'failed, not sent');
    await alice.sync.idle;
    expect(alice.d.hub.sent.where((f) => f['type'] == 'send'), isEmpty);
    expect(await bob.photos(chatId), isEmpty);
    await restarted.stop();
  });

  test('a stopped service does not fail an upload that was in flight', () async {
    final (alice, _, chatId) = await pair();
    alice.d.media.hold = Completer<void>();
    final id = await alice.media.sendPhoto(chatId, photoBytes(300));
    await until(() => alice.media.progressNow(id) != null);
    await alice.media.stop();
    alice.d.media.failWith = const ApiException(409, 'conflict');
    alice.d.media.hold!.completeError(const ApiException(409, 'conflict'));
    alice.d.media.hold = null;
    await pump();
    await alice.sync.idle;
    expect((await alice.row(id))!.state, 'pending');
  });

  test('a cached blob is served only for the hash it was verified against', () async {
    final (alice, bob, chatId) = await pair();
    await sentPhoto(alice, chatId, photoBytes(300));
    await until(() async => (await bob.photos(chatId)).isNotEmpty);
    final p = (await bob.photos(chatId)).single;
    expect(await bob.media.load(p.fullRef), isNotNull);
    // Another message names the same media key with a different hash (and key).
    final forged = MediaRef(id: p.mediaKey, key: newMediaKey(), sha256: Uint8List(32), purpose: MediaPurpose.file);
    expect(forged == p.fullRef, isFalse);
    await expectLater(bob.media.load(forged), throwsA(isA<CryptoFailure>()));
    expect(bob.d.media.downloads.where((k) => k == p.mediaKey), hasLength(2));
    expect(await bob.media.load(p.fullRef), isNotNull);
  });

  test('encryption, hashing and decryption go through the offload hook', () async {
    final alice = Node(await backend.addUser('Alice'));
    var calls = 0;
    final media = MediaService(
      db: alice.db,
      api: alice.d.media,
      sync: alice.sync,
      processor: alice.processor,
      offload: <R>(FutureOr<R> Function() task) async {
        calls++;
        return task();
      },
    );
    await media.stage(
        chatId: 'C', messageId: 'M', kind: 'photo', purpose: MediaPurpose.file, key: newMediaKey(), plaintext: photoBytes(10), position: 0);
    expect(calls, 1);
    await alice.db.close();
    await alice.d.dispose();
  });

  test('sending and loading work with a real isolate offload', () async {
    final alice = await start(await backend.addUser('Alice'));
    final bob = await start(await backend.addUser('Bob'));
    Future<R> isolate<R>(FutureOr<R> Function() task) => Isolate.run(task);
    final aliceMedia = MediaService(db: alice.db, api: alice.d.media, sync: alice.sync, processor: alice.processor, offload: isolate);
    final bobMedia = MediaService(db: bob.db, api: bob.d.media, sync: bob.sync, processor: bob.processor, offload: isolate);
    await alice.media.stop();
    await bob.media.stop();
    await aliceMedia.start();
    await bobMedia.start();
    final chatId = await alice.sync.openDirect(bob.d.userId);
    final id = await aliceMedia.sendPhoto(chatId, photoBytes(5000));
    await until(() async => (await alice.row(id))?.state == 'sent');
    await until(() async => (await bob.photos(chatId)).isNotEmpty);
    expect(await bobMedia.load((await bob.photos(chatId)).single.fullRef), photoBytes(5000));
    await aliceMedia.stop();
    await bobMedia.stop();
  });

  test('an image that does not decode throws and queues nothing', () async {
    final (alice, _, chatId) = await pair();
    await expectLater(alice.media.sendPhoto(chatId, Uint8List.fromList([0xff, 0x00, 1])), throwsA(isA<Exception>()));
    expect(await alice.rows(chatId), isEmpty);
  });

  test('a blob whose hash differs is rejected', () async {
    final (alice, bob, chatId) = await pair();
    await sentPhoto(alice, chatId, photoBytes(300));
    await until(() async => (await bob.photos(chatId)).isNotEmpty);
    final p = (await bob.photos(chatId)).single;
    // Someone who knows the media key (a member) plants a different image that decrypts fine:
    // only the hash pinned in the signed message catches it.
    backend.tamperMedia(
        p.mediaKey, await encryptMedia(key: p.key, plaintext: photoBytes(300, 99), purpose: MediaPurpose.file));
    await expectLater(bob.media.load(p.fullRef), throwsA(isA<CryptoFailure>()));
    expect(await bob.db.cacheGet(p.fullRef.cacheKey), isNull);
    // The thumbnail's blob in the photo's place doesn't open either.
    backend.tamperMedia(p.mediaKey, backend.mediaBlob(p.thumbKey)!);
    await expectLater(bob.media.load(p.fullRef), throwsA(isA<CryptoFailure>()));
  });

  test('410 marks the media expired', () async {
    final (alice, bob, chatId) = await pair();
    await sentPhoto(alice, chatId, photoBytes(300));
    await until(() async => (await bob.photos(chatId)).isNotEmpty);
    final p = (await bob.photos(chatId)).single;
    bob.d.hub.dropEventTypes.add('media_expired'); // offline when it happened
    backend.expireMedia([p.mediaKey, p.thumbKey]);
    expect(await bob.media.load(p.thumbRef), isNull);
    expect(await bob.db.isExpired(p.thumbKey), isTrue);
    expect(bob.d.media.downloads, isEmpty);
    expect(await bob.media.load(p.thumbRef), isNull);
  });

  test('media_expired event marks keys expired and drops the cache', () async {
    final (alice, bob, chatId) = await pair();
    await sentPhoto(alice, chatId, photoBytes(300));
    await until(() async => (await bob.photos(chatId)).isNotEmpty);
    final p = (await bob.photos(chatId)).single;
    expect(await bob.media.load(p.fullRef), isNotNull);
    backend.expireMedia([p.mediaKey, p.thumbKey]);
    await until(() async => await alice.db.isExpired(p.mediaKey) && await bob.db.isExpired(p.mediaKey));
    await until(() async => await bob.db.cacheGet(p.fullRef.cacheKey) == null);
    expect(await bob.media.expired.first, containsAll([p.mediaKey, p.thumbKey]));
    expect(await bob.media.load(p.fullRef), isNull);
  });

  test('cache evicts least recently used beyond the limit', () async {
    final db = memoryMediaDb();
    addTearDown(db.close);
    await db.cachePut('a', photoBytes(400), maxBytes: 1000);
    await db.cachePut('b', photoBytes(400), maxBytes: 1000);
    await Future<void>.delayed(const Duration(milliseconds: 2));
    expect(await db.cacheGet('a'), isNotNull); // a is now more recent than b
    await db.cachePut('c', photoBytes(400), maxBytes: 1000);
    expect(await db.cacheGet('b'), isNull);
    expect(await db.cacheGet('a'), isNotNull);
    expect(await db.cacheGet('c'), isNotNull);
    expect(await db.cacheBytes(), 800);
    // Something over half the cache (a video) isn't cached at all, and pushes nothing out.
    await db.cachePut('huge', photoBytes(600), maxBytes: 1000);
    expect(await db.cacheGet('huge'), isNull);
    expect(await db.cacheGet('a'), isNotNull);
    expect(await db.cacheBytes(), 800);
  });

  test('concurrent loads download once', () async {
    final (alice, bob, chatId) = await pair();
    await sentPhoto(alice, chatId, photoBytes(300));
    await until(() async => (await bob.photos(chatId)).isNotEmpty);
    final p = (await bob.photos(chatId)).single;
    final r = await Future.wait([bob.media.load(p.fullRef), bob.media.load(p.fullRef), bob.media.load(p.fullRef)]);
    expect(r.every((x) => x != null && x.length == 300), isTrue);
    expect(bob.d.media.downloads, [p.mediaKey]);
  });

  test('start drops old uploads whose message is gone, keeps fresh ones', () async {
    final alice = await start(await backend.addUser('Alice'));
    await alice.db.putUpload(
        key: 'K1', messageId: 'GONE', chatId: 'C', kind: 'photo', cipher: Uint8List(3), position: 0, createdAt: 0);
    // Staged a moment ago by a sendPhoto that hasn't queued its message yet.
    await alice.db.putUpload(
        key: 'K2', messageId: 'SOON', chatId: 'C', kind: 'photo', cipher: Uint8List(3), position: 0);
    await alice.media.start();
    expect(await alice.db.hasUploads('GONE'), isFalse);
    expect(await alice.db.hasUploads('SOON'), isTrue);
  });

  test('bindDevice to another device wipes media data', () async {
    final db = memoryMediaDb();
    addTearDown(db.close);
    await db.bindDevice('D1');
    await db.cachePut('a', photoBytes(10), maxBytes: 100);
    await db.markExpired(['x']);
    await db.bindDevice('D1');
    expect(await db.cacheGet('a'), isNotNull);
    await db.bindDevice('D2');
    expect(await db.cacheGet('a'), isNull);
    expect(await db.isExpired('x'), isFalse);
  });

  test('media key and hashes round-trip through the message', () async {
    final (alice, bob, chatId) = await pair();
    await sentPhoto(alice, chatId, photoBytes(100));
    await until(() async => (await bob.photos(chatId)).isNotEmpty);
    final mine = (await alice.photos(chatId)).single, theirs = (await bob.photos(chatId)).single;
    expect(b64url(theirs.key), b64url(mine.key));
    expect(theirs.toJson(), mine.toJson());
  });

  group('voice', () {
    RecordedVoice clip({int n = 2000, Duration duration = const Duration(seconds: 3)}) =>
        RecordedVoice(bytes: photoBytes(n, 3), duration: duration, waveform: [for (var i = 0; i < 64; i++) i]);

    test('sendVoice stages one voice blob and queues a voice message that Bob can play', () async {
      final (alice, bob, chatId) = await pair();
      final c = clip();
      final id = await alice.media.sendVoice(chatId, c);
      await until(() async => (await alice.row(id))?.state == 'sent', reason: 'voice sent');
      expect(alice.d.media.uploads, hasLength(1));
      await until(() async => (await bob.voices(chatId)).isNotEmpty, reason: 'bob gets the voice');
      final v = (await bob.voices(chatId)).single;
      expect((await bob.row(id))!.kind, 'voice');
      expect((v.durationMs, v.bytes, v.mime), (3000, 2000, 'audio/mp4'));
      expect(v.waveform, c.waveform);
      expect(alice.d.media.uploads.single, v.mediaKey);
      expect(backend.mediaBlob(v.mediaKey), isNot(contains(c.bytes.sublist(0, 32))));
      expect(await bob.media.load(v.ref), c.bytes);
    });

    test('sendVoice rejects over ten minutes, empty clips and zero length', () async {
      final (alice, _, chatId) = await pair();
      await expectLater(alice.media.sendVoice(chatId, clip(duration: maxVoiceDuration + const Duration(milliseconds: 1))),
          throwsArgumentError);
      await expectLater(alice.media.sendVoice(chatId, clip(n: 0)), throwsArgumentError);
      await expectLater(alice.media.sendVoice(chatId, clip(duration: Duration.zero)), throwsArgumentError);
      expect(await alice.media.sendVoice(chatId, clip(duration: maxVoiceDuration)), isNotEmpty);
      expect((await alice.rows(chatId)).where((r) => r.kind == 'voice'), hasLength(1));
    });

    test('a lone user (a reviewer) sends text, a photo and a voice message to a chat with only themselves', () async {
      final alice = await start(await backend.addUser('Reviewer'));
      final chatId = await alice.sync.createGroup('Note to self', const []);
      expect(backend.chatDto(chatId).members.map((m) => m.userId), [alice.d.userId]);
      await alice.sync.sendText(chatId, 'hello me');
      final photo = await sentPhoto(alice, chatId, photoBytes(800));
      final voice = await alice.media.sendVoice(chatId, clip());
      await until(() async => (await alice.row(voice))?.state == 'sent', reason: 'voice sent');
      expect(backend.storedMessages(chatId), hasLength(3));
      expect((await alice.row(photo))!.kind, 'photo');
      // A second device of the same user (paired) gets the keys from the first and reads all of it.
      final laptop = await start(await backend.pairDevice(alice.d.userId));
      await until(() async => (await laptop.rows(chatId)).length == 3, reason: 'laptop catches up');
      final v = (await laptop.voices(chatId)).single;
      expect(await laptop.media.load(v.ref), clip().bytes);
      expect(await laptop.media.load((await laptop.photos(chatId)).single.fullRef), photoBytes(800));
      // Revoking the laptop moves the one-member chat to a new epoch that the phone creates alone.
      backend.revoke(laptop.d.deviceId);
      await until(() async => backend.chatDto(chatId).epochReady && backend.chatDto(chatId).currentEpoch == 2,
          reason: 'epoch 2 created by the only member');
      await alice.sync.sendText(chatId, 'after revoke');
      await until(() async => backend.storedMessages(chatId).length == 4);
      expect(backend.storedMessages(chatId).last.envelope['epoch'], 2);
      expect(backend.hasWrap(chatId, 2, laptop.d.deviceId), isFalse);
    });

    test('sendVoice rejects a clip over the 8 MiB voice cap', () async {
      final (alice, _, chatId) = await pair();
      await expectLater(alice.media.sendVoice(chatId, clip(n: 8 * 1024 * 1024)), throwsArgumentError);
      expect(await alice.rows(chatId), isEmpty);
    });
  });

  group('files', () {
    test('sendFile stages one file blob and Bob gets the file, its name and type', () async {
      final (alice, bob, chatId) = await pair();
      final bytes = photoBytes(4000, 8);
      alice.d.media.hold = Completer<void>();
      final id = await alice.media.sendFile(chatId, name: 'Flight confirmation.pdf', bytes: bytes, mime: 'application/pdf');
      final staged = await alice.db.uploadsFor(id);
      expect(staged.map((u) => u.kind), ['file']);
      expect((await alice.row(id))!.kind, 'file');
      alice.d.media.hold!.complete();
      alice.d.media.hold = null;
      await until(() async => (await alice.row(id))?.state == 'sent', reason: 'file sent');
      expect(alice.d.media.uploads, hasLength(1));
      await until(() async => (await bob.files(chatId)).isNotEmpty, reason: 'bob gets the file');
      final f = (await bob.files(chatId)).single;
      expect((await bob.row(id))!.kind, 'file');
      expect((f.name, f.bytes, f.mime), ('Flight confirmation.pdf', 4000, 'application/pdf'));
      expect(alice.d.media.uploads.single, f.mediaKey);
      expect(backend.mediaBlob(f.mediaKey), isNot(contains(bytes.sublist(0, 32))));
      expect(await bob.media.load(f.ref), bytes);
    });

    test('a file can reply; its name is cleaned and an unknown type falls back', () async {
      final (alice, bob, chatId) = await pair();
      final first = await alice.sync.sendText(chatId, 'send me the tickets');
      final id = await bob.media.sendFile(chatId, name: '../../etc/passwd', bytes: photoBytes(50), replyTo: first);
      await until(() async => (await alice.files(chatId)).isNotEmpty, reason: 'alice gets it');
      final f = (await alice.files(chatId)).single;
      expect(f.name, isNot(contains('/')));
      expect(f.mime, FileBody.defaultMime);
      expect(f.replyTo, first);
      expect(replyTargetOf((await alice.row(id))!), first);
    });

    test('too large or empty is refused before anything is staged', () async {
      final (alice, _, chatId) = await pair();
      await expectLater(alice.media.sendFile(chatId, name: 'big.iso', bytes: Uint8List(maxFileBytes + 1)),
          throwsA(isA<FileTooLargeException>()));
      await expectLater(alice.media.sendFile(chatId, name: 'empty.txt', bytes: Uint8List(0)), throwsArgumentError);
      expect(await alice.rows(chatId), isEmpty);
      expect(await alice.db.uploadMessageIds(), isEmpty);
    });

    test('a file at the limit sends', () async {
      final (alice, bob, chatId) = await pair();
      final id = await alice.media.sendFile(chatId, name: 'max.bin', bytes: Uint8List(maxFileBytes));
      await until(() async => (await alice.row(id))?.state == 'sent', reason: 'sent');
      await until(() async => (await bob.files(chatId)).isNotEmpty);
      expect((await bob.files(chatId)).single.bytes, maxFileBytes);
    });
  });
}
