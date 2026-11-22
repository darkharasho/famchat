// "Remind me" on a message: the bell (mine alone), changing and clearing it, the reminder coming
// (shown, bell gone, Open goes to the message) and one missed while the app was closed.
import 'dart:convert';

import 'package:famchat/chat/db/chat_db.dart';
import 'package:famchat/chat/providers.dart';
import 'package:famchat/main.dart';
import 'package:famchat/push/preview_setting.dart';
import 'package:famchat/router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import '../support/chat_harness.dart';
import '../support/fake_chat_backend.dart';

const msgId = '01JREM00000000000000000001';

void main() {
  late FakeChatBackend backend;
  late TestDevice alice, bob;

  setUp(() async {
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    backend = FakeChatBackend();
    alice = await backend.addUser('Alice');
    bob = await backend.addUser('Bob');
  });

  ProviderContainer c(WidgetTester tester) => ProviderScope.containerOf(tester.element(find.byType(FamChatApp)));

  /// Alice's app on a chat with Bob holding Bob's "call the dentist" (on the server and here);
  /// [reminderAt]: a reminder of mine already cached here.
  Future<(ScriptedHubLink, String)> openChat(WidgetTester tester, {int? reminderAt}) async {
    setWindow(tester, const Size(400, 800));
    final hub = await pumpChatApp(tester, alice);
    final chatId = await inApp(tester, () => c(tester).read(chatSyncProvider)!.openDirect(bob.userId));
    final stored = backend.injectMessage(chatId, id: msgId, senderUserId: bob.userId, senderDeviceId: bob.deviceId, envelope: const {}, fanOut: false);
    await inApp(tester, () async {
      await alice.db.insertMessageIfAbsent(MessageRow(
        id: msgId,
        chatId: chatId,
        seq: stored.seq,
        senderUserId: bob.userId,
        senderDeviceId: bob.deviceId,
        kind: 'text',
        body: jsonEncode({'kind': 'text', 'text': 'call the dentist'}),
        targetId: null,
        envelope: null,
        createdAt: DateTime.now().millisecondsSinceEpoch,
        state: 'sent',
      ));
      await alice.db.setSyncedSeq(chatId, stored.seq);
      if (reminderAt != null) await alice.db.putReminder(chatId, msgId, reminderAt);
    });
    c(tester).read(routerProvider).go('/chats/$chatId');
    await settle(tester);
    return (hub, chatId);
  }

  Future<void> snackGone(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 6));
    await settle(tester);
  }

  Future<void> remindTomorrow(WidgetTester tester) async {
    await tester.longPress(find.text('call the dentist'));
    await settle(tester);
    await tester.tap(find.text('Remind me'));
    await settle(tester);
    await tester.tap(find.byKey(const Key('time-Tomorrow 9 AM')));
    await settle(tester);
  }

  chatTestWidgets('Remind me sets it; the bell shows, only for me; tapping it clears it', (tester) async {
    final (_, chatId) = await openChat(tester);
    expect(find.byKey(const Key('bell-$msgId')), findsNothing);
    await remindTomorrow(tester);

    final n = DateTime.now();
    final at = DateTime(n.year, n.month, n.day + 1, 9).millisecondsSinceEpoch;
    expect(backend.reminders[alice.userId], {msgId: isA<Object>()});
    expect(backend.reminders[alice.userId]![msgId]!.at, at);
    expect(backend.reminders[bob.userId], isNull, reason: "Bob's view of the message has no reminder");
    expect(await inApp(tester, () => bob.api.reminders()), isEmpty);
    expect(find.byKey(const Key('bell-$msgId')), findsOneWidget);
    expect(find.textContaining('Reminder set for Tomorrow at'), findsOneWidget);
    await snackGone(tester);

    // The action now says "Change reminder"; the bell opens the same choices.
    await tester.longPress(find.text('call the dentist'));
    await settle(tester);
    expect(find.text('Change reminder'), findsOneWidget);
    await tester.tapAt(const Offset(200, 50));
    await settle(tester);

    await tester.tap(find.byKey(const Key('bell-$msgId')));
    await settle(tester);
    await tester.tap(find.byKey(const Key('reminder-clear')));
    await settle(tester);
    expect(backend.reminders[alice.userId], isEmpty);
    expect(find.byKey(const Key('bell-$msgId')), findsNothing);
    expect(await inApp(tester, () => alice.db.allReminders()), isEmpty);
    expect(chatId, isNotEmpty);
  });

  chatTestWidgets('when it comes it shows, the bell goes, and Open goes to the message', (tester) async {
    final (hub, chatId) = await openChat(tester);
    await remindTomorrow(tester);
    await snackGone(tester);
    c(tester).read(routerProvider).go('/');
    await settle(tester);

    hub.emit({'type': 'reminder', 'chatId': chatId, 'messageId': msgId, 'at': DateTime.now().millisecondsSinceEpoch});
    await settle(tester);
    expect(find.text('Reminder: Message from Bob'), findsOneWidget, reason: 'previews are off: who and where only');
    expect(await inApp(tester, () => alice.db.allReminders()), isEmpty);

    await tester.tap(find.text('Open'));
    await settle(tester);
    final router = c(tester).read(routerProvider);
    expect(router.routerDelegate.currentConfiguration.uri.toString(), '/chats/$chatId?m=$msgId');
    expect(find.text('call the dentist'), findsOneWidget);
    expect(find.byKey(const Key('bell-$msgId')), findsNothing);
  });

  chatTestWidgets('with previews on it shows the text', (tester) async {
    await writePreviewsOn(true);
    final (hub, chatId) = await openChat(tester);
    hub.emit({'type': 'reminder', 'chatId': chatId, 'messageId': msgId, 'at': 1});
    await settle(tester);
    expect(find.text('Reminder: call the dentist'), findsOneWidget);
  });

  chatTestWidgets('one that came while the app was closed shows at the next open', (tester) async {
    final past = DateTime.now().subtract(const Duration(hours: 1)).millisecondsSinceEpoch;
    final (hub, _) = await openChat(tester, reminderAt: past);
    expect(find.byKey(const Key('bell-$msgId')), findsOneWidget, reason: 'cached until the server is asked');
    hub.setConnected(true); // the sync finds the server no longer lists it
    await settle(tester);
    expect(find.text('Reminder: Message from Bob'), findsOneWidget);
    expect(find.byKey(const Key('bell-$msgId')), findsNothing);
    hub.setConnected(false);
    await settle(tester);
  });
}
