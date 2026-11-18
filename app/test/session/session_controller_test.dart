import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:famchat/api/models.dart';
import 'package:famchat/chat/db/chat_db.dart';
import 'package:famchat/chat/providers.dart';
import 'package:famchat/crypto/encoding.dart';
import 'package:famchat/platform_info.dart';
import 'package:famchat/session/secure_kv.dart';
import 'package:famchat/session/session_controller.dart';
import 'package:famchat/session/stored_session.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:famchat/push/preview_keyring.dart';
import 'package:famchat/push/preview_setting.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import '../support/fake_server.dart';
import '../support/session_overrides.dart';

class ThrowingKv implements SecureKv {
  @override
  Future<String?> read(String key) async => throw PlatformException(code: 'libsecret', message: 'no keyring');
  @override
  Future<void> write(String key, String value) async => throw PlatformException(code: 'libsecret');
  @override
  Future<void> delete(String key) async {}
}

class HangingKv implements SecureKv {
  @override
  Future<String?> read(String key) => Completer<String?>().future;
  @override
  Future<void> write(String key, String value) => Completer<void>().future;
  @override
  Future<void> delete(String key) => Completer<void>().future;
}

/// Memory storage whose writes can be held, failed or hung on demand.
class ControlledKv extends MemorySecureKv {
  Completer<void>? holdNextWrite;
  int failWrites = 0;
  bool hangNextWrite = false;

  @override
  Future<void> write(String key, String value) async {
    final hold = holdNextWrite;
    if (hold != null) {
      holdNextWrite = null;
      await hold.future;
    }
    if (hangNextWrite) {
      hangNextWrite = false;
      return Completer<void>().future;
    }
    if (failWrites > 0) {
      failWrites--;
      throw PlatformException(code: 'keyring locked');
    }
    return super.write(key, value);
  }
}

void main() {
  late FakeServer server;
  late MemorySecureKv kv;

  setUp(() {
    server = FakeServer();
    kv = MemorySecureKv();
  });

  ProviderContainer make({SecureKv? store, Duration timeout = const Duration(seconds: 5)}) {
    final c = ProviderContainer(overrides: [
      ...sessionOverrides(server, store ?? kv),
      storageTimeoutProvider.overrideWithValue(timeout),
    ]);
    addTearDown(c.dispose);
    return c;
  }

  test('starts signed out with empty storage', () async {
    expect(await settledSession(make()), isA<SignedOut>());
  });

  test('join stores keys and tokens', () async {
    final c = make();
    await settledSession(c);
    await c.read(sessionProvider.notifier).join(token: server.addInvite(name: 'Dad', admin: true), deviceName: ' Pixel ');
    final s = c.read(sessionProvider);
    expect(s, isA<SignedIn>());
    final session = (s as SignedIn).session;
    expect(session.isAdmin, isTrue);
    expect(session.name, isNull);
    expect(session.deviceName, 'Pixel');
    final blob = jsonDecode(kv.values[SessionStore.key]!) as Map<String, Object?>;
    for (final k in ['identitySeed', 'encSeed', 'signSeed']) {
      expect(b64urlDecode(blob[k] as String), hasLength(32), reason: k);
    }
    final device = server.devices[session.deviceId]!;
    expect(device.name, 'Pixel');
    expect(device.platform, serverPlatform());
    expect(device.cert['signPub'], b64url(await (await session.deviceKeys()).signPub()));
    expect(device.refresh, session.refreshToken);
    // The access token from the redeem is used without a refresh.
    expect((await c.read(apiClientProvider).me()).name, 'Dad');
    expect(server.refreshCalls, 0);
  });

  test('restores a saved session', () async {
    final c1 = make();
    await settledSession(c1);
    await c1.read(sessionProvider.notifier).join(token: server.addInvite(), deviceName: 'Pixel');
    final c2 = make();
    final s = await settledSession(c2);
    expect(s, isA<SignedIn>());
    expect((await c2.read(apiClientProvider).me()).name, 'Mom');
    expect(server.refreshCalls, 1);
    expect((c2.read(sessionProvider) as SignedIn).session.refreshToken, isNot((s as SignedIn).session.refreshToken));
  });

  test('redeem retry after a lost response reuses the keys', () async {
    final c = make();
    await settledSession(c);
    final token = server.addInvite();
    server.dropNextRedeemResponse = true;
    final ctl = c.read(sessionProvider.notifier);
    await expectLater(ctl.join(token: token, deviceName: 'Pixel'), throwsA(isA<NetworkException>()));
    expect(c.read(sessionProvider), isA<SignedOut>());
    await ctl.join(token: token, deviceName: 'Pixel');
    expect(c.read(sessionProvider), isA<SignedIn>());
    expect(server.devices, hasLength(1));
  });

  test('used invite throws invite_invalid', () async {
    final c = make();
    await settledSession(c);
    final token = server.addInvite();
    await make().read(sessionProvider.notifier).join(token: token, deviceName: 'Other');
    await expectLater(
      c.read(sessionProvider.notifier).join(token: token, deviceName: 'Pixel'),
      throwsA(isA<ApiException>().having((e) => e.code, 'code', 'invite_invalid')),
    );
  });

  test('storage error gives SessionUnavailable', () async {
    expect(await settledSession(make(store: ThrowingKv())), isA<SessionUnavailable>());
  });

  test('storage that never answers gives SessionUnavailable', () async {
    final s = await settledSession(make(store: HangingKv(), timeout: const Duration(milliseconds: 50)));
    expect(s, isA<SessionUnavailable>());
  });

  test('sign out revokes this device and clears storage', () async {
    final c = make();
    await settledSession(c);
    await c.read(sessionProvider.notifier).join(token: server.addInvite(), deviceName: 'Pixel');
    final id = (c.read(sessionProvider) as SignedIn).session.deviceId;
    await c.read(sessionProvider.notifier).signOut();
    expect(c.read(sessionProvider), isA<SignedOut>());
    expect((c.read(sessionProvider) as SignedOut).message, isNull);
    expect(kv.values, isEmpty);
    expect(server.devices[id]!.revokedAt, isNotNull);
  });

  test('sign out turns message previews off', () async {
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    final c = make();
    await settledSession(c);
    await c.read(sessionProvider.notifier).join(token: server.addInvite(), deviceName: 'Pixel');
    await c.read(previewsOnProvider.notifier).set(true);
    expect(await c.read(previewsOnProvider.future), isTrue);
    await c.read(sessionProvider.notifier).signOut();
    expect(await readPreviewsOn(), isFalse);
    expect(await c.read(previewsOnProvider.future), isFalse);
  });

  test('sign out wipes the preview keyring, with a live sync and keys in the db', () async {
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    final db = ChatDb(NativeDatabase.memory());
    addTearDown(db.close);
    final store = MemoryPreviewKeyringStore()..value = 'x';
    final c = ProviderContainer(overrides: [
      ...sessionOverrides(server, kv),
      storageTimeoutProvider.overrideWithValue(const Duration(seconds: 5)),
      previewKeyringStoreProvider.overrideWithValue(store),
      chatDbProvider.overrideWithValue(db),
    ]);
    addTearDown(c.dispose);
    await settledSession(c);
    await c.read(sessionProvider.notifier).join(token: server.addInvite(), deviceName: 'Pixel');
    c.listen(previewKeyringSyncProvider, (_, _) {});
    // What the app does when the session ends (chatSyncProvider): the local chat db is wiped.
    c.listen(sessionProvider, (p, n) {
      if (p is SignedIn && n is SignedOut) unawaited(db.wipe());
    });
    await db.putKey('C1', 1, Uint8List(32));
    await c.read(previewsOnProvider.future);
    await c.read(previewsOnProvider.notifier).set(true);
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(store.value, contains('"C1"'));
    await c.read(sessionProvider.notifier).signOut();
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(store.value, isNull);
  });

  test('sign out while offline still clears storage', () async {
    final c = make();
    await settledSession(c);
    await c.read(sessionProvider.notifier).join(token: server.addInvite(), deviceName: 'Pixel');
    server.dropNextRefreshResponse = true;
    server.failNext5xx = 99;
    server.expireAccessTokens();
    await c.read(sessionProvider.notifier).signOut();
    expect(c.read(sessionProvider), isA<SignedOut>());
    expect(kv.values, isEmpty);
  });

  test('revoked device ends signed out with a message', () async {
    final c = make();
    await settledSession(c);
    await c.read(sessionProvider.notifier).join(token: server.addInvite(), deviceName: 'Pixel');
    final id = (c.read(sessionProvider) as SignedIn).session.deviceId;
    server.revoke(id);
    server.expireAccessTokens();
    await expectLater(c.read(apiClientProvider).me(), throwsA(isA<SignedOutException>()));
    final s = c.read(sessionProvider);
    expect(s, isA<SignedOut>());
    expect((s as SignedOut).message, contains('signed out'));
    expect(kv.values, isEmpty);
  });

  test('updateProfile stores the name and admin flag', () async {
    final c = make();
    await settledSession(c);
    await c.read(sessionProvider.notifier).join(token: server.addInvite(name: 'Gran'), deviceName: 'Pixel');
    final ctl = c.read(sessionProvider.notifier);
    await ctl.updateProfile(await c.read(apiClientProvider).me());
    expect((c.read(sessionProvider) as SignedIn).session.name, 'Gran');
    expect(jsonDecode(kv.values[SessionStore.key]!)['name'], 'Gran');
  });

  Future<(ProviderContainer, ControlledKv, DateTime Function())> signedInWithControlledKv({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final ckv = ControlledKv();
    var now = DateTime(2026, 11, 16, 12);
    server.now = () => now;
    final c = make(store: ckv, timeout: timeout);
    await settledSession(c);
    await c.read(sessionProvider.notifier).join(token: server.addInvite(name: 'Gran'), deviceName: 'Pixel');
    return (c, ckv, () => now = now.add(const Duration(minutes: 2)));
  }

  String serverRefresh() => server.devices.values.single.refresh!;

  test('a profile save racing a refresh keeps the new refresh token', () async {
    final (c, ckv, _) = await signedInWithControlledKv();
    final hold = ckv.holdNextWrite = Completer<void>();
    final profile = c.read(sessionProvider.notifier).updateProfile(
          Me(userId: (c.read(sessionProvider) as SignedIn).session.userId, deviceId: 'd', name: 'Gran', isAdmin: false),
        );
    server.expireAccessTokens();
    final me = c.read(apiClientProvider).me();
    await Future<void>.delayed(const Duration(milliseconds: 5));
    hold.complete();
    await profile;
    await me;
    final stored = jsonDecode(ckv.values[SessionStore.key]!) as Map<String, Object?>;
    expect(stored['refreshToken'], serverRefresh());
    expect(stored['name'], 'Gran');
    expect((c.read(sessionProvider) as SignedIn).session.refreshToken, serverRefresh());
  });

  test('a failed save during refresh keeps the new token in memory', () async {
    final (c, ckv, advance) = await signedInWithControlledKv();
    ckv.failWrites = 1;
    server.expireAccessTokens();
    await c.read(apiClientProvider).me();
    advance(); // past the grace window: only the new token works now
    server.expireAccessTokens();
    await c.read(apiClientProvider).me();
    expect(c.read(sessionProvider), isA<SignedIn>());
    expect(server.devices.values.single.revokedAt, isNull);
    final stored = jsonDecode(ckv.values[SessionStore.key]!) as Map<String, Object?>;
    expect(stored['refreshToken'], serverRefresh());
  });

  test('a hung save during refresh does not block requests', () async {
    final (c, ckv, _) = await signedInWithControlledKv(timeout: const Duration(milliseconds: 50));
    ckv.hangNextWrite = true;
    server.expireAccessTokens();
    expect((await c.read(apiClientProvider).me().timeout(const Duration(seconds: 2))).name, 'Gran');
  });

  test('revocation does not wipe a session another tab stored for a different device', () async {
    final c = make();
    await settledSession(c);
    await c.read(sessionProvider.notifier).join(token: server.addInvite(), deviceName: 'Pixel');
    final mine = (c.read(sessionProvider) as SignedIn).session;
    final other = jsonEncode({...mine.toJson(), 'deviceId': 'other-device', 'refreshToken': 'other'});
    kv.values[SessionStore.key] = other;
    server.revoke(mine.deviceId);
    server.expireAccessTokens();
    await expectLater(c.read(apiClientProvider).me(), throwsA(isA<SignedOutException>()));
    expect(c.read(sessionProvider), isA<SignedOut>());
    expect(kv.values[SessionStore.key], other);
  });
}
