import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:famchat/api/models.dart';
import 'package:famchat/chat/chat_sync.dart';
import 'package:famchat/chat/db/chat_db.dart';
import 'package:famchat/chat/plaintext.dart';
import 'package:famchat/crypto/encoding.dart';
import 'package:famchat/crypto/media.dart';
import 'package:famchat/media/media_db.dart';
import 'package:famchat/media/media_service.dart';
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
    final sub = alice.media.progress(id).listen(seen.add);
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
    expect(await bob.db.cacheGet(p.mediaKey), isNull);
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
    await until(() async => await bob.db.cacheGet(p.mediaKey) == null);
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
    await db.cachePut('huge', photoBytes(2000), maxBytes: 1000);
    expect(await db.cacheBytes(), lessThanOrEqualTo(1000));
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

  test('start drops uploads whose message is gone', () async {
    final alice = await start(await backend.addUser('Alice'));
    await alice.db.putUpload(PendingUploadRow(
        key: 'K1', messageId: 'GONE', chatId: 'C', kind: 'photo', cipher: Uint8List(3), position: 0));
    await alice.media.start();
    expect(await alice.db.hasUploads('GONE'), isFalse);
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
}
