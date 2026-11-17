import 'package:famchat/chat/directory.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_chat_backend.dart';

void main() {
  late FakeChatBackend backend;
  late TestDevice alice, bob;
  late Directory dir;

  setUp(() async {
    backend = FakeChatBackend();
    alice = await backend.addUser('Alice');
    bob = await backend.addUser('Bob');
    dir = Directory(alice.db, alice.api, alice.me);
  });
  tearDown(() async {
    await alice.dispose();
    await bob.dispose();
  });

  test('first identity is trusted and devices verify', () async {
    await dir.refresh();
    final d = await dir.device(bob.deviceId);
    expect(d, isNotNull);
    expect(d!.userId, bob.userId);
    expect(d.signPub, await bob.me.keys.signPub());
    expect(await dir.identityChanged(bob.userId), isFalse);
    expect((await dir.liveDevices([alice.userId, bob.userId])).map((d) => d.id), unorderedEquals([alice.deviceId, bob.deviceId]));
  });

  test('a former user is stored as former and never pinned as admin', () async {
    backend.setAdmin(bob.userId);
    backend.markFormer(bob.userId);
    await dir.refresh();
    final row = (await alice.db.userById(bob.userId))!;
    expect(row.former, isTrue);
    expect(row.isAdmin, isFalse);
    expect(row.pinnedAdmin, isFalse);
    expect((await alice.db.userById(alice.userId))!.former, isNot(isTrue));
  });

  test('changed identity is flagged until acknowledged', () async {
    await dir.refresh();
    final bob2 = await backend.resetUser(bob.userId);
    addTearDown(bob2.dispose);
    await dir.refresh();
    expect(await dir.identityChanged(bob.userId), isTrue);
    // The new device chains to the new key: it verifies, but gets no keys until the change is acknowledged.
    expect((await dir.device(bob2.deviceId))!.trusted, isFalse);
    expect(await dir.liveDevices([bob.userId]), isEmpty);
    // Bob's old device still verifies against the key first seen (for its old signatures).
    expect((await dir.device(bob.deviceId))!.trusted, isTrue);
    await dir.acknowledgeIdentity(bob.userId);
    expect(await dir.identityChanged(bob.userId), isFalse);
    expect((await dir.liveDevices([bob.userId])).map((d) => d.id), [bob2.deviceId]);
    expect((await dir.device(bob2.deviceId))!.trusted, isTrue);
  });

  test('device with a bad cert is not verified', () async {
    await backend.forgeCert(bob.deviceId);
    await dir.refresh();
    expect(await dir.device(bob.deviceId), isNull);
    expect(await dir.liveDevices([bob.userId]), isEmpty);
  });

  test('my own devices must chain to my local identity key', () async {
    final mine = await backend.addDevice(alice.userId);
    addTearDown(mine.dispose);
    await backend.forgeCert(mine.deviceId);
    await dir.refresh();
    expect(await dir.device(mine.deviceId), isNull);
    expect(await dir.device(alice.deviceId), isNotNull);
  });

  test('an unknown device triggers one refresh', () async {
    await dir.refresh();
    final late = await backend.addDevice(bob.userId);
    addTearDown(late.dispose);
    expect(await dir.device(late.deviceId), isNotNull);
    expect(await dir.device('nope'), isNull);
  });
}
