import 'dart:convert';

import 'package:famchat/api/api_client.dart';
import 'package:famchat/api/models.dart';
import 'package:famchat/api/token_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

ApiClient clientFor(Future<http.Response> Function(http.Request) handler) {
  final api = ApiClient(http: MockClient(handler), base: Uri.parse('https://famchat.dev'));
  api.tokens = TokenManager(
    refreshCall: api.refresh,
    readRefreshToken: () async => 'r',
    saveRefreshToken: (_) async {},
    onRevoked: () async {},
  )..setAccessToken('opaque-token');
  return api;
}

void main() {
  test('error body maps to ApiException code', () async {
    final api = clientFor((_) async => http.Response('{"error":"invite_invalid"}', 410));
    await expectLater(
      api.createInvite('Mom'),
      throwsA(isA<ApiException>().having((e) => e.code, 'code', 'invite_invalid').having((e) => e.status, 'status', 410)),
    );
  });

  test('non-JSON error body gives code unknown', () async {
    final api = clientFor((_) async => http.Response('<html>bad gateway</html>', 502));
    await expectLater(api.listDevices(), throwsA(isA<ApiException>().having((e) => e.code, 'code', 'unknown')));
  });

  test('transport error becomes NetworkException', () async {
    final api = clientFor((_) async => throw http.ClientException('offline'));
    await expectLater(api.me(), throwsA(isA<NetworkException>()));
  });

  test('requests go to the configured base with a bearer token', () async {
    late http.Request seen;
    final api = clientFor((r) async {
      seen = r;
      return http.Response('', 204);
    });
    await api.revokeDevice('dev 1');
    expect(seen.method, 'DELETE');
    expect(seen.url.toString(), 'https://famchat.dev/api/devices/dev%201');
    expect(seen.headers['authorization'], 'Bearer opaque-token');
  });

  test('devices parse with current flag and dates', () async {
    final api = clientFor((_) async => http.Response(
          jsonEncode({
            'devices': [
              {'id': 'a', 'name': 'Pixel', 'platform': 'android', 'createdAt': 1000, 'lastSeen': 2000, 'current': true},
              {'id': 'b', 'name': 'Mac', 'platform': 'macos', 'createdAt': 3000, 'lastSeen': 4000, 'current': false},
            ],
          }),
          200,
        ));
    final list = await api.listDevices();
    expect(list.map((d) => d.id), ['a', 'b']);
    expect(list.first.current, isTrue);
    expect(list.first.lastSeen, DateTime.fromMillisecondsSinceEpoch(2000));
    expect(list.last.platform, 'macos');
  });

  test('malformed success body is an ApiException, not a TypeError', () async {
    final api = clientFor((_) async => http.Response('{"devices": "nope"}', 200));
    await expectLater(api.listDevices(), throwsA(isA<ApiException>().having((e) => e.code, 'code', 'bad_response')));
  });
}
