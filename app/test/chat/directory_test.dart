import 'package:famchat/chat/directory.dart';
import 'package:famchat/chat/wire.dart';
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

  test("after first sight, a family-2 admin the server lists with no proof can't make a reset count", () async {
    // Family 2 (Alice and Bob, no admins yet) is seen once.
    backend.addFamilyRole(alice.userId, const FamilyRoleDto(id: 2, admin: false));
    backend.addFamilyRole(bob.userId, const FamilyRoleDto(id: 2, admin: false));
    await dir.refresh();
    expect((await alice.db.familyPins())[2], isEmpty);
    final x = await backend.addUser('X');
    addTearDown(x.dispose);
    // A hostile server: X joins family 2 as its (unproven) admin, and resets Bob.
    backend.addFamilyRole(x.userId, const FamilyRoleDto(id: 2, admin: true));
    final resetId = await backend.adminReset(bob.userId, by: x.userId);
    final bob2 = await backend.claimReset(bob.userId, resetId);
    addTearDown(bob2.dispose);
    expect(await dir.refresh(), isEmpty);
    expect(await dir.identityChanged(bob.userId), isTrue, reason: 'manual banner, not silently accepted');
    expect((await alice.db.userById(x.userId))!.pinnedAdmin, isFalse);
    expect(await alice.db.allResets(), isEmpty);
    // Listing X as a family-1 admin too (no proof) doesn't help.
    backend.setAdmin(x.userId);
    expect(await dir.refresh(), isEmpty);
    expect(await dir.identityChanged(bob.userId), isTrue);
    expect((await alice.db.userById(x.userId))!.pinnedAdmin, isFalse);
    // A family Alice sees for the first time is trusted on first use, but only for itself: its
    // admin X gets no say in families 1 and 2, where Bob is.
    backend.addFamilyRole(alice.userId, const FamilyRoleDto(id: 3, admin: false));
    backend.addFamilyRole(x.userId, const FamilyRoleDto(id: 3, admin: true));
    expect(await dir.refresh(), isEmpty);
    expect(await alice.db.familyPins(), {
      1: <String>{},
      2: <String>{},
      3: {x.userId},
    });
    expect(await dir.identityChanged(bob.userId), isTrue);
    expect(await alice.db.allResets(), isEmpty);
  });

  test('two families: pins stay separate and an admin resets only their own family', () async {
    final carol = await backend.addUser('Carol'), dave = await backend.addUser('Dave'), erin = await backend.addUser('Erin');
    addTearDown(carol.dispose);
    addTearDown(dave.dispose);
    addTearDown(erin.dispose);
    // Family 1: Alice, Bob (admin), Dave, Erin. Family 2: Alice, Carol (admin), Dave.
    backend.setAdmin(bob.userId);
    backend.removeFamilyRole(carol.userId, 1);
    for (final u in [alice, dave]) {
      backend.addFamilyRole(u.userId, const FamilyRoleDto(id: 2, admin: false));
    }
    backend.addFamilyRole(carol.userId, const FamilyRoleDto(id: 2, admin: true));
    await dir.refresh();
    expect(await alice.db.familyPins(), {
      1: {bob.userId},
      2: {carol.userId},
    });
    expect((await alice.db.userById(bob.userId))!.pinnedAdmin, isTrue);
    expect((await alice.db.userById(carol.userId))!.pinnedAdmin, isTrue);

    // Carol resets Dave (family 2) and Erin (family 1 only).
    final daveReset = await backend.adminReset(dave.userId, by: carol.userId);
    final erinReset = await backend.adminReset(erin.userId, by: carol.userId);
    final dave2 = await backend.claimReset(dave.userId, daveReset);
    final erin2 = await backend.claimReset(erin.userId, erinReset);
    addTearDown(dave2.dispose);
    addTearDown(erin2.dispose);
    expect(await dir.refresh(), {dave.userId});
    expect(await dir.identityChanged(dave.userId), isFalse);
    expect(await dir.identityChanged(erin.userId), isTrue, reason: "Carol isn't an admin of Erin's family");
    expect((await alice.db.allResets()).map((r) => r.userId), [dave.userId]);
    expect(await alice.db.familyPins(), {
      1: {bob.userId},
      2: {carol.userId},
    });
  });

  test('upgraded device keeps its admins and shows no new banner', () async {
    final carol = await backend.addUser('Carol'), x = await backend.addUser('X');
    addTearDown(carol.dispose);
    addTearDown(x.dispose);
    backend.setAdmin(bob.userId);
    final witnessed = await backend.adminReset(carol.userId, by: bob.userId);
    // What a schema-7 device that had pinned Bob and seen his reset of Carol holds after the
    // upgrade (the conversion itself: chat_db_migration_test.dart).
    await alice.db.replaceFamilyPins({
      1: {bob.userId},
    });
    await alice.db.recordReset(id: witnessed, userId: carol.userId, signerUserId: bob.userId, signerKind: 'admin', createdAt: 1);
    // The server now also lists X as an admin, with no proof, and X resets Bob.
    backend.setAdmin(x.userId);
    await backend.adminReset(bob.userId, by: x.userId);
    await dir.refresh();
    expect((await alice.db.allResets()).map((r) => r.id), [witnessed]);
    expect(await alice.db.familyPins(), {
      1: {bob.userId},
    });
    expect((await alice.db.userById(bob.userId))!.pinnedAdmin, isTrue);
    expect((await alice.db.userById(x.userId))!.pinnedAdmin, isFalse);
  });

  test('leaving a family drops its pins', () async {
    backend.addFamilyRole(alice.userId, const FamilyRoleDto(id: 2, admin: false));
    backend.addFamilyRole(bob.userId, const FamilyRoleDto(id: 2, admin: true));
    await dir.refresh();
    expect((await alice.db.familyPins())[2], {bob.userId});
    backend.removeFamilyRole(alice.userId, 2);
    await dir.refresh();
    expect((await alice.db.familyPins()).keys, [1]);
    expect((await alice.db.userById(bob.userId))!.pinnedAdmin, isFalse);
  });

  test('a demoted admin is unpinned', () async {
    backend.setAdmin(bob.userId);
    await dir.refresh();
    expect((await alice.db.familyPins())[1], {bob.userId});
    backend.setAdmin(bob.userId, false);
    await dir.refresh();
    expect((await alice.db.familyPins())[1], isEmpty);
    expect((await alice.db.userById(bob.userId))!.pinnedAdmin, isFalse);
    // Listed again with no proof: still not trusted.
    backend.setAdmin(bob.userId);
    await dir.refresh();
    expect((await alice.db.familyPins())[1], isEmpty);
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
