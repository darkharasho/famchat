// Scheduled messages on the device (docs/protocol.md "Scheduled messages"): handing them to the
// server after their media, the synced list, cancel / send now / edit, delivery at the time, and
// re-encrypting after a key change exactly once, from the plaintext or from the server's copy.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:famchat/chat/chat_sync.dart';
import 'package:famchat/chat/db/chat_db.dart';
import 'package:famchat/media/media_db.dart';
import 'package:famchat/media/media_service.dart';
import 'package:famchat/voice/waveform.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_chat_backend.dart';
import '../support/fake_media.dart';

class Clock {
  DateTime now = DateTime.fromMillisecondsSinceEpoch(1700000000000);
  int get ms => now.millisecondsSinceEpoch;
}

class Node {
  Node(this.d, this.clock) : mediaDb = memoryMediaDb() {
    sync = ChatSync(db: d.db, api: d.api, hub: d.hub, me: d.me, now: () => clock.now);
    media = MediaService(db: mediaDb, api: d.media, sync: sync, processor: FakeProcessor());
  }
  final TestDevice d;
  final Clock clock;
  final MediaDb mediaDb;
  late final ChatSync sync;
  late final MediaService media;

  Future<ScheduledRow?> sched(String id) => d.db.scheduledById(id);
  Future<List<ScheduledRow>> list(String chatId) => d.db.watchScheduled(chatId).first;
  Future<MessageRow?> row(String id) => d.db.messageById(id);
}

Future<void> until(FutureOr<bool> Function() cond, {String? reason}) async {
  final sw = Stopwatch()..start();
  while (!await cond()) {
    if (sw.elapsed > const Duration(seconds: 5)) fail('timed out waiting${reason == null ? '' : ' for $reason'}');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

String? textOf(MessageRow? r) => r?.body == null ? null : (jsonDecode(r!.body!) as Map)['text'] as String?;

void main() {
  late FakeChatBackend backend;
  late Clock clock;
  final nodes = <Node>[];

  Future<Node> start(TestDevice d) async {
    final n = Node(d, clock);
    nodes.add(n);
    await n.sync.start();
    await n.media.start();
    await n.sync.idle;
    return n;
  }

  setUp(() {
    backend = FakeChatBackend();
    clock = Clock();
    backend.wallClock = () => clock.ms;
  });
  tearDown(() async {
    for (final n in nodes) {
      await n.media.stop();
      await n.sync.stop();
      await n.mediaDb.close();
    }
    for (final d in {for (final n in nodes) n.d}) {
      await d.dispose();
    }
    nodes.clear();
  });

  Future<(Node, Node, String)> pair() async {
    final alice = await start(await backend.addUser('Alice'));
    final bob = await start(await backend.addUser('Bob'));
    final chatId = await alice.sync.openDirect(bob.d.userId);
    await until(() async => await bob.d.db.chatById(chatId) != null, reason: 'bob has the chat');
    return (alice, bob, chatId);
  }

  DateTime inHours(int h) => clock.now.add(Duration(hours: h));

  Future<String> scheduled(Node n, String chatId, String text, {int hours = 2}) async {
    final id = await n.sync.sendText(chatId, text, at: inHours(hours));
    await until(() async => (await n.sched(id))?.onServer ?? false, reason: 'on the server');
    return id;
  }

  test('a scheduled text goes to the server encrypted, stays listed with its plaintext, and nobody else sees it', () async {
    final (alice, bob, chatId) = await pair();
    final id = await scheduled(alice, chatId, 'happy birthday!');
    final s = (await alice.sched(id))!;
    expect((s.state, s.kind, s.deliverAt), ('pending', 'text', inHours(2).millisecondsSinceEpoch));
    expect((jsonDecode(s.body!) as Map)['text'], 'happy birthday!');
    final held = backend.scheduledDto(id)!;
    expect(held.chatId, chatId);
    expect(jsonEncode(held.envelope), isNot(contains('birthday')), reason: 'the server holds ciphertext only');
    expect(await alice.row(id), isNull, reason: 'not in the timeline until delivered');
    expect(backend.storedMessages(chatId), isEmpty);
    await bob.sync.idle;
    expect(await bob.row(id), isNull);
    expect(await bob.list(chatId), isEmpty);
    expect(() => alice.sync.sendText(chatId, 'too soon', at: clock.now.add(const Duration(seconds: 30))), throwsArgumentError);
    expect(() => alice.sync.sendText(chatId, 'too late', at: clock.now.add(const Duration(days: 367))), throwsArgumentError);
  });

  test('a scheduled photo uploads its blobs under the message id first, then goes to the server', () async {
    final (alice, _, chatId) = await pair();
    final hold = alice.d.media.hold = Completer<void>();
    final id = await alice.media.sendPhoto(chatId, Uint8List.fromList(List.filled(64, 7)), caption: 'look', at: inHours(3));
    await until(() async => alice.d.media.uploads.isEmpty && (await alice.sched(id)) != null, reason: 'staged');
    await alice.sync.idle;
    expect((await alice.sched(id))!.state, 'local', reason: 'waits for its blobs');
    expect(backend.scheduledDto(id), isNull);
    hold.complete();
    alice.d.media.hold = null;
    await until(() async => (await alice.sched(id))?.onServer ?? false, reason: 'scheduled after the upload');
    expect(alice.d.media.uploads, hasLength(2));
    final s = (await alice.sched(id))!;
    expect((s.kind, (jsonDecode(s.body!) as Map)['caption']), ('photo', 'look'));
    // A restart keeps nothing it no longer needs, and loses nothing it does.
    await alice.media.stop();
    await alice.media.start();
    expect(await alice.mediaDb.uploadsFor(id), isEmpty, reason: 'on the server now');
  });

  test('cancel removes it here and on the server; my other device follows', () async {
    final (alice, _, chatId) = await pair();
    final alice2 = await start(await backend.pairDevice(alice.d.userId));
    await until(() async => await alice2.d.db.key(chatId, 1) != null, reason: 'my new device gets the key');
    final id = await scheduled(alice, chatId, 'never mind');
    await until(() async => (await alice2.list(chatId)).length == 1, reason: 'synced to my other device');
    expect(textOf(_asRow((await alice2.sched(id))!)), 'never mind', reason: 'decrypted there for showing');
    await alice.sync.cancelScheduled(id);
    expect(await alice.sched(id), isNull);
    expect(backend.scheduledDto(id), isNull);
    await until(() async => (await alice2.list(chatId)).isEmpty, reason: 'gone from my other device');
  });

  test('send now delivers it as a normal message to everyone', () async {
    final (alice, bob, chatId) = await pair();
    final id = await scheduled(alice, chatId, 'right now');
    await alice.sync.sendScheduledNow(id);
    await until(() async => textOf(await bob.row(id)) == 'right now', reason: 'bob gets it');
    await until(() async => (await alice.row(id))?.seq != null, reason: 'in my timeline');
    expect(await alice.list(chatId), isEmpty);
    expect(backend.scheduledDto(id), isNull);
  });

  test('edit replaces the text and the time under the same id', () async {
    final (alice, bob, chatId) = await pair();
    final id = await scheduled(alice, chatId, 'dinner at 6');
    final before = backend.scheduledDto(id)!;
    await alice.sync.editScheduled(id, text: 'dinner at 7', at: inHours(5));
    final after = backend.scheduledDto(id)!;
    expect(after.deliverAt, inHours(5).millisecondsSinceEpoch);
    expect(jsonEncode(after.envelope), isNot(jsonEncode(before.envelope)));
    expect(textOf(_asRow((await alice.sched(id))!)), 'dinner at 7');
    backend.runScheduled(id);
    await until(() async => textOf(await bob.row(id)) == 'dinner at 7', reason: 'the edited text goes out');
    expect(() => alice.sync.editScheduled('01JNOTHING00000000000000000', text: 'x'), throwsStateError);
  });

  test('at its time it arrives as a normal message; the list empties on every device of mine', () async {
    final (alice, bob, chatId) = await pair();
    final alice2 = await start(await backend.pairDevice(alice.d.userId));
    await until(() async => await alice2.d.db.key(chatId, 1) != null, reason: 'my new device gets the key');
    final id = await scheduled(alice, chatId, 'good morning');
    await until(() async => (await alice2.list(chatId)).length == 1, reason: 'listed on my other device');
    backend.runScheduled(id);
    await until(() async => textOf(await bob.row(id)) == 'good morning', reason: 'bob gets it');
    final mine = (await until2(() => alice.row(id), (r) => r?.seq != null))!;
    expect((mine.state, mine.senderUserId, mine.scheduledFor), ('sent', alice.d.userId, null), reason: 'on time, not late');
    await until(() async => (await alice2.row(id))?.seq == mine.seq, reason: 'my other device has it too');
    expect(await alice.list(chatId), isEmpty);
    expect(await alice2.list(chatId), isEmpty);
    expect(backend.storedMessages(chatId).where((m) => m.id == id), hasLength(1));
  });

  test('needs_resend: re-encrypted under the new epoch and sent once, marked sent late for me', () async {
    final (alice, bob, chatId) = await pair();
    final id = await scheduled(alice, chatId, 'still coming');
    backend.rotateEpoch(chatId); // a device was removed, say
    await until(() async => (await alice.d.db.chatById(chatId))?.currentEpoch == 2, reason: 'alice sees the new epoch');
    backend.runScheduled(id);
    await until(() async => textOf(await bob.row(id)) == 'still coming', reason: 'bob gets it after all');
    await until(() async => (await alice.row(id))?.state == 'sent', reason: 'acked');
    await alice.sync.idle;
    await bob.sync.idle;
    final sends = [for (final f in alice.d.hub.sent) if (f['type'] == 'send' && f['id'] == id) f];
    expect(sends, hasLength(1));
    expect((sends.single['envelope'] as Map)['epoch'], 2);
    expect(backend.storedMessages(chatId).where((m) => m.id == id), hasLength(1));
    expect((await alice.row(id))!.scheduledFor, inHours(2).millisecondsSinceEpoch);
    expect(await alice.list(chatId), isEmpty);
  });

  test('needs_resend with two of my devices racing: delivered exactly once', () async {
    final (alice, bob, chatId) = await pair();
    final alice2 = await start(await backend.pairDevice(alice.d.userId));
    await until(() async => await alice2.d.db.key(chatId, 1) != null, reason: 'my new device gets the key');
    final id = await scheduled(alice, chatId, 'once only');
    await until(() async => (await alice2.list(chatId)).length == 1, reason: 'synced');
    backend.rotateEpoch(chatId);
    await until(() async => (await alice2.d.db.chatById(chatId))?.currentEpoch == 2, reason: 'new epoch');
    await until(() async => (await alice.d.db.chatById(chatId))?.currentEpoch == 2, reason: 'new epoch');
    backend.runScheduled(id);
    await until(() async => (await alice.row(id))?.seq != null && (await alice2.row(id))?.seq != null, reason: 'both have it');
    await until(() async => textOf(await bob.row(id)) == 'once only', reason: 'bob has it');
    await bob.sync.idle;
    expect(backend.storedMessages(chatId).where((m) => m.id == id), hasLength(1));
    expect((await alice.row(id))!.seq, (await alice2.row(id))!.seq);
    expect([...await bob.d.db.watchMessages(chatId).first].where((m) => m.id == id), hasLength(1));
  });

  test("no plaintext on this device: the server's copy is decrypted with the old epoch's key and re-sent", () async {
    final (alice, bob, chatId) = await pair();
    final id = await scheduled(alice, chatId, 'from the phone');
    // The phone that scheduled it is wiped; another device of mine carries on.
    await alice.media.stop();
    await alice.sync.stop();
    await alice.d.hub.stop();
    final alice2 = await start(await backend.addDevice(alice.d.userId));
    await alice.sync.start(); // only to wrap the keys for the new device
    await alice.sync.idle;
    await until(() async => await alice2.d.db.key(chatId, 1) != null, reason: 'alice2 gets epoch 1');
    await alice.sync.stop();
    await alice.d.hub.stop();
    await alice2.sync.refreshScheduled();
    final listed = (await alice2.sched(id))!;
    expect(textOf(_asRow(listed)), 'from the phone', reason: 'decrypted for the list');
    // Pretend this device never had the plaintext (a list fetched while its key was missing).
    await alice2.d.db.putScheduled(listed.copyWith(body: const Value(null), kind: const Value(null)));
    backend.revoke(alice.d.deviceId);
    await until(() async => (await alice2.d.db.chatById(chatId))?.currentEpoch == 2, reason: 'new epoch');
    await until(() async => await alice2.d.db.key(chatId, 2) != null, reason: 'alice2 has the new key');
    backend.runScheduled(id);
    await until(() async => textOf(await bob.row(id)) == 'from the phone', reason: 'bob gets it');
    final sent = [for (final f in alice2.d.hub.sent) if (f['type'] == 'send' && f['id'] == id) f];
    expect(sent, hasLength(1));
    expect((sent.single['envelope'] as Map)['epoch'], 2);
  });

  test('needs_resend of a photo: its blobs stay on the server, so it goes without uploading again', () async {
    final (alice, bob, chatId) = await pair();
    final id = await alice.media.sendPhoto(chatId, Uint8List.fromList(List.filled(64, 7)), at: inHours(2));
    await until(() async => (await alice.sched(id))?.onServer ?? false, reason: 'on the server');
    await alice.media.stop();
    await alice.media.start(); // its upload rows are cleaned up
    expect(await alice.mediaDb.uploadsFor(id), isEmpty);
    backend.rotateEpoch(chatId);
    await until(() async => (await alice.d.db.chatById(chatId))?.currentEpoch == 2, reason: 'new epoch');
    backend.runScheduled(id);
    await until(() async => (await bob.row(id))?.kind == 'photo', reason: 'bob gets the photo');
    expect((await alice.row(id))!.state, isNot('failed'));
    expect(alice.d.media.uploads, hasLength(2), reason: 'uploaded once, when scheduled');
  });

  test("a time that passed while it waited for its upload: it goes now, as a message", () async {
    final (alice, bob, chatId) = await pair();
    final hold = alice.d.media.hold = Completer<void>();
    final id = await alice.media.sendVoice(
      chatId,
      RecordedVoice(bytes: Uint8List.fromList(List.filled(200, 3)), duration: const Duration(seconds: 2), waveform: const [1, 2, 3]),
      at: clock.now.add(const Duration(minutes: 2)),
    );
    await until(() async => (await alice.sched(id))?.state == 'local', reason: 'waiting');
    clock.now = clock.now.add(const Duration(minutes: 5));
    hold.complete();
    alice.d.media.hold = null;
    await until(() async => (await bob.row(id))?.kind == 'voice', reason: 'sent at once instead');
    expect(await alice.sched(id), isNull);
    expect(backend.scheduledDto(id), isNull);
  });

  test('a cancel while offline hides it at once and reaches the server when back', () async {
    final (alice, _, chatId) = await pair();
    final id = await scheduled(alice, chatId, 'oops');
    alice.d.api.offlineCalls.add('DELETE /me/scheduled/$id');
    await alice.sync.cancelScheduled(id);
    expect(await alice.list(chatId), isEmpty);
    expect((await alice.sched(id))!.state, 'cancelling');
    expect(backend.scheduledDto(id), isNotNull, reason: 'the server still has it');
    // A refresh while still offline keeps it cancelling (and doesn't bring it back).
    await expectLater(alice.sync.refreshScheduled(), throwsA(anything));
    expect(await alice.list(chatId), isEmpty);
    alice.d.api.offlineCalls.clear();
    await alice.sync.refreshScheduled();
    expect(backend.scheduledDto(id), isNull);
    expect(await alice.sched(id), isNull);
  });
}

/// A scheduled row as a message row (for its text).
MessageRow _asRow(ScheduledRow s) => MessageRow(
      id: s.id,
      chatId: s.chatId,
      seq: null,
      senderUserId: '',
      senderDeviceId: '',
      kind: s.kind ?? 'unknown',
      body: s.body,
      targetId: null,
      envelope: null,
      createdAt: s.createdAt,
      state: 'pending',
    );

Future<T> until2<T>(Future<T> Function() get, bool Function(T) ok) async {
  late T v;
  await until(() async => ok(v = await get()));
  return v;
}
