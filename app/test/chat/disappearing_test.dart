// Disappearing messages on the device (docs/protocol.md "Disappearing messages"): expiry from my
// read time or my send time, the server's `gone` frame and tombstones, and what a purge removes.
import 'dart:async';
import 'dart:convert';

import 'package:famchat/chat/chat_sync.dart';
import 'package:famchat/chat/db/chat_db.dart';
import 'package:famchat/chat/search.dart';
import 'package:famchat/media/media_db.dart';
import 'package:famchat/media/media_service.dart';
import 'package:famchat/chat/plaintext.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_chat_backend.dart';
import '../support/fake_media.dart';

const day = Duration(days: 1);
const daySecs = 86400;

/// One device with a clock the test moves.
class Node {
  Node(this.d, this.clock) : mediaDb = memoryMediaDb() {
    sync = ChatSync(db: d.db, api: d.api, hub: d.hub, me: d.me, now: () => clock.now);
    media = MediaService(db: mediaDb, api: d.media, sync: sync, processor: FakeProcessor());
  }
  final TestDevice d;
  final Clock clock;
  final MediaDb mediaDb;
  late final ChatSync sync;
  late final MediaService media;

  Future<MessageRow?> row(String id) => d.db.messageById(id);
  Future<List<MessageRow>> rows(String chatId) => d.db.watchMessages(chatId).first;
}

class Clock {
  DateTime now = DateTime.fromMillisecondsSinceEpoch(1700000000000);
  void advance(Duration d) => now = now.add(d);
  int get ms => now.millisecondsSinceEpoch;
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
  late Clock clock;
  final nodes = <Node>[];

  Future<Node> start(TestDevice d) async {
    final n = Node(d, clock);
    nodes.add(n);
    await n.sync.start();
    await n.media.start();
    await n.sync.idle;
    return n;
  }

  Future<void> stopNode(Node n) async {
    await n.media.stop();
    await n.sync.stop();
  }

  setUp(() {
    backend = FakeChatBackend();
    clock = Clock();
  });
  tearDown(() async {
    for (final n in nodes) {
      await stopNode(n);
      await n.mediaDb.close();
    }
    for (final d in {for (final n in nodes) n.d}) {
      await d.dispose();
    }
    nodes.clear();
  });

  /// Alice and Bob in a direct chat with a 24-hour timer that Alice turned on.
  Future<(Node, Node, String)> timedPair() async {
    final alice = await start(await backend.addUser('Alice'));
    final bob = await start(await backend.addUser('Bob'));
    final chatId = await alice.sync.openDirect(bob.d.userId);
    await alice.sync.setDisappearing(chatId, daySecs);
    await until(() async => (await bob.d.db.chatById(chatId))?.disappearSecs == daySecs, reason: 'bob gets the timer');
    return (alice, bob, chatId);
  }

  Future<String> sent(Node n, String chatId, String text, {Node? to}) async {
    final id = await n.sync.sendText(chatId, text);
    await until(() async => (await n.row(id))?.state == 'sent', reason: 'sent');
    if (to != null) await until(() async => await to.row(id) != null, reason: 'delivered');
    return id;
  }

  test('the setting is shared: who changed it, when and after which seq; turning it off', () async {
    final (alice, bob, chatId) = await timedPair();
    expect(backend.calls, contains('PATCH /chats/$chatId'));
    final chat = (await bob.d.db.chatById(chatId))!;
    expect((chat.disappearSecs, chat.disappearChangedBy, chat.disappearChangedSeq), (daySecs, alice.d.userId, 0));
    await sent(alice, chatId, 'hi', to: bob);
    await bob.sync.setDisappearing(chatId, null);
    await until(() async => (await alice.d.db.chatById(chatId))?.disappearSecs == null, reason: 'alice sees it off');
    final off = (await alice.d.db.chatById(chatId))!;
    expect((off.disappearChangedBy, off.disappearChangedSeq), (bob.d.userId, 1));
    expect(() => alice.sync.setDisappearing(chatId, 3600), throwsArgumentError);
  });

  test("someone else's message expires my read time + its timer; unread, it stays", () async {
    final (alice, bob, chatId) = await timedPair();
    final id = await sent(alice, chatId, 'gone soon', to: bob);
    final stored = (await bob.row(id))!;
    expect(stored.disappearSecs, daySecs);
    final createdAt = stored.createdAt;
    expect(stored.expiresAt, createdAt + day.inMilliseconds + ChatSync.disappearBackstop.inMilliseconds,
        reason: 'unread: only the backstop');

    clock.advance(const Duration(days: 3));
    expect(await bob.sync.purgeExpired(), 0, reason: 'unread messages never expire from the read clock');
    expect(await bob.row(id), isNotNull);

    await bob.sync.markRead(chatId);
    final readAt = clock.ms;
    expect((await bob.row(id))!.expiresAt, readAt + day.inMilliseconds);
    // Reading again later doesn't move it.
    clock.advance(const Duration(hours: 2));
    await bob.sync.markRead(chatId);
    await bob.d.db.stampRead(chatId, 1);
    expect((await bob.row(id))!.expiresAt, readAt + day.inMilliseconds);

    clock.advance(const Duration(hours: 21, minutes: 59));
    expect(await bob.sync.purgeExpired(), 0);
    clock.advance(const Duration(minutes: 1));
    expect(await bob.sync.purgeExpired(), 1);
    expect(await bob.row(id), isNull);
    expect(await alice.row(id), isNotNull, reason: "Alice's copy follows her own clock");
  });

  test('my own messages expire sent + timer, on every device of mine', () async {
    final (alice, bob, chatId) = await timedPair();
    final alice2 = await start(await backend.addDevice(alice.d.userId));
    final id = await sent(alice, chatId, 'mine', to: bob);
    await until(() async => await alice2.row(id) != null, reason: 'my other device gets it');
    final mine = (await alice.row(id))!;
    expect((mine.disappearSecs, mine.expiresAt), (daySecs, mine.createdAt + day.inMilliseconds));
    expect((await alice2.row(id))!.expiresAt, mine.createdAt + day.inMilliseconds);

    clock.now = DateTime.fromMillisecondsSinceEpoch(mine.createdAt + day.inMilliseconds - 1);
    expect(await alice.sync.purgeExpired(), 0);
    clock.advance(const Duration(milliseconds: 1));
    expect(await alice.sync.purgeExpired(), 1);
    expect(await alice2.sync.purgeExpired(), 1);
    expect(await alice.row(id), isNull);
    expect(await alice2.row(id), isNull);
    expect(await bob.row(id), isNotNull, reason: "Bob hasn't read it");
  });

  test('the sweeper waits for the next expiry and purges on its own', () async {
    final (alice, bob, chatId) = await timedPair();
    final id = await sent(alice, chatId, 'tick tock', to: bob);
    final due = (await alice.row(id))!.expiresAt!;
    clock.now = DateTime.fromMillisecondsSinceEpoch(due - 40);
    alice.sync.sweepSoon(); // re-arms for 40 ms from now
    await alice.sync.idle;
    expect(await alice.row(id), isNotNull);
    clock.advance(const Duration(milliseconds: 40)); // by the time the timer fires, it's due
    await until(() async => await alice.row(id) == null, reason: 'the timer purged it');
  });

  test('a read on another of my devices starts the clock here too', () async {
    final (alice, bob, chatId) = await timedPair();
    final bob2 = await start(await backend.addDevice(bob.d.userId));
    final id = await sent(alice, chatId, 'read elsewhere', to: bob);
    await until(() async => await bob2.row(id) != null);
    clock.advance(const Duration(hours: 5));
    await bob2.sync.markRead(chatId);
    final at = clock.ms;
    await until(() async => (await bob.row(id))!.expiresAt == at + day.inMilliseconds, reason: 'the read event stamps it');
  });

  test('messages without a timer never expire, and turning it off leaves sent ones as they were', () async {
    final (alice, bob, chatId) = await timedPair();
    final timed = await sent(alice, chatId, 'timed', to: bob);
    await alice.sync.setDisappearing(chatId, null);
    await until(() async => (await bob.d.db.chatById(chatId))?.disappearSecs == null);
    final plain = await sent(alice, chatId, 'kept', to: bob);
    expect(((await bob.row(plain))!.disappearSecs, (await bob.row(plain))!.expiresAt), (null, null));
    expect((await alice.row(plain))!.expiresAt, isNull);
    expect((await bob.row(timed))!.disappearSecs, daySecs);
    await bob.sync.markRead(chatId);
    clock.advance(const Duration(days: 400));
    expect(await bob.sync.purgeExpired(), 1);
    expect(await bob.row(plain), isNotNull);
  });

  test('a device that was off for the whole timer drops what it read when it starts again', () async {
    final (alice, bob, chatId) = await timedPair();
    final id = await sent(alice, chatId, 'read then away', to: bob);
    await bob.sync.markRead(chatId);
    // Bob's app is closed for two days.
    await stopNode(bob);
    nodes.remove(bob);
    await bob.mediaDb.close();
    clock.advance(const Duration(days: 2));
    final again = await start(bob.d);
    await again.sync.idle;
    await until(() async => await again.row(id) == null, reason: 'swept on start');
    // Alice's app comes back to the foreground: her timer may have slept.
    alice.sync.sweepSoon();
    await alice.sync.idle;
    expect(await alice.row(id), isNull, reason: 'Alice sent it two days ago');
  });

  test('a device that was offline learns of server deletions from /me/gone and keeps the cursor', () async {
    final (alice, bob, chatId) = await timedPair();
    final first = await sent(alice, chatId, 'one', to: bob);
    final second = await sent(alice, chatId, 'two', to: bob);
    bob.d.hub.drop();
    backend.serverDelete(chatId, [first]);
    await pump();
    expect(await bob.row(first), isNotNull, reason: 'offline: no gone frame');
    await bob.d.hub.connect();
    await bob.sync.idle;
    await until(() async => await bob.row(first) == null, reason: 'tombstone applied');
    expect(await bob.row(second), isNotNull);
    expect(await bob.d.db.metaValue(ChatSync.goneCursorKey), '1');

    // The next sync asks only for newer tombstones.
    bob.d.hub.drop();
    backend.serverDelete(chatId, [second]);
    await bob.d.hub.connect();
    await bob.sync.idle;
    await until(() async => await bob.row(second) == null);
    expect(await bob.d.db.metaValue(ChatSync.goneCursorKey), '2');
  });

  test('a gone frame purges the message with its reactions, edits, pins and my star', () async {
    final (alice, bob, chatId) = await timedPair();
    final id = await sent(alice, chatId, 'about to go', to: bob);
    final other = await sent(alice, chatId, 'stays', to: bob);
    await bob.sync.react(chatId, id, '👍');
    await alice.sync.editText(chatId, id, 'about to go (edited)');
    await bob.sync.pinMessage(chatId, id, pinned: true);
    await bob.sync.react(chatId, other, '❤️');
    await bob.sync.star(chatId, id, starred: true);
    await until(() async => (await bob.d.db.changesTo(chatId, id)).length == 3, reason: 'changes arrive');
    expect(await bob.d.db.watchStars(chatId: chatId).first, hasLength(1));

    backend.serverDelete(chatId, [id]);
    await until(() async => await bob.row(id) == null, reason: 'gone frame');
    await bob.sync.idle;
    expect(await bob.d.db.changesTo(chatId, id), isEmpty);
    expect(await bob.d.db.watchStars(chatId: chatId).first, isEmpty);
    expect(await bob.row(other), isNotNull);
    expect(await bob.d.db.changesTo(chatId, other), hasLength(1), reason: "another message's reaction stays");
    await until(() async => await alice.row(id) == null, reason: 'the sender drops it too');
  });

  test('the chat list preview and unread count recompute after a purge', () async {
    final (alice, bob, chatId) = await timedPair();
    await sent(alice, chatId, 'first', to: bob);
    final last = await sent(alice, chatId, 'second', to: bob);
    var item = (await bob.d.db.watchChatList(bob.d.userId).first).single;
    expect((item.last?.id, item.unread), (last, 2));
    backend.serverDelete(chatId, [last]);
    await until(() async => await bob.row(last) == null);
    item = (await bob.d.db.watchChatList(bob.d.userId).first).single;
    expect(item.unread, 1);
    expect(jsonDecode(item.last!.body!)['text'], 'first');
  });

  test('search no longer finds a purged message, nor its edits', () async {
    final (alice, bob, chatId) = await timedPair();
    final id = await sent(alice, chatId, 'the secret plan', to: bob);
    await alice.sync.editText(chatId, id, 'the secret recipe');
    await until(() async => (await bob.d.db.changesTo(chatId, id)).isNotEmpty);
    expect((await searchMessages(bob.d.db, 'recipe')).map((h) => h.message.id), [id]);
    await bob.sync.markRead(chatId);
    clock.advance(day);
    await bob.sync.purgeExpired();
    expect(await searchMessages(bob.d.db, 'recipe'), isEmpty);
    expect(await searchMessages(bob.d.db, 'plan'), isEmpty);
    final rows = await bob.d.db.customSelect("SELECT COUNT(*) AS n FROM local_messages WHERE body LIKE '%secret%'").getSingle();
    expect(rows.read<int>('n'), 0, reason: 'no plaintext left anywhere');
  });

  test("a purge drops the message's cached media", () async {
    final (alice, bob, chatId) = await timedPair();
    final original = photoBytes(2000);
    final id = await alice.media.sendPhoto(chatId, original);
    await until(() async => await bob.row(id) != null, reason: 'bob gets the photo');
    final p = Plaintext.decode(utf8.encode((await bob.row(id))!.body!)) as PhotoBody;
    expect(await bob.media.load(p.fullRef), original);
    expect(await bob.media.load(p.thumbRef), isNotNull);
    expect(await bob.mediaDb.cacheGet(p.fullRef.cacheKey), isNotNull);
    expect(await alice.mediaDb.cacheGet(p.fullRef.cacheKey), isNotNull, reason: "the sender's staged copy");

    backend.serverDelete(chatId, [id]);
    await until(() async => await bob.row(id) == null && await alice.row(id) == null);
    await bob.media.purgesDone;
    await alice.media.purgesDone;
    expect(await bob.mediaDb.cacheGet(p.fullRef.cacheKey), isNull);
    expect(await bob.mediaDb.cacheGet(p.thumbRef.cacheKey), isNull);
    expect(await alice.mediaDb.cacheGet(p.fullRef.cacheKey), isNull);
    expect(await alice.mediaDb.uploadsFor(id), isEmpty);
  });

  test('purges before the media layer starts are handed over when it does', () async {
    final (alice, bob, chatId) = await timedPair();
    final id = await alice.media.sendPhoto(chatId, photoBytes(500));
    await until(() async => await bob.row(id) != null);
    final p = Plaintext.decode(utf8.encode((await bob.row(id))!.body!)) as PhotoBody;
    await bob.media.load(p.fullRef);
    await bob.media.stop();
    backend.serverDelete(chatId, [id]);
    await until(() async => await bob.row(id) == null);
    expect(await bob.mediaDb.cacheGet(p.fullRef.cacheKey), isNotNull);
    final media = MediaService(db: bob.mediaDb, api: bob.d.media, sync: bob.sync, processor: FakeProcessor());
    await media.start();
    await media.purgesDone;
    expect(await bob.mediaDb.cacheGet(p.fullRef.cacheKey), isNull);
    await media.stop();
  });

  test('mediaKeysOf names every blob a body references', () {
    MessageRow r(Map<String, Object?> body) => MessageRow(
          id: 'M', chatId: 'C', seq: 1, senderUserId: 'U', senderDeviceId: 'D', kind: 'text',
          body: jsonEncode(body), targetId: null, envelope: null, createdAt: 0, state: 'sent');
    expect(mediaKeysOf(r({'kind': 'photo', 'mediaKey': 'F', 'thumbKey': 'T'})), {'F', 'T'});
    expect(mediaKeysOf(r({'kind': 'text', 'text': 'x', 'preview': {'image': {'mediaKey': 'P'}}})), {'P'});
    expect(mediaKeysOf(r({'kind': 'text', 'text': 'x'})), isEmpty);
  });
}
