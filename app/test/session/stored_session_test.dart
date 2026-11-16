import 'package:famchat/crypto/encoding.dart';
import 'package:famchat/crypto/keys.dart';
import 'package:famchat/session/secure_kv.dart';
import 'package:famchat/session/stored_session.dart';
import 'package:flutter_test/flutter_test.dart';

Future<(StoredSession, DeviceKeys, List<int>)> sample() async {
  final identity = await newIdentityKey();
  final device = await DeviceKeys.generate();
  final seeds = await device.toStorage();
  final s = StoredSession(
    userId: 'u1',
    deviceId: 'd1',
    deviceName: 'Pixel',
    refreshToken: 'r1',
    isAdmin: true,
    name: null,
    identitySeed: b64url(await seedOf(identity)),
    encSeed: seeds['encSeed']!,
    signSeed: seeds['signSeed']!,
  );
  return (s, device, await publicKeyOf(identity));
}

void main() {
  test('session round-trips through the store', () async {
    final kv = MemorySecureKv();
    final (s, device, identityPub) = await sample();
    await SessionStore(kv).save(s);
    final loaded = (await SessionStore(kv).load())!;
    expect(loaded.toJson(), s.toJson());
    expect(loaded.userId, 'u1');
    expect(loaded.isAdmin, isTrue);
    final keys = await loaded.deviceKeys();
    expect(await keys.encPub(), await device.encPub());
    expect(await keys.signPub(), await device.signPub());
    expect(await publicKeyOf(await loaded.identityKey()), identityPub);
  });

  test('absent session loads as null', () async {
    expect(await SessionStore(MemorySecureKv()).load(), isNull);
  });

  test('corrupt blob loads as null', () async {
    for (final bad in ['{', '{"v":1}', '[]', '{"v":2,"userId":"u"}']) {
      final kv = MemorySecureKv()..values[SessionStore.key] = bad;
      expect(await SessionStore(kv).load(), isNull, reason: bad);
    }
  });

  test('clear removes the blob', () async {
    final kv = MemorySecureKv();
    final (s, _, _) = await sample();
    await SessionStore(kv).save(s);
    await SessionStore(kv).clear();
    expect(kv.values, isEmpty);
    expect(await SessionStore(kv).load(), isNull);
  });

  test('copyWith rotates only the refresh token', () async {
    final (s, _, _) = await sample();
    final r = s.copyWith(refreshToken: 'r2');
    expect(r.refreshToken, 'r2');
    expect({...r.toJson(), 'refreshToken': 'r1'}, s.toJson());
    expect(s.copyWith(name: 'Mom', isAdmin: false).name, 'Mom');
  });
}
