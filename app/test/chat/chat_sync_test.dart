import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:famchat/api/models.dart';
import 'package:famchat/chat/chat_sync.dart';
import 'package:famchat/chat/db/chat_db.dart';
import 'package:famchat/chat/message_changes.dart';
import 'package:famchat/chat/plaintext.dart';
import 'package:famchat/chat/reactions.dart';
import 'package:famchat/chat/wire.dart';
import 'package:famchat/crypto/envelope.dart';
import 'package:famchat/pairing/bundle.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_chat_backend.dart';

class Node {
  Node(this.d, {void Function()? onFamiliesChanged})
      : sync = ChatSync(
          db: d.db,
          api: d.api,
          hub: d.hub,
          me: d.me,
          onFamiliesChanged: onFamiliesChanged,
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

  Future<Node> start(TestDevice d, {void Function()? onFamiliesChanged}) async {
    final n = Node(d, onFamiliesChanged: onFamiliesChanged);
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

  test('a message sent during a slow reconnect catch-up goes out without waiting for it', () async {
    final (alice, bob, carol) = await trio();
    final slow = await alice.sync.openDirect(carol.d.userId);
    final chatId = await alice.sync.openDirect(bob.d.userId);
    await pump();
    await alice.sync.idle;
    alice.d.hub.drop();
    final hold = Completer<void>();
    alice.d.api.holds['GET /chats/$slow/messages'] = hold;
    await alice.d.hub.connect();
    final id = await alice.sync.sendText(chatId, 'now');
    await until(() async => backend.storedMessages(chatId).isNotEmpty, reason: 'the send reaches the hub');
    // The ack counts too: the row stops "sending" (and the app may go to sleep) before the
    // catch-up is done.
    await until(() async => (await alice.d.db.messageById(id))!.state == 'sent', reason: 'the ack, during the catch-up');
    expect(await alice.sync.hasUnsent(), isFalse);
    hold.complete();
    await until(() async => (await bob.texts(chatId)).contains('now'));
  });

  test('hasUnsent is true from send until the ack', () async {
    final alice = await start(await backend.addUser('Alice'));
    final bob = await start(await backend.addUser('Bob'));
    final chatId = await alice.sync.openDirect(bob.d.userId);
    await alice.sync.idle;
    expect(await alice.sync.hasUnsent(), isFalse);
    alice.d.hub.drop();
    final id = await alice.sync.sendText(chatId, 'wait');
    expect(await alice.sync.hasUnsent(), isTrue);
    await alice.d.hub.connect();
    await until(() async => (await alice.d.db.messageById(id))!.state == 'sent');
    expect(await alice.sync.hasUnsent(), isFalse);
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

  test('replies, edits and deletes reach the others, silently, and only the sender can change a message', () async {
    final (alice, bob, carol) = await trio();
    final chatId = await alice.sync.createGroup('G', [bob.d.userId, carol.d.userId]);
    final hi = await alice.sync.sendText(chatId, 'hi');
    await until(() async => (await bob.rows(chatId)).isNotEmpty);
    final reply = await bob.sync.sendText(chatId, 'hey', replyTo: hi);
    await until(() async => (await carol.rows(chatId)).length == 2);
    expect(replyTargetOf((await carol.d.db.messageById(reply))!), hi);

    await alice.sync.editText(chatId, hi, 'hello');
    await bob.sync.editText(chatId, hi, 'bob was here'); // not his: ignored by everyone
    await until(() async => (await carol.rows(chatId)).length == 4);
    var changes = messageChanges(await carol.rows(chatId));
    expect(changes.textOf((await carol.d.db.messageById(hi))!), 'hello');

    await alice.sync.deleteMessage(chatId, hi);
    await until(() async => (await carol.rows(chatId)).length == 5);
    changes = messageChanges(await carol.rows(chatId));
    expect(changes.isDeleted(hi), isTrue);

    // Only the two texts notify; the edits and the delete were sent silent.
    expect(backend.silentIds, hasLength(3));
    // Changes and deleted messages aren't unread, and the list shows the latest real message.
    final list = await carol.d.db.watchChatList(carol.d.userId).first;
    expect(list.single.unread, 1);
    expect(list.single.last?.id, reply);
  });

  test('a text with mentions carries them in the send frame and the plaintext', () async {
    final (alice, bob, carol) = await trio();
    final chatId = await alice.sync.createGroup('G', [bob.d.userId, carol.d.userId]);
    final id = await alice.sync.sendText(chatId, '@Bob look', mentions: [bob.d.userId]);
    await until(() async => (await carol.rows(chatId)).isNotEmpty);
    expect(backend.sentMentions[id], [bob.d.userId]);
    final row = (await carol.d.db.messageById(id))!;
    expect((Plaintext.decode(utf8.encode(row.body!)) as TextBody).mentions, [bob.d.userId]);
    final plain = await alice.sync.sendText(chatId, 'no one');
    await until(() async => (await carol.rows(chatId)).length == 2);
    expect(backend.sentMentions.containsKey(plain), isFalse);
  });

  test("a profile event brings in someone's new photo key, and its removal", () async {
    final alice = await start(await backend.addUser('Alice'));
    final bob = await start(await backend.addUser('Bob'));
    await alice.sync.openDirect(bob.d.userId);
    await alice.sync.idle;
    final key = backend.setAvatar(bob.d.userId, Uint8List.fromList([1, 2, 3]));
    await until(() async => (await alice.d.db.userById(bob.d.userId))?.avatarKey == key, reason: 'new key');
    backend.setAvatar(bob.d.userId, null);
    await until(() async => (await alice.d.db.userById(bob.d.userId))?.avatarKey == null, reason: 'removed');
  });

  test("a group's family id is stored; a direct chat has none", () async {
    final alice = await start(await backend.addUser('Alice'));
    final bob = await start(await backend.addUser('Bob'));
    final direct = await alice.sync.openDirect(bob.d.userId);
    final group = await alice.sync.createGroup('Us', [bob.d.userId]);
    await alice.sync.idle;
    expect((await alice.d.db.chatById(group))!.familyId, 1);
    expect((await alice.d.db.chatById(direct))!.familyId, isNull);
    await until(() async => (await bob.d.db.chatById(group))?.familyId == 1, reason: 'bob stores it');
    backend.setChatFamily(group, 2);
    await until(() async => (await bob.d.db.chatById(group))?.familyId == 2, reason: 'bob follows the server');
  });

  test('a family event refreshes the directory and the families', () async {
    var familiesChanged = 0;
    final alice = await start(await backend.addUser('Alice'), onFamiliesChanged: () => familiesChanged++);
    final bob = await backend.addUser('Bob');
    addTearDown(bob.dispose);
    await alice.sync.idle;
    final before = familiesChanged; // start() already reports the first connect
    backend.addFamilyRole(alice.d.userId, const FamilyRoleDto(id: 2, admin: false));
    backend.addFamilyRole(bob.userId, const FamilyRoleDto(id: 2, admin: true));
    backend.familyEvent([alice.d.userId], 2);
    await until(() async => familiesChanged > before, reason: 'families callback');
    await alice.sync.idle;
    expect(jsonDecode((await alice.d.db.userById(bob.userId))!.familyIds), [1, 2]);
  });

  test('a family change missed while offline refreshes the families after the reconnect', () async {
    var familiesChanged = 0;
    final alice = await start(await backend.addUser('Alice'), onFamiliesChanged: () => familiesChanged++);
    final before = familiesChanged;
    alice.d.hub.drop();
    backend.addFamilyRole(alice.d.userId, const FamilyRoleDto(id: 2, admin: true));
    backend.familyEvent([alice.d.userId], 2); // nobody connected: lost
    await alice.d.hub.connect();
    await until(() async => familiesChanged > before, reason: 'families callback after the reconnect');
    await alice.sync.idle;
    expect(jsonDecode((await alice.d.db.userById(alice.d.userId))!.familyIds), [1, 2]);
  });

  test('deleting a message whose ack was lost still deletes it for everyone', () async {
    final alice = await start(await backend.addUser('Alice'));
    final bob = await start(await backend.addUser('Bob'));
    final chatId = await alice.sync.openDirect(bob.d.userId);
    await pump();
    await alice.sync.idle;
    alice.d.hub.dropNextAck = true; // stored on the server, then the socket drops before the ack
    final id = await alice.sync.sendText(chatId, 'oops');
    await until(() async => !alice.d.hub.connected);
    await until(() async => (await bob.rows(chatId)).isNotEmpty, reason: 'bob got it');
    await alice.sync.deleteMessage(chatId, id);
    await alice.d.hub.connect();
    await until(() async => messageChanges(await bob.rows(chatId)).isDeleted(id), reason: 'bob sees it deleted');
    await alice.sync.idle;
    expect(messageChanges(await alice.rows(chatId)).isDeleted(id), isTrue);
  });

  test('deleting a message that never left this device just drops it', () async {
    final alice = await start(await backend.addUser('Alice'));
    final bob = await start(await backend.addUser('Bob'));
    final chatId = await alice.sync.openDirect(bob.d.userId);
    alice.d.hub.drop();
    final id = await alice.sync.sendText(chatId, 'never mind');
    await alice.sync.deleteMessage(chatId, id);
    expect(await alice.rows(chatId), isEmpty);
    await alice.d.hub.connect();
    await alice.sync.idle;
    expect(backend.storedMessages(chatId), isEmpty);
  });

  test('reactions are sent silent', () async {
    final alice = await start(await backend.addUser('Alice'));
    final bob = await start(await backend.addUser('Bob'));
    final chatId = await alice.sync.openDirect(bob.d.userId);
    final id = await alice.sync.sendText(chatId, 'x');
    await until(() async => (await bob.rows(chatId)).isNotEmpty);
    await bob.sync.react(chatId, id, '👍');
    await until(() async => (await alice.rows(chatId)).length == 2);
    expect(backend.silentIds, hasLength(1));
  });

  test("muting is per user and reaches the user's other devices", () async {
    final alice = await start(await backend.addUser('Alice'));
    final bob = await start(await backend.addUser('Bob'));
    final chatId = await alice.sync.openDirect(bob.d.userId);
    final alice2 = await start(await backend.addDevice(alice.d.userId));
    await until(() async => await alice2.d.db.chatById(chatId) != null);
    await alice.sync.mute(chatId, 4102444800000);
    expect((await alice.d.db.chatById(chatId))!.mutedUntil, 4102444800000);
    await until(() async => (await alice2.d.db.chatById(chatId))!.mutedUntil == 4102444800000, reason: 'other device');
    await bob.sync.syncAll();
    expect((await bob.d.db.chatById(chatId))!.mutedUntil, isNull);
    await alice.sync.mute(chatId, null);
    expect((await alice.d.db.chatById(chatId))!.mutedUntil, isNull);
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

  test('flushes while a stale_epoch is being handled do not resend it under the old epoch', () async {
    final (alice, bob, carol) = await trio();
    final chatId = await alice.sync.createGroup('G', [bob.d.userId, carol.d.userId]);
    await until(() async => await bob.d.db.key(chatId, 1) != null);
    alice.d.hub.dropEventTypes.addAll(['chat', 'keys']);
    await carol.sync.leave(chatId);
    await until(() async => backend.chatDto(chatId).epochReady, reason: 'bob creates epoch 2');
    final hold = Completer<void>();
    alice.d.api.holds['GET /chats/$chatId'] = hold;
    final id = await alice.sync.sendText(chatId, 'stale');
    await until(() => backend.calls.contains('GET /chats/$chatId'), reason: 'the stale_epoch refresh');
    // Uploads finishing, other sends: each flushes the outbox meanwhile.
    for (var i = 0; i < ChatSync.maxStaleRetries + 1; i++) {
      alice.sync.flushSoon();
      await pump();
    }
    hold.complete();
    await until(() async => (await alice.d.db.messageById(id))!.state != 'pending', reason: 'resent under epoch 2');
    expect((await alice.d.db.messageById(id))!.state, 'sent');
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

  test('no_shared_family fails the send and refreshes the directory', () async {
    final alice = await start(await backend.addUser('Alice'));
    final bob = await start(await backend.addUser('Bob'));
    final chatId = await alice.sync.openDirect(bob.d.userId);
    backend.markFormer(bob.d.userId);
    final before = backend.calls.where((c) => c == 'GET /users').length;
    final id = await alice.sync.sendText(chatId, 'anyone?');
    await until(() async => (await alice.d.db.messageById(id))?.state == 'failed', reason: 'the send fails');
    await until(() => backend.calls.where((c) => c == 'GET /users').length > before, reason: 'directory refreshed');
    expect((await alice.d.db.userById(bob.d.userId))?.former, isTrue);
    expect(backend.storedMessages(chatId), isEmpty);
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

  test('device event repairs wraps right away', () async {
    final alice = await start(await backend.addUser('Alice'));
    final bob = await start(await backend.addUser('Bob'));
    final chatId = await alice.sync.openDirect(bob.d.userId);
    await until(() async => await bob.d.db.key(chatId, 1) != null);
    final callsBefore = backend.calls.length;
    final laptop = await backend.pairDevice(alice.d.userId); // not started: only online members can repair
    await until(() async => backend.hasWrap(chatId, 1, laptop.deviceId), reason: 'a member adds the wrap');
    expect(backend.calls.sublist(callsBefore), contains('PUT /keys/wraps'));
    await laptop.dispose();
  });

  test('revoking a device rotates and the revoked device gets no new key', () async {
    final alice = await start(await backend.addUser('Alice'));
    final bob = await start(await backend.addUser('Bob'));
    final laptop = await start(await backend.addDevice(alice.d.userId));
    final chatId = await alice.sync.openDirect(bob.d.userId);
    await until(() async => await laptop.d.db.key(chatId, 1) != null);
    backend.revoke(laptop.d.deviceId);
    await until(() async => backend.chatDto(chatId).epochReady, reason: 'a member creates epoch 2');
    expect(backend.chatDto(chatId).currentEpoch, 2);
    expect(backend.hasWrap(chatId, 2, laptop.d.deviceId), isFalse);
    await bob.sync.sendText(chatId, 'after revoke');
    await until(() async => (await alice.texts(chatId)).contains('after revoke'));
    expect(backend.storedMessages(chatId).last.envelope['epoch'], 2);
  });

  test('paired device reads history from the handover', () async {
    final alice = await start(await backend.addUser('Alice'));
    final bob = await start(await backend.addUser('Bob'));
    final carol = await start(await backend.addUser('Carol'));
    final direct = await alice.sync.openDirect(bob.d.userId);
    final group = await alice.sync.createGroup('G', [bob.d.userId, carol.d.userId]);
    await alice.sync.sendText(direct, 'one');
    await until(() async => await bob.d.db.key(group, 1) != null);
    await bob.sync.sendText(group, 'two');
    await until(() async => (await alice.texts(group)).contains('two'), reason: 'alice gets two');
    await carol.sync.leave(group); // epoch 2 in the group
    await until(() async => backend.chatDto(group).epochReady, reason: 'epoch 2');
    await alice.sync.sendText(group, 'three');
    await until(() async => backend.storedMessages(group).length == 2, reason: 'three stored');

    // Bob is offline: only the handover can give the new device its keys at first.
    await bob.sync.stop();
    final laptopDevice = await backend.pairDevice(alice.d.userId, notify: false);
    final bundle = await buildHandover(
      db: alice.d.db,
      userId: alice.d.userId,
      deviceId: laptopDevice.deviceId,
      identity: backend.identityOf(alice.d.userId),
      encPub: await laptopDevice.me.keys.encPub(),
      signPub: await laptopDevice.me.keys.signPub(),
    );
    await installHandover(laptopDevice.db, bundle);
    alice.d.hub.drop(); // and Alice's phone too
    final laptop = await start(laptopDevice);
    expect(await laptop.texts(direct), ['one']);
    expect(await laptop.texts(group), ['two', 'three']);
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

  group('admin reset', () {
    Future<(Node, Node, String)> setup() async {
      final aliceDevice = await backend.addUser('Alice');
      backend.setAdmin(aliceDevice.userId); // the bootstrapped admin
      final alice = await start(aliceDevice);
      final bob = await start(await backend.addUser('Bob'));
      final chatId = await alice.sync.openDirect(bob.d.userId);
      await until(() async => await bob.d.db.key(chatId, 1) != null);
      await bob.sync.sendText(chatId, 'before reset');
      await until(() async => (await alice.texts(chatId)).contains('before reset'));
      return (alice, bob, chatId);
    }

    test('verified reset is acknowledged and history flows to the new device', () async {
      final (alice, bob, chatId) = await setup();
      final resetId = await backend.adminReset(bob.d.userId, by: alice.d.userId);
      await until(() async => (await alice.d.db.allResets()).isNotEmpty, reason: 'banner recorded');
      final bob2 = await start(await backend.claimReset(bob.d.userId, resetId));
      await until(() async => backend.hasWrap(chatId, 1, bob2.d.deviceId), reason: 'alice re-wraps the history');
      expect(await alice.sync.directory.identityChanged(bob.d.userId), isFalse, reason: 'no manual banner');
      await until(() async => (await bob2.texts(chatId)).contains('before reset'), reason: 'history on the new device');
      await bob2.sync.sendText(chatId, 'after reset');
      await until(() async => (await alice.texts(chatId)).contains('after reset'));
      final r = (await alice.d.db.allResets()).single;
      expect((r.id, r.userId, r.signerUserId, r.signerKind), (resetId, bob.d.userId, alice.d.userId, 'admin'));
    });

    test('historical key lets a later device verify old messages', () async {
      final (alice, bob, chatId) = await setup();
      final resetId = await backend.adminReset(bob.d.userId, by: alice.d.userId);
      final bob2 = await start(await backend.claimReset(bob.d.userId, resetId));
      await until(() async => (await bob2.texts(chatId)).contains('before reset'), reason: "bob's own old message verifies");
      expect((await bob2.rows(chatId)).where((r) => r.kind == 'invalid'), isEmpty);
      expect(await bob2.d.db.allResets(), isEmpty, reason: 'no banner for my own reset');
      expect(alice, isNotNull);
    });

    test('a pending reset shows the banner and signs the old device out locally', () async {
      final (alice, bob, _) = await setup();
      await backend.adminReset(bob.d.userId, by: alice.d.userId);
      await until(() async => (await alice.d.db.allResets()).isNotEmpty);
      expect((await alice.d.db.deviceById(bob.d.deviceId))!.revoked, isTrue);
    });

    test('a reset signed by a non-admin is not trusted', () async {
      final (alice, bob, chatId) = await setup();
      final carol = await backend.addUser('Carol');
      addTearDown(carol.dispose);
      final resetId = await backend.adminReset(bob.d.userId, by: carol.userId);
      final bob2 = await start(await backend.claimReset(bob.d.userId, resetId));
      await alice.sync.syncAll();
      expect(await alice.sync.directory.identityChanged(bob.d.userId), isTrue, reason: 'manual banner stays');
      expect(backend.hasWrap(chatId, 1, bob2.d.deviceId), isFalse);
      expect(await alice.d.db.allResets(), isEmpty);
    });

    test("an admin the server names later, with no signed promotion, can't reset anyone", () async {
      final (alice, bob, chatId) = await setup();
      final carol = await backend.addUser('Carol');
      addTearDown(carol.dispose);
      backend.setAdmin(carol.userId);
      final resetId = await backend.adminReset(bob.d.userId, by: carol.userId);
      final bob2 = await start(await backend.claimReset(bob.d.userId, resetId));
      await alice.sync.syncAll();
      expect(await alice.sync.directory.identityChanged(bob.d.userId), isTrue);
      expect(backend.hasWrap(chatId, 1, bob2.d.deviceId), isFalse);
      expect(await alice.d.db.allResets(), isEmpty);
    });

    test('a second admin promoted with a signature can reset', () async {
      final (alice, bob, chatId) = await setup();
      final carol = await backend.addUser('Carol');
      addTearDown(carol.dispose);
      await backend.promote(carol.userId, by: alice.d.userId);
      final resetId = await backend.adminReset(bob.d.userId, by: carol.userId);
      final bob2 = await start(await backend.claimReset(bob.d.userId, resetId));
      await until(() async => backend.hasWrap(chatId, 1, bob2.d.deviceId), reason: 'alice re-wraps the history');
      expect(await alice.sync.directory.identityChanged(bob.d.userId), isFalse);
    });

    test('completed reset with a bad claim is not acknowledged', () async {
      final (alice, bob, chatId) = await setup();
      final resetId = await backend.adminReset(bob.d.userId, by: alice.d.userId);
      final bob2 = await start(await backend.claimReset(bob.d.userId, resetId, badClaim: true));
      await alice.sync.syncAll();
      expect(await alice.sync.directory.identityChanged(bob.d.userId), isTrue);
      expect(backend.hasWrap(chatId, 1, bob2.d.deviceId), isFalse);
    });
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

  test('messages an older version stored as unknown are shown once this version knows the kind', () async {
    final d = await backend.addUser('Alice');
    MessageRow unknown(String id, Map<String, Object?> body) => MessageRow(
          id: id,
          chatId: 'C',
          seq: 1,
          senderUserId: 'U',
          senderDeviceId: 'D',
          kind: 'unknown',
          body: jsonEncode(body),
          targetId: null,
          envelope: null,
          createdAt: 1,
          state: 'sent',
        );
    final voice = {
      'kind': 'voice',
      'mediaKey': '01JC0000000000000000000000',
      'key': 'AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE',
      'sha256': 'AgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgI',
      'durationMs': 1200,
      'waveform': '',
      'bytes': 100,
      'mime': 'audio/mp4',
    };
    await d.db.bindDevice(d.deviceId);
    await d.db.insertMessageIfAbsent(unknown('M1', voice));
    await d.db.insertMessageIfAbsent(unknown('M2', {'kind': 'sticker', 'id': 7}));
    await d.db.insertMessageIfAbsent(unknown('M3', {...voice, 'durationMs': -1}));
    await start(d);
    expect((await d.db.messageById('M1'))!.kind, 'voice');
    expect((await d.db.messageById('M2'))!.kind, 'unknown');
    expect((await d.db.messageById('M3'))!.kind, 'invalid');
  });
}
