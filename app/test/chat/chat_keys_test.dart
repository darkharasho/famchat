import 'package:famchat/chat/chat_keys.dart';
import 'package:famchat/chat/directory.dart';
import 'package:famchat/chat/ulid.dart';
import 'package:famchat/crypto/keys.dart';
import 'package:famchat/crypto/wrap.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_chat_backend.dart';

class Peer {
  Peer(this.d) : dir = Directory(d.db, d.api, d.me) {
    keys = ChatKeys(db: d.db, api: d.api, directory: dir, me: d.me);
  }
  final TestDevice d;
  final Directory dir;
  late final ChatKeys keys;

  Future<void> syncChats() async {
    for (final c in await d.api.chats()) {
      await d.db.upsertChat(c);
    }
  }
}

void main() {
  late FakeChatBackend backend;
  late Peer alice, bob, carol;

  setUp(() async {
    backend = FakeChatBackend();
    alice = Peer(await backend.addUser('Alice'));
    bob = Peer(await backend.addUser('Bob'));
    carol = Peer(await backend.addUser('Carol'));
    for (final p in [alice, bob, carol]) {
      await p.dir.refresh();
    }
  });
  tearDown(() async {
    for (final p in [alice, bob, carol]) {
      await p.d.dispose();
    }
  });

  /// Alice creates a group with Bob (and Carol) using ChatKeys' wraps.
  Future<String> group({bool withCarol = true}) async {
    final id = newUlid();
    final key = newChatKey();
    final members = [alice.d.userId, bob.d.userId, if (withCarol) carol.d.userId];
    final wraps = await alice.keys.wrapKey(chatId: id, epoch: 1, key: key, devices: await alice.dir.liveDevices(members));
    final r = await alice.d.api.createChat(id: id, kind: 'group', title: 'G', userIds: members.sublist(1), wraps: wraps);
    await alice.d.db.putKey(id, 1, key);
    await alice.d.db.upsertChat(r.chat);
    return id;
  }

  test('creator wraps for every member device and the other member unwraps', () async {
    final id = await group();
    await bob.syncChats();
    expect(await bob.keys.fetch(), 1);
    expect(await bob.keys.key(id, 1), await alice.keys.key(id, 1));
  });

  test('wrap from a non-member is rejected', () async {
    final id = await group(withCarol: false);
    await bob.syncChats();
    // Carol (not a member) wraps a key of her own for Bob, and the server stores it.
    final forged = await wrapChatKey(
      chatId: id,
      epoch: 1,
      recipientDeviceId: bob.d.deviceId,
      recipientEncPub: await bob.d.me.keys.encPub(),
      wrapperDeviceId: carol.d.deviceId,
      wrapperSignKey: carol.d.me.keys.sign,
      chatKey: newChatKey(),
    );
    backend.injectWrap(forged);
    expect(await bob.keys.fetch(), 0);
    expect(await bob.keys.key(id, 1), isNull);
  });

  test('wrap with a cert that does not chain is rejected', () async {
    final id = await group();
    await backend.forgeCert(alice.d.deviceId);
    await bob.dir.refresh();
    await bob.syncChats();
    expect(await bob.keys.fetch(), 0);
    expect(await bob.keys.key(id, 1), isNull);
  });

  test('wrap moved to another device fails', () async {
    final id = await group();
    final mine = (await bob.d.api.wraps()).single;
    backend.injectWrap(ChatKeyWrap(
      chatId: id,
      epoch: 1,
      recipientDeviceId: carol.d.deviceId,
      wrapperDeviceId: mine.wrapperDeviceId,
      sealed: mine.sealed,
      sig: mine.sig,
    ));
    await carol.syncChats();
    expect(await carol.keys.fetch(), 0);
  });

  test('ensureCurrentEpoch after a leave creates epoch 2 once', () async {
    final id = await group();
    await bob.syncChats();
    await bob.keys.fetch();
    await carol.d.api.removeMember(id, carol.d.userId);
    await alice.syncChats();
    await bob.syncChats();
    final results = await Future.wait([alice.keys.ensureCurrentEpoch(id), bob.keys.ensureCurrentEpoch(id)]);
    expect(results, [true, true]);
    final k = await alice.keys.key(id, 2);
    expect(k, isNotNull);
    expect(await bob.keys.key(id, 2), k);
    expect(backend.chatDto(id).epochReady, isTrue);
    expect(backend.hasWrap(id, 2, carol.d.deviceId), isFalse);
    // Carol can no longer fetch keys for the chat.
    expect(await carol.d.api.wraps(chatId: id), isEmpty);
  });

  test('ensureCurrentEpoch is true when the key is held, and fetches when ready but missing', () async {
    final id = await group();
    expect(await alice.keys.ensureCurrentEpoch(id), isTrue);
    await bob.syncChats();
    expect(await bob.keys.ensureCurrentEpoch(id), isTrue);
    expect(await bob.keys.key(id, 1), isNotNull);
  });

  test('repair adds wraps for a member\'s new device', () async {
    final id = await group();
    final bob2 = Peer(await backend.addDevice(bob.d.userId));
    addTearDown(bob2.d.dispose);
    await alice.dir.refresh();
    expect(await alice.keys.repairMissing(), 1);
    await bob2.dir.refresh();
    await bob2.syncChats();
    expect(await bob2.keys.fetch(), 1);
    expect(await bob2.keys.key(id, 1), await alice.keys.key(id, 1));
    expect(await alice.keys.repairMissing(), 0);
  });

  test('repair skips devices with a bad cert', () async {
    await group();
    final bob2 = await backend.addDevice(bob.d.userId);
    addTearDown(bob2.dispose);
    await backend.forgeCert(bob2.deviceId);
    await alice.dir.refresh();
    expect(await alice.keys.repairMissing(), 0);
  });

  test('wrapsForNewDevices covers every held epoch', () async {
    final id = await group(withCarol: false);
    await alice.d.db.putKey(id, 2, newChatKey());
    final wraps = await alice.keys.wrapsForNewDevices(id, [carol.d.userId]);
    expect(wraps.map((w) => (w.epoch, w.recipientDeviceId)), unorderedEquals([(1, carol.d.deviceId), (2, carol.d.deviceId)]));
  });
}
