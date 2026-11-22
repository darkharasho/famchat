// Reminders on the device (docs/protocol.md "Reminders"): set and clear (mine alone, synced to my
// other devices), the `reminder` frame, and one that came while this device was away.
import 'dart:async';

import 'package:famchat/chat/chat_sync.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_chat_backend.dart';

class Clock {
  DateTime now = DateTime.fromMillisecondsSinceEpoch(1700000000000);
  int get ms => now.millisecondsSinceEpoch;
}

class Node {
  Node(this.d, Clock clock) {
    sync = ChatSync(db: d.db, api: d.api, hub: d.hub, me: d.me, now: () => clock.now);
    sync.onReminder = fired.add;
  }
  final TestDevice d;
  late final ChatSync sync;
  final fired = <FiredReminder>[];

  Future<Map<String, int>> reminders(String chatId) => d.db.watchReminders(chatId).first;
}

Future<void> until(FutureOr<bool> Function() cond, {String? reason}) async {
  final sw = Stopwatch()..start();
  while (!await cond()) {
    if (sw.elapsed > const Duration(seconds: 5)) fail('timed out waiting${reason == null ? '' : ' for $reason'}');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  late FakeChatBackend backend;
  late Clock clock;
  final nodes = <Node>[];

  Future<Node> start(TestDevice d) async {
    final n = Node(d, clock);
    nodes.add(n);
    await n.sync.start();
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
      await n.sync.stop();
    }
    for (final d in {for (final n in nodes) n.d}) {
      await d.dispose();
    }
    nodes.clear();
  });

  /// Alice and Bob in a direct chat with one message from Bob.
  Future<(Node, Node, String, String)> chatWithMessage() async {
    final alice = await start(await backend.addUser('Alice'));
    final bob = await start(await backend.addUser('Bob'));
    final chatId = await alice.sync.openDirect(bob.d.userId);
    await until(() async => await bob.d.db.chatById(chatId) != null, reason: 'bob has the chat');
    final id = await bob.sync.sendText(chatId, 'call the dentist');
    await until(() async => await alice.d.db.messageById(id) != null, reason: 'alice has it');
    return (alice, bob, chatId, id);
  }

  DateTime inHours(int h) => clock.now.add(Duration(hours: h));

  test('set and clear: on the server and here, mine alone, and on my other devices', () async {
    final (alice, bob, chatId, id) = await chatWithMessage();
    final alice2 = await start(await backend.pairDevice(alice.d.userId));
    await alice2.sync.syncAll();
    await alice.sync.setReminder(chatId, id, inHours(3));
    expect(await alice.reminders(chatId), {id: inHours(3).millisecondsSinceEpoch});
    expect(backend.reminders[alice.d.userId]!.keys, [id]);
    await until(() async => (await alice2.reminders(chatId)).containsKey(id), reason: 'my other device shows it');
    await bob.sync.idle;
    expect(await bob.reminders(chatId), isEmpty, reason: 'only I see my reminders');
    expect(await bob.d.api.reminders(), isEmpty);

    await alice.sync.setReminder(chatId, id, inHours(5)); // moved
    await until(() async => (await alice2.reminders(chatId))[id] == inHours(5).millisecondsSinceEpoch, reason: 'moved there too');

    await alice.sync.clearReminder(chatId, id);
    expect(await alice.reminders(chatId), isEmpty);
    expect(backend.reminders[alice.d.userId], isEmpty);
    await until(() async => (await alice2.reminders(chatId)).isEmpty, reason: 'cleared there too');
    expect(alice.fired, isEmpty, reason: 'clearing is not firing');
    expect(alice2.fired, isEmpty);

    expect(() => alice.sync.setReminder(chatId, id, clock.now.add(const Duration(seconds: 20))), throwsArgumentError);
    expect(() => alice.sync.setReminder(chatId, id, clock.now.add(const Duration(days: 400))), throwsArgumentError);
  });

  test('when it comes: every device of mine hears it, and the bell is gone', () async {
    final (alice, _, chatId, id) = await chatWithMessage();
    final alice2 = await start(await backend.pairDevice(alice.d.userId));
    await alice2.sync.syncAll();
    await alice.sync.setReminder(chatId, id, inHours(1));
    await until(() async => (await alice2.reminders(chatId)).isNotEmpty, reason: 'synced');
    clock.now = inHours(1);
    backend.fireReminder(alice.d.userId, id);
    await until(() async => alice.fired.isNotEmpty && alice2.fired.isNotEmpty, reason: 'both hear it');
    final f = alice.fired.single;
    expect((f.chatId, f.messageId, f.missed), (chatId, id, false));
    expect(await alice.reminders(chatId), isEmpty);
    expect(await alice2.reminders(chatId), isEmpty);
    expect(backend.reminderPushes, isEmpty, reason: 'devices with a socket get the frame, not a push');
    // The next sync doesn't show it again.
    await alice.sync.syncAll();
    expect(alice.fired, hasLength(1));
  });

  test('one that came while this device was away shows at the next open, once; one cleared elsewhere does not', () async {
    final (alice, _, chatId, id) = await chatWithMessage();
    final other = await alice.sync.sendText(chatId, 'and the plumber');
    await until(() async => (await alice.d.db.messageById(other))?.seq != null, reason: 'sent');
    final start = clock.now;
    await alice.sync.setReminder(chatId, id, inHours(1));
    await alice.sync.setReminder(chatId, other, inHours(5));
    await alice.sync.idle;
    alice.d.hub.drop(); // the app is closed
    clock.now = start.add(const Duration(hours: 1));
    backend.fireReminder(alice.d.userId, id);
    expect(backend.reminderPushes, [(alice.d.deviceId, id)], reason: 'pushed to the closed device');
    final phone = await backend.addDevice(alice.d.userId);
    await phone.api.clearReminder(chatId, other); // cleared on another device of mine, before its time
    clock.now = start.add(const Duration(hours: 3));
    await alice.d.hub.connect();
    await until(() async => alice.fired.isNotEmpty, reason: 'shown at open');
    await alice.sync.idle;
    expect([for (final f in alice.fired) (f.messageId, f.missed)], [(id, true)]);
    expect(await alice.reminders(chatId), isEmpty);
    await alice.sync.syncAll();
    expect(alice.fired, hasLength(1), reason: 'shown once');
  });

  test('reminders that come before anyone listens are handed over later', () async {
    final (alice, _, chatId, id) = await chatWithMessage();
    alice.sync.onReminder = null;
    await alice.sync.setReminder(chatId, id, inHours(1));
    backend.fireReminder(alice.d.userId, id);
    await until(() async => (await alice.reminders(chatId)).isEmpty, reason: 'handled');
    final late = <FiredReminder>[];
    alice.sync.onReminder = late.add;
    expect(late.map((f) => f.messageId), [id]);
  });

  test('a message that disappears takes my reminder with it', () async {
    final (alice, _, chatId, id) = await chatWithMessage();
    await alice.sync.setReminder(chatId, id, inHours(1));
    await alice.sync.purge([id]);
    expect(await alice.reminders(chatId), isEmpty);
  });

  test("a purge clears the server's reminder too, so it never comes for a message I no longer have", () async {
    final (alice, _, chatId, id) = await chatWithMessage();
    await alice.sync.setReminder(chatId, id, inHours(1));
    expect(backend.reminders[alice.d.userId]?.keys, [id]);
    await alice.sync.purge([id]);
    await until(() async => backend.reminders[alice.d.userId]?.isEmpty ?? true, reason: 'cleared on the server');
    await alice.sync.refreshReminders();
    expect(await alice.reminders(chatId), isEmpty, reason: 'not brought back by the next refresh');
  });

  test('a reminder after the message disappears from this device is refused', () async {
    final (alice, _, chatId, id) = await chatWithMessage();
    final expires = inHours(3);
    await alice.d.db.customStatement('UPDATE local_messages SET expires_at = ? WHERE id = ?', [expires.millisecondsSinceEpoch, id]);
    await expectLater(alice.sync.setReminder(chatId, id, inHours(4)), throwsA(isA<ReminderAfterExpiry>()));
    expect(backend.reminders[alice.d.userId] ?? const {}, isEmpty);
    await alice.sync.setReminder(chatId, id, inHours(2));
    expect(await alice.reminders(chatId), {id: inHours(2).millisecondsSinceEpoch});
  });
}
