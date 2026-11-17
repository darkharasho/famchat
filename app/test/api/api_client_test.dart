import 'dart:convert';

import 'package:famchat/api/api_client.dart';
import 'package:famchat/api/models.dart';
import 'package:famchat/api/token_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

ApiClient clientFor(Future<http.Response> Function(http.Request) handler) {
  final api = ApiClient(client: MockClient(handler), base: Uri.parse('https://famchat.dev'));
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

  test('me() reads operator', () async {
    String body(Object? op) => jsonEncode({
          'userId': 'U1',
          'deviceId': 'D1',
          'name': 'Mom',
          'isAdmin': true,
          'operator': ?op,
        });
    expect((await clientFor((_) async => http.Response(body(true), 200)).me()).operator, isTrue);
    expect((await clientFor((_) async => http.Response(body(false), 200)).me()).operator, isFalse);
    expect((await clientFor((_) async => http.Response(body(null), 200)).me()).operator, isFalse);
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

  test('a 401 from refresh without the server error code does not sign out', () async {
    var revoked = 0;
    final api = ApiClient(
      client: MockClient((r) async => r.url.path == '/api/auth/refresh'
          ? http.Response('<html>login to wifi</html>', 401)
          : http.Response('{"error":"unauthorized"}', 401)),
      base: Uri.parse('https://famchat.dev'),
    );
    api.tokens = TokenManager(
      refreshCall: api.refresh,
      readRefreshToken: () async => 'r',
      saveRefreshToken: (_) async {},
      onRevoked: () async => revoked++,
    )..setAccessToken('opaque-token');
    await expectLater(api.me(), throwsA(isA<ApiException>().having((e) => e.status, 'status', 401)));
    expect(revoked, 0);
  });

  group('families', () {
    Map<String, Object?> family(int id, {String status = 'approved', String role = 'admin', bool owner = true}) => {
          'id': id,
          'name': 'Fam $id',
          'status': status,
          'role': role,
          'memberCount': 3,
          'owner': owner,
          'createdAt': 1000,
        };

    test('list, create and rename', () async {
      final seen = <http.Request>[];
      final api = clientFor((r) async {
        seen.add(r);
        return switch ((r.method, r.url.path)) {
          ('GET', '/api/families') => http.Response(
              jsonEncode({
                'families': [family(1), family(4, status: 'pending', role: 'member', owner: false)],
              }),
              200),
          ('POST', '/api/families') => http.Response(jsonEncode({'family': family(5, status: 'pending')}), 201),
          _ => http.Response('', 204),
        };
      });
      final list = await api.families();
      expect(list.map((f) => f.id), [1, 4]);
      expect(list.first.name, 'Fam 1');
      expect(list.first.status, 'approved');
      expect(list.first.admin, isTrue);
      expect(list.first.owner, isTrue);
      expect(list.first.memberCount, 3);
      expect(list.last.status, 'pending');
      expect(list.last.admin, isFalse);
      expect(list.last.owner, isFalse);

      final made = await api.createFamily('Smiths');
      expect(made.id, 5);
      expect(made.status, 'pending');
      expect(jsonDecode(seen.last.body), {'name': 'Smiths'});

      await api.renameFamily(5, 'Smith clan');
      expect(seen.last.method, 'PUT');
      expect(seen.last.url.path, '/api/families/5');
      expect(jsonDecode(seen.last.body), {'name': 'Smith clan'});
    });

    test('invite, lookup and join', () async {
      final seen = <http.Request>[];
      final api = clientFor((r) async {
        seen.add(r);
        return switch (r.url.path) {
          '/api/families/2/invites' => http.Response(
              jsonEncode({'inviteToken': 'tok', 'inviteUrl': 'https://famchat.dev/join#tok', 'expiresAt': 5000}), 201),
          '/api/families/invite-lookup' => http.Response(
              jsonEncode({'familyId': 2, 'familyName': 'Smiths', 'invitedName': 'Gran', 'alreadyMember': false}), 200),
          '/api/families/2/join' => http.Response(jsonEncode({'family': family(2, role: 'member', owner: false)}), 200),
          _ => http.Response('{"error":"not_found"}', 404),
        };
      });
      final invite = await api.createFamilyInvite(2, 'Gran');
      expect(invite.inviteToken, 'tok');
      expect(invite.inviteUrl, 'https://famchat.dev/join#tok');
      expect(invite.expiresAt, DateTime.fromMillisecondsSinceEpoch(5000));
      expect(seen.last.method, 'POST');
      expect(jsonDecode(seen.last.body), {'name': 'Gran'});

      final look = await api.lookupInvite('tok');
      expect(look.familyId, 2);
      expect(look.familyName, 'Smiths');
      expect(look.invitedName, 'Gran');
      expect(look.alreadyMember, isFalse);
      expect(jsonDecode(seen.last.body), {'inviteToken': 'tok'});

      final joined = await api.joinFamily(2, 'tok');
      expect(joined.id, 2);
      expect(joined.admin, isFalse);
      expect(seen.last.method, 'POST');
      expect(jsonDecode(seen.last.body), {'inviteToken': 'tok'});
    });

    test('an unusable invite and an existing membership keep their codes', () async {
      final gone = clientFor((_) async => http.Response('{"error":"invite_invalid"}', 410));
      await expectLater(gone.lookupInvite('x'), throwsA(isA<ApiException>().having((e) => e.code, 'code', 'invite_invalid')));
      final dup = clientFor((_) async => http.Response('{"error":"conflict"}', 409));
      await expectLater(dup.joinFamily(2, 'x'), throwsA(isA<ApiException>().having((e) => e.code, 'code', 'conflict')));
    });

    test('leave, remove and demote', () async {
      final seen = <http.Request>[];
      final api = clientFor((r) async {
        seen.add(r);
        return http.Response('', 204);
      });
      await api.leaveOrRemove(3, 'user 1');
      expect(seen.last.method, 'DELETE');
      expect(seen.last.url.toString(), 'https://famchat.dev/api/families/3/members/user%201');
      await api.demote(3, 'U2');
      expect(seen.last.method, 'DELETE');
      expect(seen.last.url.path, '/api/families/3/admins/U2');
    });

    test('409 last_admin names the family', () async {
      final api = clientFor((_) async =>
          http.Response(jsonEncode({'error': 'last_admin', 'familyId': 3, 'familyName': 'Smiths'}), 409));
      await expectLater(
        api.leaveOrRemove(3, 'U1'),
        throwsA(isA<ApiException>()
            .having((e) => e.status, 'status', 409)
            .having((e) => e.code, 'code', 'last_admin')
            .having((e) => e.familyId, 'familyId', 3)
            .having((e) => e.familyName, 'familyName', 'Smiths')),
      );
    });

    test('operator lists requests and decides them', () async {
      final seen = <http.Request>[];
      final api = clientFor((r) async {
        seen.add(r);
        if (r.method == 'GET') {
          return http.Response(
              jsonEncode({
                'families': [
                  {
                    'id': 7,
                    'name': 'Joneses',
                    'status': 'pending',
                    'createdAt': 9000,
                    'decidedAt': null,
                    'creator': {'id': 'U9', 'name': 'Jo'},
                    'memberCount': 1,
                  },
                  {
                    'id': 6,
                    'name': 'Orphans',
                    'status': 'pending',
                    'createdAt': 8000,
                    'decidedAt': null,
                    'creator': null,
                    'memberCount': 0,
                  },
                ],
              }),
              200);
        }
        return http.Response('', 204);
      });
      final pending = await api.operatorFamilies();
      expect(seen.last.url.path, '/api/operator/families');
      expect(seen.last.url.queryParameters, {'status': 'pending'});
      expect(pending.map((f) => f.id), [7, 6]);
      expect(pending.first.name, 'Joneses');
      expect(pending.first.status, 'pending');
      expect(pending.first.createdAt, DateTime.fromMillisecondsSinceEpoch(9000));
      expect(pending.first.creatorName, 'Jo');
      expect(pending.first.memberCount, 1);
      expect(pending.last.creatorName, isNull);

      await api.operatorFamilies(status: 'declined');
      expect(seen.last.url.queryParameters, {'status': 'declined'});

      await api.approveFamily(7);
      expect(seen.last.method, 'POST');
      expect(seen.last.url.path, '/api/operator/families/7/approve');
      await api.declineFamily(6);
      expect(seen.last.url.path, '/api/operator/families/6/decline');
    });
  });
}
