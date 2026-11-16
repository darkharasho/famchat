import 'dart:typed_data';

import 'package:famchat/api/api_client.dart';
import 'package:famchat/crypto/encoding.dart';
import 'package:famchat/crypto/keys.dart';
import 'package:famchat/crypto/pairing.dart';
import 'package:famchat/pairing/bundle.dart';
import 'package:famchat/pairing/new_device_pairing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../support/fake_server.dart';
import '../support/pairing_helpers.dart';

void main() {
  late FakeServer server;
  late DateTime clock, serverClock;
  late NewDevicePairing p;

  setUp(() {
    clock = serverClock = DateTime(2026, 11, 16, 12);
    server = FakeServer(now: () => serverClock);
    p = NewDevicePairing(
      api: ApiClient(client: server.client, base: testBase),
      deviceName: 'Laptop',
      platform: 'linux',
      pollEvery: const Duration(milliseconds: 1),
      now: () => clock,
    );
  });
  tearDown(() => p.dispose());

  Future<PairShowing> showing() async {
    await p.start();
    return p.state as PairShowing;
  }

  Future<PairState> settled() => p.states.firstWhere((s) => s is! PairShowing && s is! PairFinishing).timeout(
        const Duration(seconds: 5),
        onTimeout: () => p.state,
      );

  int claims() => server.log.where((l) => l.startsWith('POST /api/devices/pair/claim')).length;

  test('shows a code then finishes with a verified session', () async {
    final s = await showing();
    expect(s.code.display, matches(RegExp(r'^[0-9A-Z]{4}(-[0-9A-Z]{4}){3}$')));
    expect(s.qr, startsWith('famchat-pair:1:${s.code.compact}:'));
    expect(s.expiresAt, clock.add(const Duration(minutes: 5)));
    final x = server.pairSessionByCode(s.code.lookup)!;
    // The MAC the server holds checks with the code's secret: an approver can verify the keys.
    expect(
      await checkPairKeysMac(
        secret: s.code.secret,
        ephPub: b64urlDecode(x.body['ephPub']!),
        encPub: b64urlDecode(x.body['encPub']!),
        signPub: b64urlDecode(x.body['signPub']!),
        deviceName: 'Laptop',
        platform: 'linux',
        mac: b64urlDecode(x.body['keysMac']!),
      ),
      isTrue,
    );

    final key = HandoverKey(chatId: 'C1', epoch: 1, key: Uint8List(32)..[0] = 5);
    final approver = await approveByHand(server, s.code, keys: [key]);
    final done = await settled() as PairDone;
    final session = done.device.session;
    expect(session.userId, approver.userId);
    expect(session.deviceId, x.deviceId);
    expect(session.deviceName, 'Laptop');
    expect(session.identitySeed, b64url(await seedOf(approver.identity)));
    expect(done.device.bundle.keys.single.key, key.key);
    expect(server.devices[x.deviceId]!.refresh, session.refreshToken);
    final keys = await session.deviceKeys();
    expect(server.devices[x.deviceId]!.cert['encPub'], b64url(await keys.encPub()));
  });

  test('lost claim response is retried', () async {
    final s = await showing();
    server.dropNextClaimResponse = true;
    await approveByHand(server, s.code);
    final done = await settled() as PairDone;
    expect(server.devices.length, 1);
    expect(server.devices.values.single.refresh, done.device.session.refreshToken);
  });

  test('network and server errors keep polling', () async {
    final s = await showing();
    server.failNextClaims = 3;
    await approveByHand(server, s.code);
    expect(await settled(), isA<PairDone>());
  });

  test('expired session stops polling', () async {
    final s = await showing();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    clock = s.expiresAt; // our clock says expired; the server still says waiting
    final end = await settled();
    expect(end, isA<PairExpired>());
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final n = claims();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(claims(), n);
    expect(server.pairSessionByCode(s.code.lookup)!.cancelledAt, isNotNull);
  });

  test('a session the server expired ends the wait', () async {
    final s = await showing();
    server.pairSessionByCode(s.code.lookup)!.cancelledAt = clock;
    expect(await settled(), isA<PairExpired>());
  });

  test('forged bundle is rejected', () async {
    final s = await showing();
    await approveByHand(server, s.code, secret: 'ZZZZZZZZZZZZ');
    final end = await settled();
    expect(end, isA<PairFailed>());
    expect((end as PairFailed).message, forgedBundleMessage);
  });

  test('cancel stops polling', () async {
    final s = await showing();
    await p.cancel();
    expect(p.state, isA<PairCancelled>());
    expect(server.pairSessionByCode(s.code.lookup)!.cancelledAt, isNotNull);
    final n = claims();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(claims(), lessThanOrEqualTo(n + 1));
  });

  test('rate limited start fails with a message', () async {
    final failing = NewDevicePairing(
      api: ApiClient(client: _rateLimited(), base: testBase),
      deviceName: 'Laptop',
      platform: 'linux',
    );
    await failing.start();
    expect((failing.state as PairFailed).message, contains('Too many tries'));
    await failing.dispose();
  });
}

MockClient _rateLimited() => MockClient((_) async => http.Response('{"error":"rate_limited"}', 429));
