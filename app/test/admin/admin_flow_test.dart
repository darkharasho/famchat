// Reset, second admin and recovery code through the real ApiClient and SessionController against
// the fake server, which checks every signature like server/src/routes/{admin,auth}.ts.
import 'package:famchat/admin/admin_service.dart';
import 'package:famchat/api/models.dart';
import 'package:famchat/crypto/encoding.dart';
import 'package:famchat/crypto/reset.dart';
import 'package:famchat/session/invite_link.dart';
import 'package:famchat/session/secure_kv.dart';
import 'package:famchat/session/session_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_server.dart';
import '../support/session_overrides.dart';

void main() {
  late FakeServer server;

  setUp(() => server = FakeServer());

  /// A signed-in device for a new family member (its own container and storage).
  Future<ProviderContainer> member(String name, {bool admin = false}) async {
    final c = ProviderContainer(overrides: sessionOverrides(server, MemorySecureKv()));
    addTearDown(c.dispose);
    await settledSession(c);
    await c.read(sessionProvider.notifier).join(token: server.addInvite(name: name, admin: admin), deviceName: 'Phone');
    return c;
  }

  Future<ProviderContainer> signedOut() async {
    final c = ProviderContainer(overrides: sessionOverrides(server, MemorySecureKv()));
    addTearDown(c.dispose);
    await settledSession(c);
    return c;
  }

  AdminService adminOf(ProviderContainer c) {
    final s = (c.read(sessionProvider) as SignedIn).session;
    return AdminService(api: c.read(apiClientProvider), userId: s.userId, identity: s.identityKey);
  }

  String userIdOf(ProviderContainer c) => (c.read(sessionProvider) as SignedIn).session.userId;

  test('reset link signs the same user in with a new key and a valid claim', () async {
    final admin = await member('Michael', admin: true);
    final mom = await member('Mom');
    final momId = userIdOf(mom);
    final oldKey = server.users[momId]!.identityPub;
    final link = await adminOf(admin).resetUser(momId, currentIdentityPub: oldKey);
    expect(link.url, startsWith('https://famchat.dev/join#'));
    final invite = parseInviteToken(link.url)!;
    final parts = splitInvite(invite);
    expect(parts.claimSeed, hasLength(32));
    expect(server.invites.containsKey(parts.token), isTrue, reason: 'the server only knows the token');
    expect(server.liveDevices(momId), isEmpty, reason: 'old devices signed out at once');

    final momAgain = await signedOut();
    await momAgain.read(sessionProvider.notifier).join(token: invite, deviceName: 'New phone');
    expect(userIdOf(momAgain), momId);
    final record = server.users[momId]!.resets.single;
    expect(record['oldIdentityPub'], oldKey);
    expect(record['newIdentityPub'], server.users[momId]!.identityPub);
    expect(record['newIdentityPub'], isNot(oldKey));
  });

  test('a reset link without its claim part is refused', () async {
    final admin = await member('Michael', admin: true);
    final mom = await member('Mom');
    final link = await adminOf(admin).resetUser(userIdOf(mom), currentIdentityPub: server.users[userIdOf(mom)]!.identityPub);
    final token = splitInvite(parseInviteToken(link.url)!).token;
    final c = await signedOut();
    await expectLater(
      c.read(sessionProvider.notifier).join(token: token, deviceName: 'X'),
      throwsA(isA<ApiException>().having((e) => e.code, 'code', 'invalid_request')),
    );
  });

  test('make admin signs v2 and posts to /families/1/admins/:id', () async {
    final admin = await member('Michael', admin: true);
    final dad = await member('Dad');
    final adminId = userIdOf(admin), dadId = userIdOf(dad);
    await adminOf(admin).makeAdmin(dadId, familyId: 1);
    expect(server.log, contains('POST /api/families/1/admins/$dadId -> 204'));
    final d = server.users[dadId]!;
    expect(d.isAdmin, isTrue);
    expect(d.adminProof!['byUserId'], adminId);
    expect(
      await verifyPromotionV2(
        signerPub: b64urlDecode(server.users[adminId]!.identityPub),
        familyId: 1,
        userId: dadId,
        byUserId: adminId,
        sig: b64urlDecode(d.adminProof!['sig']! as String),
      ),
      isTrue,
    );
  });

  test('make admin in a family the server has no such family for is refused', () async {
    final admin = await member('Michael', admin: true);
    final dad = await member('Dad');
    await expectLater(
      adminOf(admin).makeAdmin(userIdOf(dad), familyId: 2),
      throwsA(isA<ApiException>()),
    );
    expect(server.users[userIdOf(dad)]!.isAdmin, isFalse);
  });

  test('recovery code: saved, then recovers the admin account on a new device once', () async {
    final admin = await member('Michael', admin: true);
    expect((await admin.read(apiClientProvider).me()).recoveryCodeSet, isFalse);
    final code = await adminOf(admin).createRecoveryCode();
    expect((await admin.read(apiClientProvider).me()).recoveryCodeSet, isTrue);
    final adminId = userIdOf(admin);
    final oldKey = server.users[adminId]!.identityPub;

    final fresh = await signedOut();
    await fresh.read(sessionProvider.notifier).recover(code: RecoveryCode.parse(code.display.toLowerCase())!, deviceName: 'Laptop');
    final s = (fresh.read(sessionProvider) as SignedIn).session;
    expect((s.userId, s.isAdmin), (adminId, true));
    final record = server.users[adminId]!.resets.single;
    expect((record['signerKind'], record['oldIdentityPub']), ('recovery', oldKey));
    expect(server.liveDevices(adminId).map((d) => d.id), [s.deviceId]);

    final again = await signedOut();
    await expectLater(
      again.read(sessionProvider.notifier).recover(code: code, deviceName: 'Other'),
      throwsA(isA<ApiException>().having((e) => e.code, 'code', 'unauthorized')),
    );
  });

  test('a wrong recovery code is refused', () async {
    final admin = await member('Michael', admin: true);
    await adminOf(admin).createRecoveryCode();
    final c = await signedOut();
    await expectLater(
      c.read(sessionProvider.notifier).recover(code: newRecoveryCode(), deviceName: 'X'),
      throwsA(isA<ApiException>().having((e) => e.code, 'code', 'unauthorized')),
    );
  });
}
