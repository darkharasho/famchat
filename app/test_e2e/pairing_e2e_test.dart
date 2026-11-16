// End to end against a real Worker (`wrangler dev`): an admin and a family member chat, the admin
// pairs a new device that then reads the history, and revoking it moves the chat to a new key.
//
// Run with scripts/e2e-pairing.sh (starts wrangler dev on a fresh local D1). Skipped unless
// FAMCHAT_E2E_API and FAMCHAT_E2E_BOOTSTRAP are set.
@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:famchat/api/api_client.dart';
import 'package:famchat/api/token_manager.dart';
import 'package:famchat/chat/chat_sync.dart';
import 'package:famchat/chat/db/chat_db.dart';
import 'package:famchat/chat/directory.dart';
import 'package:famchat/chat/http_chat_api.dart';
import 'package:famchat/chat/hub_link.dart';
import 'package:famchat/crypto/device_cert.dart';
import 'package:famchat/crypto/encoding.dart';
import 'package:famchat/crypto/keys.dart';
import 'package:famchat/pairing/approver.dart';
import 'package:famchat/pairing/bundle.dart';
import 'package:famchat/pairing/new_device_pairing.dart';
import 'package:famchat/session/stored_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

final _api = Platform.environment['FAMCHAT_E2E_API'];
final _bootstrap = Platform.environment['FAMCHAT_E2E_BOOTSTRAP'];

/// One running device: its API client, chat engine and database.
class Device {
  Device(this.session, this.api, this.db, this.sync);
  final StoredSession session;
  final ApiClient api;
  final ChatDb db;
  final ChatSync sync;

  Future<List<String>> texts(String chatId) async => [
        for (final r in await db.watchMessages(chatId).first)
          if (r.kind == 'text') (jsonDecode(r.body!) as Map)['text'] as String,
      ];

  Future<void> stop() async {
    await sync.stop();
    await db.close();
  }
}

Future<void> until(FutureOr<bool> Function() cond, String what) async {
  final sw = Stopwatch()..start();
  while (!await cond()) {
    if (sw.elapsed > const Duration(seconds: 30)) fail('timed out waiting for $what');
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

void main() {
  final base = _api == null ? null : Uri.parse(_api!);
  final client = http.Client();
  final running = <Device>[];
  tearDownAll(() async {
    for (final d in running) {
      await d.stop();
    }
    client.close();
  });

  /// Signs [session] in with [accessToken] and starts its chat engine on a fresh database (after
  /// [prepare], e.g. installing a pairing handover).
  Future<Device> run(StoredSession session, String accessToken, {Future<void> Function(ChatDb db)? prepare}) async {
    var refresh = session.refreshToken;
    final api = ApiClient(client: client, base: base!);
    api.tokens = TokenManager(
      refreshCall: api.refresh,
      readRefreshToken: () async => refresh,
      saveRefreshToken: (t) async => refresh = t,
      onRevoked: () async {},
    )..setAccessToken(accessToken);
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    final db = ChatDb(NativeDatabase.memory());
    if (prepare != null) await prepare(db);
    final chatApi = HttpChatApi(api);
    final identity = await session.identityKey();
    final me = LocalIdentity(
      userId: session.userId,
      deviceId: session.deviceId,
      keys: await session.deviceKeys(),
      identityPub: Uint8List.fromList((await identity.extractPublicKey()).bytes),
    );
    final sync = ChatSync(db: db, api: chatApi, hub: HubConnection(ticket: chatApi.wsTicket, apiBase: base), me: me);
    await sync.start();
    final d = Device(session, api, db, sync);
    running.add(d);
    return d;
  }

  Future<Device> join(String inviteToken, String deviceName) async {
    final identity = await newIdentityKey();
    final keys = await DeviceKeys.generate();
    final api = ApiClient(client: client, base: base!);
    final r = await api.redeemInvite(
      token: inviteToken,
      deviceName: deviceName,
      platform: 'linux',
      cert: await signDeviceCert(identity: identity, device: keys),
    );
    final seeds = await keys.toStorage();
    return run(
      StoredSession(
        userId: r.userId,
        deviceId: r.deviceId,
        deviceName: deviceName,
        refreshToken: r.refreshToken,
        isAdmin: r.isAdmin,
        name: null,
        identitySeed: b64url(await seedOf(identity)),
        encSeed: seeds['encSeed']!,
        signSeed: seeds['signSeed']!,
      ),
      r.accessToken,
    );
  }

  test('pair a new device, read history, revoke it', () async {
    final res = await client.post(
      base!.replace(path: '/api/admin/bootstrap'),
      headers: {'authorization': 'Bearer $_bootstrap', 'content-type': 'application/json'},
      body: jsonEncode({'name': 'Alice'}),
    );
    expect(res.statusCode, 201, reason: res.body);
    final alice = await join((jsonDecode(res.body) as Map)['inviteToken'] as String, 'Alice phone');
    final bob = await join((await alice.api.createInvite('Bob')).inviteToken, 'Bob phone');

    final chatId = await alice.sync.openDirect(bob.session.userId);
    await alice.sync.sendText(chatId, 'before pairing');
    await until(() async => (await bob.texts(chatId)).contains('before pairing'), 'Bob to get the first message');

    // The new device shows a code; Alice's phone types it in and approves.
    final pairing = NewDevicePairing(
      api: ApiClient(client: client, base: base),
      deviceName: 'Alice laptop',
      platform: 'linux',
      pollEvery: const Duration(milliseconds: 300),
    );
    final done = pairing.states.firstWhere((s) => s is PairDone || s is PairFailed || s is PairExpired);
    await pairing.start();
    final code = (pairing.state as PairShowing).code;
    final approver = DeviceApprover(api: alice.api, db: alice.db, session: alice.session);
    final pending = await approver.lookup(code.display);
    expect(pending.deviceName, 'Alice laptop');
    await approver.approve(pending);
    final end = await done.timeout(const Duration(seconds: 30));
    expect(end, isA<PairDone>(), reason: '$end');
    final paired = (end as PairDone).device;
    await pairing.dispose();
    expect(paired.session.userId, alice.session.userId);

    final laptop = await run(paired.session, paired.accessToken, prepare: (db) => installHandover(db, paired.bundle));
    await until(() async => (await laptop.texts(chatId)).contains('before pairing'), 'the laptop to read history');

    // Member devices added wraps for the laptop when they heard about it.
    await until(() async => (await HttpChatApi(laptop.api).wraps(chatId: chatId)).isNotEmpty, 'repaired wraps');

    await laptop.sync.sendText(chatId, 'from the laptop');
    await until(() async => (await bob.texts(chatId)).contains('from the laptop'), 'Bob to read the laptop');

    // Revoking the laptop moves the chat to epoch 2, created without it.
    await alice.api.revokeDevice(laptop.session.deviceId);
    final chats = HttpChatApi(bob.api);
    await until(() async {
      final c = await chats.chat(chatId);
      return c.currentEpoch == 2 && c.epochReady;
    }, 'a member to create epoch 2');
    await bob.sync.sendText(chatId, 'after revoke');
    await until(() async => (await alice.texts(chatId)).contains('after revoke'), 'Alice to read after the revoke');
    final last = (await chats.messages(chatId)).last;
    expect(last.envelope['epoch'], 2);
    final wraps = await HttpChatApi(alice.api).missingWraps();
    expect(wraps.where((w) => w.deviceId == laptop.session.deviceId), isEmpty);
  }, skip: _api == null || _bootstrap == null ? 'set FAMCHAT_E2E_API and FAMCHAT_E2E_BOOTSTRAP (scripts/e2e-pairing.sh)' : false);
}
