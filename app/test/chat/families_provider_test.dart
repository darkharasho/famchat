import 'dart:convert';

import 'package:famchat/api/api_client.dart';
import 'package:famchat/api/token_manager.dart';
import 'package:famchat/chat/providers.dart';
import 'package:famchat/session/session_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('familiesProvider lists my families, refetches on refresh; myFamiliesProvider keeps the approved ones',
      () async {
    var gets = 0;
    var families = [
      {'id': 1, 'name': 'Smiths', 'status': 'approved', 'role': 'admin', 'memberCount': 4, 'owner': true, 'createdAt': 1},
      {'id': 4, 'name': 'Club', 'status': 'pending', 'role': 'admin', 'memberCount': 1, 'owner': true, 'createdAt': 2},
    ];
    final api = ApiClient(
      client: MockClient((r) async {
        gets++;
        return http.Response(jsonEncode({'families': families}), 200);
      }),
      base: Uri.parse('https://famchat.dev'),
    );
    api.tokens = TokenManager(
      refreshCall: api.refresh,
      readRefreshToken: () async => 'r',
      saveRefreshToken: (_) async {},
      onRevoked: () async {},
    )..setAccessToken('t');
    final c = ProviderContainer(overrides: [
      apiClientProvider.overrideWithValue(api),
      myUserIdProvider.overrideWithValue('U1'),
    ]);
    addTearDown(c.dispose);

    expect((await c.read(familiesProvider.future)).map((f) => f.id), [1, 4]);
    expect((await c.read(myFamiliesProvider.future)).map((f) => f.id), [1]);
    expect(gets, 1);

    families = [
      ...families,
      {'id': 5, 'name': 'Joneses', 'status': 'approved', 'role': 'member', 'memberCount': 2, 'owner': false, 'createdAt': 3},
    ];
    await c.read(familiesProvider.notifier).refresh();
    expect(gets, 2);
    expect((await c.read(myFamiliesProvider.future)).map((f) => f.id), [1, 5]);
  });

  test('signed out: no families and no request', () async {
    final c = ProviderContainer(overrides: [
      apiClientProvider.overrideWithValue(
          ApiClient(client: MockClient((_) async => fail('no request')), base: Uri.parse('https://famchat.dev'))),
      myUserIdProvider.overrideWithValue(null),
    ]);
    addTearDown(c.dispose);
    expect(await c.read(familiesProvider.future), isEmpty);
  });
}
