import 'dart:async';
import 'dart:convert';

import 'package:famchat/api/models.dart';
import 'package:famchat/chat/chat_sync.dart';
import 'package:famchat/chat/db/chat_db.dart';
import 'package:famchat/chat/reactions.dart';
import 'package:famchat/crypto/envelope.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_chat_backend.dart';

class Node {
  Node(this.d)
      : sync = ChatSync(
          db: d.db,
          api: d.api,
          hub: d.hub,
          me: d.me,
          typingTtl: const Duration(milliseconds: 300),
          typingThrottle: const Duration(milliseconds: 200),
        );
  final TestDevice d;
  final ChatSync sync;

  Future<List<MessageRow>> rows(String chatId) => d.db.watchMessages(chatId).first;
  Future<List<String>> texts(String chatId) async => [
        for (final r in await rows(chatId))
          if (r.kind == 'text') (jsonDecode(r.body!) as Map)['text'] as String,
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

  Future<Node> start(TestDevice d) async {
    final n = Node(d);
    nodes.add(n);
    await n.sync.start();
    await n.sync.idle;
    return n;
  }

  setUp(() => backend = FakeChatBackend());
  tearDown(() async {
    for (final n in nodes) {
      await n.sync.stop();
      await n.d.dispose();
    }
    nodes.clear();
  });

  Future<(Node, Node, Node)> trio() async =>
      (await start(await backend.addUser('Alice')), await start(await backend.addUser('Bob')), await start(await backend.addUser('Carol')));

  test('text goes from Alice to Bob', () async {
    final alice = await start(await backend.addUser('Alice'));
    final bob = await start(await backend.addUser('Bob'));
    final chatId = await alice.sync.openDirect(bob.d.userId);
    final id = await alice.sync.sendText(chatId, '  hello  ');
    await until(() async => (await bob.texts(chatId)).isNotEmpty, reason: 'bob gets the text');
    expect(await bob.texts(chatId), ['hello']);
    final mine = (await alice.rows(chatId)).single;
    await until(() async => (await alice.d.db.messageById(id))!.state == 'sent');
    expect((await alice.d.db.messageById(id))!.seq, 1);
    expect(mine.senderUserId, alice.d.userId);
    final bobRow = (await bob.rows(chatId)).single;
    expect((bobRow.id, bobRow.seq, bobRow.senderUserId), (id, 1, alice.d.userId));
    final list = await bob.d.db.watchChatList(bob.d.userId).first;
    expect(list.single.unread, 1);
  });

  test("Alice's second device sees her own message", () async {
    final alice = await start(await backend.addUser('Alice'));
    final bob = await start(await backend.addUser('Bob'));
    final chatId = await alice.sync.openDirect(bob.d.userId);
    final alice2 = await start(await backend.addDevice(alice.d.userId));
    // Alice's first device adds wraps for her new device (missing-wrap repair).
    await alice.sync.syncAll();
    await until(() async => await alice2.d.db.key(chatId, 1) != null, reason: 'alice2 gets the key');
    await alice.sync.sendText(chatId, 'from phone');
    await until(() async => (await alice2.texts(chatId)).isNotEmpty);
    expect(await alice2.texts(chatId), ['from phone']);
    final list = await alice2.d.db.watchChatList(alice2.d.userId).first;
    expect(list.single.unread, 0);
  });

  test('outbox resend after reconnect does not duplicate', () async {
    final alice = await start(await backend.addUser('Alice'));
    final bob = await start(await backend.addUser('Bob'));
    final chatId = await alice.sync.openDirect(bob.d.userId);
    await pump();
    await alice.sync.idle; // the chat event's catch-up must not find the message first
    alice.d.hub.dropNextAck = true;
    final id = await alice.sync.sendText(chatId, 'once');
    await until(() async => !alice.d.hub.connected);
    expect((await alice.d.db.messageById(id))!.state, 'pending');
    await alice.d.hub.connect();
    await until(() async => (await alice.d.db.messageById(id))!.state == 'sent');
    await alice.sync.idle;
    expect(backend.storedMessages(chatId), hasLength(1));
    expect((await alice.rows(chatId)).map((r) => (r.id, r.seq)), [(id, 1)]);
    await until(() async => (await bob.rows(chatId)).isNotEmpty);
    expect(await bob.texts(chatId), ['once']);
  });

  test('offline send flushes on connect', () async {
    final alice = await start(await backend.addUser('Alice'));
    final bob = await start(await backend.addUser('Bob'));
    final chatId = await alice.sync.openDirect(bob.d.userId);
    alice.d.hub.drop();
    final id = await alice.sync.sendText(chatId, 'later');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(backend.storedMessages(chatId), isEmpty);
    expect((await alice.d.db.messageById(id))!.state, 'pending');
    await alice.d.hub.connect();
    await until(() async => (await bob.texts(chatId)).contains('later'));
  });

  test('a gap triggers a catch-up fetch', () async {
    final alice = await start(await backend.addUser('Alice'));
    final bob = await start(await backend.addUser('Bob'));
    final chatId = await alice.sync.openDirect(bob.d.userId);
    alice.d.hub.holdFanOut = true;
    final first = await alice.sync.sendText(chatId, 'one');
    await until(() async => (await alice.d.db.messageById(first))!.state == 'sent');
    alice.d.hub.holdFanOut = false;
    await alice.sync.sendText(chatId, 'two');
    await until(() async => (await bob.texts(chatId)).length == 2, reason: 'bob catches up');
    expect(await bob.texts(chatId), ['one', 'two']);
    expect((await bob.d.db.chatById(chatId))!.syncedSeq, 2);
  });

  test('a message decrypts later when its key arrives', () async {
    final alice = await start(await backend.addUser('Alice'));
    final bobDevice = await backend.addUser('Bob');
    final chatId = await alice.sync.openDirect(bobDevice.userId);
    backend.deleteWrap(chatId, 1, bobDevice.deviceId);
    final bob = await start(bobDevice);
    await alice.sync.sendText(chatId, 'secret');
    await until(() async => (await bob.rows(chatId)).isNotEmpty);
    expect((await bob.rows(chatId)).single.kind, 'undecryptable');
    await alice.sync.syncAll(); // repairs Bob's missing wrap
    await until(() async => (await bob.texts(chatId)).isNotEmpty, reason: 'bob decrypts after repair');
    expect(await bob.texts(chatId), ['secret']);
    expect((await bob.rows(chatId)).single.envelope, isNull);
  });

  test("a message whose device is not the sender user's is rejected", () async {
    final (alice, bob, carol) = await trio();
    final chatId = await alice.sync.createGroup('G', [bob.d.userId, carol.d.userId]);
    await until(() async => await carol.d.db.key(chatId, 1) != null);
    // Alice's device signs a message, and the server claims Bob sent it.
    const id = '01JM0000000000000000000099';
    final env = await encryptEnvelope(
      chatKey: (await alice.d.db.key(chatId, 1))!,
      epoch: 1,
      chatId: chatId,
      messageId: id,
      senderDeviceId: alice.d.deviceId,
      signKey: alice.d.me.keys.sign,
      plaintext: utf8.encode('{"kind":"text","text":"I am Bob"}'),
    );
    backend.injectMessage(chatId, id: id, senderUserId: bob.d.userId, senderDeviceId: alice.d.deviceId, envelope: env.toJson());
    await until(() async => (await carol.rows(chatId)).isNotEmpty);
    expect((await carol.rows(chatId)).single.kind, 'invalid');
    expect(await carol.texts(chatId), isEmpty);
  });

  test('reaction aggregates and can be removed', () async {
    final (alice, bob, carol) = await trio();
    final chatId = await alice.sync.createGroup('G', [bob.d.userId, carol.d.userId]);
    final target = await alice.sync.sendText(chatId, 'pic');
    await until(() async => (await carol.rows(chatId)).isNotEmpty && (await bob.rows(chatId)).isNotEmpty);
    await bob.sync.react(chatId, target, '👍');
    await carol.sync.react(chatId, target, '👍');
    await until(() async => (await alice.rows(chatId)).length == 3);
    expect(aggregateReactions(await alice.rows(chatId))[target], {'👍': {bob.d.userId, carol.d.userId}});
    await bob.sync.react(chatId, target, '❤️');
    await carol.sync.react(chatId, target, '');
    await until(() async => (await alice.rows(chatId)).length == 5);
    expect(aggregateReactions(await alice.rows(chatId))[target], {'❤️': {bob.d.userId}});
    // Reactions don't count as unread.
    final list = await alice.d.db.watchChatList(alice.d.userId).first;
    expect(list.single.unread, 0);
    expect(list.single.last?.id, target);
  });

  test("read receipt reaches the sender and clears the reader's unread on other devices", () async {
    final alice = await start(await backend.addUser('Alice'));
    final bob = await start(await backend.addUser('Bob'));
    final chatId = await alice.sync.openDirect(bob.d.userId);
    final bob2 = await start(await backend.addDevice(bob.d.userId));
    await alice.sync.syncAll();
    await alice.sync.sendText(chatId, 'read me');
    await until(() async => (await bob.texts(chatId)).isNotEmpty && (await bob2.texts(chatId)).isNotEmpty);
    expect((await bob2.d.db.watchChatList(bob.d.userId).first).single.unread, 1);
    await bob.sync.markRead(chatId);
    await until(() async =>
        (await alice.d.db.membersOf(chatId)).firstWhere((m) => m.userId == bob.d.userId).lastReadSeq == 1);
    await until(() async => (await bob2.d.db.watchChatList(bob.d.userId).first).single.unread == 0);
  });

  test('typing shows, is throttled and expires', () async {
    final alice = await start(await backend.addUser('Alice'));
    final bob = await start(await backend.addUser('Bob'));
    final chatId = await alice.sync.openDirect(bob.d.userId);
    alice.sync.typing(chatId);
    alice.sync.typing(chatId);
    await until(() => bob.sync.typingNow(chatId).contains(alice.d.userId));
    expect(alice.d.hub.sent.where((f) => f['type'] == 'typing'), hasLength(1));
    await until(() => bob.sync.typingNow(chatId).isEmpty, reason: 'typing expires');
  });

  test('presence follows connections', () async {
    final alice = await start(await backend.addUser('Alice'));
    final bob = await start(await backend.addUser('Bob'));
    await until(() => bob.sync.onlineNow.contains(alice.d.userId));
    alice.d.hub.drop();
    await until(() => !bob.sync.onlineNow.contains(alice.d.userId));
    await alice.d.hub.connect();
    await until(() => bob.sync.onlineNow.contains(alice.d.userId));
  });

  test('leave rotates and the rest keep talking', () async {
    final (alice, bob, carol) = await trio();
    final chatId = await alice.sync.createGroup('G', [bob.d.userId, carol.d.userId]);
    await until(() async => await carol.d.db.key(chatId, 1) != null);
    await carol.sync.leave(chatId);
    expect(await carol.d.db.chatById(chatId), isNull);
    await until(() async => backend.chatDto(chatId).epochReady, reason: 'a remaining member creates epoch 2');
    await alice.sync.sendText(chatId, 'after carol');
    await until(() async => (await bob.texts(chatId)).contains('after carol'));
    expect(backend.storedMessages(chatId).last.envelope['epoch'], 2);
    expect(await carol.d.api.wraps(chatId: chatId), isEmpty);
  });

  test('stale_epoch re-encrypts under the new epoch', () async {
    final (alice, bob, carol) = await trio();
    final chatId = await alice.sync.createGroup('G', [bob.d.userId, carol.d.userId]);
    await until(() async => await bob.d.db.key(chatId, 1) != null);
    alice.d.hub.dropEventTypes.addAll(['chat', 'keys']);
    await carol.sync.leave(chatId);
    await until(() async => backend.chatDto(chatId).epochReady, reason: 'bob creates epoch 2');
    expect((await alice.d.db.chatById(chatId))!.currentEpoch, 1);
    final id = await alice.sync.sendText(chatId, 'stale');
    await until(() async => (await alice.d.db.messageById(id))!.state == 'sent', reason: 'resent under epoch 2');
    final stored = backend.storedMessages(chatId).single;
    expect((stored.id, stored.envelope['epoch']), (id, 2));
    await until(() async => (await bob.texts(chatId)).contains('stale'));
  });

  test("removed member's send fails", () async {
    final (alice, bob, carol) = await trio();
    final chatId = await alice.sync.createGroup('G', [bob.d.userId, carol.d.userId]);
    await until(() async => await carol.d.db.key(chatId, 1) != null);
    carol.d.hub.dropEventTypes.addAll(['removed', 'chat', 'keys']);
    await alice.sync.removeMember(chatId, carol.d.userId);
    final id = await carol.sync.sendText(chatId, 'still here?');
    await until(() async => (await carol.d.db.messageById(id))?.state == 'failed' || await carol.d.db.chatById(chatId) == null,
        reason: 'carol learns she was removed');
    expect(backend.storedMessages(chatId).where((m) => m.id == id), isEmpty);
  });

  test('added member reads history', () async {
    final (alice, bob, carol) = await trio();
    final chatId = await alice.sync.createGroup('G', [bob.d.userId]);
    await alice.sync.sendText(chatId, 'one');
    await alice.sync.sendText(chatId, 'two');
    await until(() async => backend.storedMessages(chatId).length == 2);
    await alice.sync.addMembers(chatId, [carol.d.userId]);
    await until(() async => (await carol.texts(chatId)).length == 2, reason: 'carol reads history');
    expect(await carol.texts(chatId), ['one', 'two']);
  });

  test('openDirect twice returns the same chat, from either side', () async {
    final alice = await start(await backend.addUser('Alice'));
    final bob = await start(await backend.addUser('Bob'));
    final a = await alice.sync.openDirect(bob.d.userId);
    expect(await alice.sync.openDirect(bob.d.userId), a);
    expect(await bob.sync.openDirect(alice.d.userId), a);
    expect(() => alice.sync.addMembers(a, [bob.d.userId]), throwsArgumentError);
  });

  test("an identity change gets no keys or trust until acknowledged", () async {
    final alice = await start(await backend.addUser('Alice'));
    final bobOld = await backend.addUser('Bob');
    final chatId = await alice.sync.openDirect(bobOld.userId);
    final bob2 = await start(await backend.resetUser(bobOld.userId));
    await alice.sync.syncAll();
    expect(backend.hasWrap(chatId, 1, bob2.d.deviceId), isFalse, reason: 'no history for an unacknowledged key');
    await alice.sync.acknowledgeIdentity(bobOld.userId);
    await until(() async => backend.hasWrap(chatId, 1, bob2.d.deviceId), reason: 'repair after acknowledging');
  });

  test('a message under an unacknowledged identity waits, then shows once acknowledged', () async {
    final alice = await start(await backend.addUser('Alice'));
    final bobOld = await backend.addUser('Bob');
    final chatId = await alice.sync.openDirect(bobOld.userId);
    final bob2 = await start(await backend.resetUser(bobOld.userId));
    await alice.sync.syncAll(); // sees Bob's new key, not acknowledged
    // As if Bob's key reached his new device some other way (pairing comes in plan 6).
    await bob2.d.db.putKey(chatId, 1, (await alice.d.db.key(chatId, 1))!);
    await bob2.sync.sendText(chatId, 'it is me');
    await until(() async => (await alice.rows(chatId)).isNotEmpty);
    expect((await alice.rows(chatId)).single.kind, 'undecryptable');
    await alice.sync.acknowledgeIdentity(bobOld.userId);
    await until(() async => (await alice.texts(chatId)).contains('it is me'));
  });

  test("old messages from a reset user's previous device still verify", () async {
    final alice = await start(await backend.addUser('Alice'));
    final bob = await start(await backend.addUser('Bob'));
    final chatId = await alice.sync.openDirect(bob.d.userId);
    await until(() async => await bob.d.db.key(chatId, 1) != null);
    alice.d.hub.drop();
    await bob.sync.sendText(chatId, 'before reset');
    await until(() async => backend.storedMessages(chatId).isNotEmpty);
    final bob2 = await backend.resetUser(bob.d.userId);
    addTearDown(bob2.dispose);
    await alice.d.hub.connect();
    await until(() async => (await alice.rows(chatId)).isNotEmpty);
    expect(await alice.texts(chatId), ['before reset']);
  });

  test('a directory failure leaves a message waiting, not invalid', () async {
    final alice = await start(await backend.addUser('Alice'));
    final bob = await start(await backend.addUser('Bob'));
    final chatId = await alice.sync.openDirect(bob.d.userId);
    final bob2 = await start(await backend.addDevice(bob.d.userId));
    await bob.sync.syncAll(); // wraps for bob2
    await until(() async => await bob2.d.db.key(chatId, 1) != null);
    alice.d.api.failNext = const NetworkException('offline');
    await bob2.sync.sendText(chatId, 'new phone');
    await until(() async => (await alice.rows(chatId)).isNotEmpty);
    expect((await alice.rows(chatId)).single.kind, 'undecryptable');
    await alice.sync.syncAll();
    expect(await alice.texts(chatId), ['new phone']);
  });

  test('a read made offline is sent on reconnect', () async {
    final alice = await start(await backend.addUser('Alice'));
    final bob = await start(await backend.addUser('Bob'));
    final chatId = await alice.sync.openDirect(bob.d.userId);
    await alice.sync.sendText(chatId, 'read me later');
    await until(() async => (await bob.texts(chatId)).isNotEmpty);
    bob.d.hub.drop();
    await bob.sync.markRead(chatId);
    await bob.d.hub.connect();
    await until(() async =>
        (await alice.d.db.membersOf(chatId)).firstWhere((m) => m.userId == bob.d.userId).lastReadSeq == 1,
        reason: 'the read reaches Alice');
  });

  test('a failed connect sync still flushes the outbox, then retries', () async {
    final alice = await start(await backend.addUser('Alice'));
    final bob = await start(await backend.addUser('Bob'));
    final chatId = await alice.sync.openDirect(bob.d.userId);
    await pump();
    await alice.sync.idle;
    alice.d.hub.drop();
    await alice.sync.sendText(chatId, 'queued');
    await bob.sync.sendText(chatId, 'while you were out');
    await until(() async => backend.storedMessages(chatId).length == 1);
    alice.d.api.failNext = const NetworkException('blip');
    await alice.d.hub.connect();
    await until(() async => (await bob.texts(chatId)).contains('queued'), reason: 'outbox flushed despite the failed sync');
    await until(() async => (await alice.texts(chatId)).contains('while you were out'), reason: 'sync retried');
  });

  test('a missing key is fetched once per pass, not per message', () async {
    final alice = await start(await backend.addUser('Alice'));
    final bob = await start(await backend.addUser('Bob'));
    final chatId = await alice.sync.openDirect(bob.d.userId);
    for (var i = 0; i < 5; i++) {
      await alice.sync.sendText(chatId, 'm$i');
    }
    await until(() async => backend.storedMessages(chatId).length == 5);
    final bob2 = Node(await backend.addDevice(bob.d.userId)); // no wraps yet, nobody repairs
    nodes.add(bob2);
    backend.calls.clear();
    await bob2.sync.start();
    await until(() async => (await bob2.rows(chatId)).length == 5);
    await bob2.sync.idle;
    expect(backend.calls.where((c) => c == 'GET /keys/wraps').length, lessThanOrEqualTo(3));
  });
}
