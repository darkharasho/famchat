import 'dart:async';

import 'package:famchat/api/api_client.dart';
import 'package:famchat/api/models.dart';
import 'package:famchat/api/token_manager.dart';
import 'package:famchat/crypto/device_cert.dart';
import 'package:famchat/crypto/keys.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_server.dart';

/// A device signed in against [server], with its refresh token held in [stored].
class Harness {
  Harness(this.server);

  final FakeServer server;
  DateTime clock = DateTime(2026, 11, 16, 12);
  String? stored;

  /// Values handed out by readRefreshToken before it falls back to [stored].
  final readQueue = <String>[];
  final saved = <String>[];
  int revokedCalls = 0;
  late ApiClient api;
  late TokenManager tokens;
  late RedeemResult redeemed;

  static Future<Harness> signedIn({List<Duration> retryDelays = const [Duration.zero]}) async {
    final server = FakeServer();
    final h = Harness(server);
    server.now = () => h.clock;
    h.api = ApiClient(client: server.client, base: Uri.parse('https://famchat.dev'));
    h.tokens = TokenManager(
      refreshCall: h.api.refresh,
      readRefreshToken: () async => h.readQueue.isNotEmpty ? h.readQueue.removeAt(0) : h.stored,
      saveRefreshToken: (t) async {
        h.saved.add(t);
        h.stored = t;
      },
      onRevoked: () async {
        h.revokedCalls++;
        h.stored = null;
      },
      now: () => h.clock,
      retryDelays: retryDelays,
    );
    h.api.tokens = h.tokens;
    final cert = await signDeviceCert(identity: await newIdentityKey(), device: await DeviceKeys.generate());
    h.redeemed = await h.api.redeemInvite(
      token: server.addInvite(name: 'Mom'),
      deviceName: 'Pixel',
      platform: 'android',
      cert: cert,
    );
    h.stored = h.redeemed.refreshToken;
    h.tokens.setAccessToken(h.redeemed.accessToken);
    return h;
  }
}

void main() {
  test('expired access token is refreshed before the request', () async {
    final h = await Harness.signedIn();
    final before = h.stored;
    h.clock = h.clock.add(const Duration(minutes: 16));
    final me = await h.api.me();
    expect(me.name, 'Mom');
    expect(h.server.refreshCalls, 1);
    expect(h.stored, isNot(before));
    expect(h.server.log.where((l) => l.endsWith('-> 401')), isEmpty);
  });

  test('token close to expiry is refreshed early', () async {
    final h = await Harness.signedIn();
    h.clock = h.clock.add(const Duration(minutes: 14, seconds: 30));
    await h.api.me();
    expect(h.server.refreshCalls, 1);
  });

  test('concurrent 401s share one refresh', () async {
    final h = await Harness.signedIn();
    h.server.expireAccessTokens();
    final results = await Future.wait([h.api.listDevices(), h.api.listDevices(), h.api.me()]);
    expect(results, hasLength(3));
    expect(h.server.refreshCalls, 1);
    expect(h.server.log.where((l) => l.endsWith('-> 401')), hasLength(3));
  });

  test('lost refresh response is retried with the same token', () async {
    final h = await Harness.signedIn();
    final original = h.stored;
    h.server.expireAccessTokens();
    h.server.dropNextRefreshResponse = true;
    expect((await h.api.me()).name, 'Mom');
    expect(h.server.refreshCalls, 2);
    expect(h.saved, hasLength(1));
    expect(h.stored, isNot(original));
    expect(h.revokedCalls, 0);
    expect(h.server.devices[h.redeemed.deviceId]!.revokedAt, isNull);
    // The token from the grace path is the live one.
    h.server.expireAccessTokens();
    await h.api.me();
    expect(h.revokedCalls, 0);
  });

  test('network errors during refresh give up after the retries without signing out', () async {
    final h = await Harness.signedIn(retryDelays: const [Duration.zero, Duration.zero]);
    final original = h.stored;
    h.server.expireAccessTokens();
    h.server.failNext5xx = 5;
    await expectLater(h.api.me(), throwsA(isA<ApiException>().having((e) => e.status, 'status', 500)));
    expect(h.server.refreshCalls, 3);
    expect(h.revokedCalls, 0);
    expect(h.stored, original);
  });

  test('revoked device signs out', () async {
    final h = await Harness.signedIn();
    h.server.revoke(h.redeemed.deviceId);
    h.server.expireAccessTokens();
    await expectLater(h.api.me(), throwsA(isA<SignedOutException>()));
    expect(h.revokedCalls, 1);
    await expectLater(h.api.me(), throwsA(isA<SignedOutException>()));
    expect(h.revokedCalls, 1);
  });

  test('refresh token is saved before the new access token is used', () async {
    final h = await Harness.signedIn();
    h.server.expireAccessTokens();
    String? savedAtUse;
    final original = h.tokens;
    // Wrap the save callback to see the order of events.
    h.tokens = TokenManager(
      refreshCall: h.api.refresh,
      readRefreshToken: () async => h.stored,
      saveRefreshToken: (t) async {
        h.stored = t;
        savedAtUse = h.server.log.last;
      },
      onRevoked: () async {},
      now: () => h.clock,
    );
    h.api.tokens = h.tokens;
    expect(original, isNot(h.tokens));
    await h.api.me();
    expect(savedAtUse, 'POST /api/auth/refresh -> 200');
  });

  test('a refresh token rotated by another tab is picked up from storage', () async {
    final h = await Harness.signedIn();
    // Another tab refreshes with the shared token and stores the result.
    final other = await h.api.refresh(h.stored!);
    h.stored = other.refreshToken;
    h.server.expireAccessTokens();
    await h.api.me();
    expect(h.revokedCalls, 0);
  });

  test('a 401 for a token another tab already replaced retries with the stored one', () async {
    final h = await Harness.signedIn();
    final t0 = h.stored!;
    // Another tab rotated twice (t0 -> t1 -> t2), so t0 is outside the grace window.
    final t1 = (await h.api.refresh(t0)).refreshToken;
    h.stored = (await h.api.refresh(t1)).refreshToken;
    h.readQueue.add(t0); // this tab read the token before the other tab's write landed
    h.server.expireAccessTokens();
    expect((await h.api.me()).name, 'Mom');
    expect(h.revokedCalls, 0);
  });

  test('a refresh that started before reset cannot save into the next session', () async {
    final gate = Completer<TokenPair>();
    final saved = <String>[];
    final tm = TokenManager(
      refreshCall: (_) => gate.future,
      readRefreshToken: () async => 'old',
      saveRefreshToken: (t) async => saved.add(t),
      onRevoked: () async {},
    );
    final pending = tm.accessToken();
    tm.reset();
    gate.complete(const TokenPair('a', 'r2'));
    await expectLater(pending, throwsA(isA<SignedOutException>()));
    expect(saved, isEmpty);
  });
}
