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

  test('changed identity is flagged until acknowledged', () async {
    await dir.refresh();
    final bob2 = await backend.resetUser(bob.userId);
    addTearDown(bob2.dispose);
    await dir.refresh();
    expect(await dir.identityChanged(bob.userId), isTrue);
    // The new device chains to the new key: accepted (an admin reset is legitimate), but flagged.
    expect(await dir.device(bob2.deviceId), isNotNull);
    expect((await dir.liveDevices([bob.userId])).map((d) => d.id), [bob2.deviceId]);
    await dir.acknowledgeIdentity(bob.userId);
    expect(await dir.identityChanged(bob.userId), isFalse);
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
