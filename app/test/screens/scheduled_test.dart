// Scheduling from the composer (long-press or right-click on Send), the "Scheduled (N)" bar and its
// list (Send now, Edit, Delete), the time picker's presets, and "sent late" on my late ones.
import 'dart:convert';
import 'dart:typed_data';

import 'package:famchat/chat/chat_sync.dart';
import 'package:famchat/chat/db/chat_db.dart';
import 'package:famchat/chat/providers.dart';
import 'package:famchat/main.dart';
import 'package:famchat/media/photo_picker.dart';
import 'package:famchat/router.dart';
import 'package:famchat/screens/chats/time_picker_sheet.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind, kSecondaryMouseButton;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:material_ui/material_ui.dart';

import '../support/chat_harness.dart';
import '../support/fake_chat_backend.dart';

final png = Uint8List.fromList(img.encodePng(img.Image(width: 8, height: 6)));

void main() {
  late FakeChatBackend backend;
  late TestDevice alice, bob;

  setUp(() async {
    backend = FakeChatBackend();
    alice = await backend.addUser('Alice');
    bob = await backend.addUser('Bob');
  });

  ProviderContainer c(WidgetTester tester) => ProviderScope.containerOf(tester.element(find.byType(FamChatApp)));

  Future<(ScriptedHubLink, String)> openChat(WidgetTester tester, {List<Uint8List> picks = const []}) async {
    setWindow(tester, const Size(400, 800));
    final hub = await pumpChatApp(tester, alice, picker: (source) async => [for (final p in picks) PickedPhoto(p)]);
    final id = await inApp(tester, () => c(tester).read(chatSyncProvider)!.openDirect(bob.userId));
    c(tester).read(routerProvider).go('/chats/$id');
    await settle(tester);
    return (hub, id);
  }

  DateTime tomorrow9() {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day + 1, 9);
  }

  /// Long-press Send → "Schedule message" → "Tomorrow 9 AM".
  Future<void> scheduleTomorrow(WidgetTester tester, {String button = 'Send'}) async {
    await tester.longPress(find.byTooltip(button));
    await settle(tester);
    await tester.tap(find.byKey(const Key('schedule-message')));
    await settle(tester);
    expect(find.text('In 1 hour'), findsOneWidget);
    expect(find.text('Pick date and time'), findsOneWidget);
    await tester.tap(find.byKey(const Key('time-Tomorrow 9 AM')));
    await settle(tester);
  }

  /// Lets the snack bar (over the bar) go away.
  Future<void> snackGone(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 6));
    await settle(tester);
  }

  test('presets: tonight only until 7 PM, Monday unless that is tomorrow', () {
    final wed = DateTime(2026, 11, 18, 10, 30); // a Wednesday morning
    expect([for (final p in timePresets(wed)) p.label], ['In 1 hour', 'Tonight 8 PM', 'Tomorrow 9 AM', 'Monday 9 AM']);
    final presets = {for (final p in timePresets(wed)) p.label: p.at};
    expect(presets['In 1 hour'], DateTime(2026, 11, 18, 11, 30));
    expect(presets['Tonight 8 PM'], DateTime(2026, 11, 18, 20));
    expect(presets['Tomorrow 9 AM'], DateTime(2026, 11, 19, 9));
    expect(presets['Monday 9 AM'], DateTime(2026, 11, 23, 9));
    expect([for (final p in timePresets(DateTime(2026, 11, 18, 19, 5))) p.label], isNot(contains('Tonight 8 PM')));
    // Sunday: Monday is tomorrow, offered once.
    expect([for (final p in timePresets(DateTime(2026, 11, 22, 10))) p.label], ['In 1 hour', 'Tonight 8 PM', 'Tomorrow 9 AM']);
    // Monday: next week's.
    expect({for (final p in timePresets(DateTime(2026, 11, 23, 10))) p.label: p.at}['Monday 9 AM'], DateTime(2026, 11, 30, 9));
    final now = DateTime(2026, 11, 18, 10);
    expect(inScheduleWindow(now.add(const Duration(seconds: 30)), now), isFalse);
    expect(inScheduleWindow(now.add(const Duration(minutes: 1)), now), isTrue);
    expect(inScheduleWindow(now.add(const Duration(days: 367)), now), isFalse);
    expect(whenLabel(DateTime(2026, 11, 19, 9), h24: false, now: now), 'Tomorrow at 9:00 AM');
    expect(whenLabel(DateTime(2026, 11, 18, 20), h24: true, now: now), 'Today at 20:00');
    expect(whenLabel(DateTime(2027, 1, 2, 9), h24: false, now: now), 'Jan 2, 2027 at 9:00 AM');
  });

  chatTestWidgets('long-press Send schedules the text; the bar lists it; edit, send now and delete from the list', (tester) async {
    final (_, chatId) = await openChat(tester);
    await tester.enterText(find.byKey(const Key('composer')), 'see you tomorrow');
    await settle(tester);
    await scheduleTomorrow(tester);

    expect(find.textContaining('Scheduled for Tomorrow at'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'see you tomorrow'), findsNothing, reason: 'the composer is cleared');
    expect(backend.scheduled, hasLength(1));
    final id = backend.scheduled.keys.single;
    expect(backend.scheduledDto(id)!.deliverAt, tomorrow9().millisecondsSinceEpoch);
    expect(find.text('Scheduled (1)'), findsOneWidget);
    expect(find.text('see you tomorrow'), findsNothing, reason: 'not in the timeline');
    await snackGone(tester);

    await tester.tap(find.byKey(const Key('scheduled-bar')));
    await settle(tester);
    expect(find.descendant(of: find.byKey(Key('scheduled-$id')), matching: find.text('see you tomorrow')), findsOneWidget);

    // Edit the text.
    await tester.tap(find.byKey(Key('scheduled-menu-$id')));
    await settle(tester);
    await tester.tap(find.text('Edit'));
    await settle(tester);
    await tester.enterText(find.byKey(const Key('scheduled-edit-text')), 'see you at noon');
    await tester.tap(find.byKey(const Key('scheduled-edit-save')));
    await settle(tester);
    expect(find.descendant(of: find.byKey(Key('scheduled-$id')), matching: find.text('see you at noon')), findsOneWidget);
    final edited = (await inApp(tester, () => alice.db.scheduledById(id)))!;
    expect((jsonDecode(edited.body!) as Map)['text'], 'see you at noon');
    expect(jsonEncode(backend.scheduledDto(id)!.envelope), edited.envelope, reason: 'the server holds the new one');

    // Send now.
    await tester.tap(find.byKey(Key('scheduled-menu-$id')));
    await settle(tester);
    await tester.tap(find.text('Send now'));
    await settle(tester);
    expect(backend.scheduled, isEmpty);
    expect(backend.storedMessages(chatId).map((m) => m.id), [id]);
    expect(find.text('Nothing scheduled here.'), findsOneWidget);
    await tester.tapAt(const Offset(200, 50)); // close the sheet
    await settle(tester);
    await snackGone(tester);
    expect(find.text('Scheduled (1)'), findsNothing);

    // Schedule another and delete it.
    await tester.enterText(find.byKey(const Key('composer')), 'oops');
    await settle(tester);
    await scheduleTomorrow(tester);
    final second = backend.scheduled.keys.single;
    await snackGone(tester);
    await tester.tap(find.byKey(const Key('scheduled-bar')));
    await settle(tester);
    await tester.tap(find.byKey(Key('scheduled-menu-$second')));
    await settle(tester);
    await tester.tap(find.text('Delete'));
    await settle(tester);
    expect(backend.scheduled, isEmpty);
    expect(backend.calls, contains('DELETE /me/scheduled/$second'));
    expect(await inApp(tester, () => alice.db.scheduledById(second)), isNull);
  });

  chatTestWidgets('with nothing typed, the next send is scheduled: a staged photo and its caption', (tester) async {
    final (hub, chatId) = await openChat(tester, picks: [png]);
    // Empty composer: the mic is there; it offers scheduling too.
    await scheduleTomorrow(tester, button: 'Record voice message');
    expect(find.byKey(const Key('schedule-banner')), findsOneWidget);
    expect(find.textContaining('Scheduling for Tomorrow at'), findsOneWidget);

    await tester.tap(find.byTooltip('Attach'));
    await settle(tester);
    if (find.text('Photos and videos').evaluate().isNotEmpty) {
      await tester.tap(find.text('Photos and videos'));
      await settle(tester);
    }
    await tester.enterText(find.byKey(const Key('composer')), 'the view');
    await settle(tester);
    await tester.tap(find.byTooltip('Schedule'));
    await settle(tester);
    await settle(tester);

    expect(find.byKey(const Key('schedule-banner')), findsNothing, reason: 'one send uses it');
    expect(find.text('Scheduled (1)'), findsOneWidget);
    expect(hub.sent.where((f) => f['type'] == 'send'), isEmpty);
    final id = backend.scheduled.keys.single;
    final s = (await inApp(tester, () => alice.db.scheduledById(id)))!;
    expect((s.kind, s.onServer, (jsonDecode(s.body!) as Map)['caption']), ('photo', true, 'the view'));
    expect(alice.media.uploads, hasLength(2), reason: 'its blobs went up first');
    expect(backend.storedMessages(chatId), isEmpty);
  });

  chatTestWidgets('right-click on Send offers it too', (tester) async {
    await openChat(tester);
    await tester.enterText(find.byKey(const Key('composer')), 'hi');
    await settle(tester);
    final gesture = await tester.startGesture(tester.getCenter(find.byTooltip('Send')), kind: PointerDeviceKind.mouse, buttons: kSecondaryMouseButton);
    await gesture.up();
    await settle(tester);
    expect(find.byKey(const Key('schedule-message')), findsOneWidget);
    await tester.tapAt(const Offset(10, 10));
    await settle(tester);
    expect(backend.scheduled, isEmpty);
  });

  chatTestWidgets('my scheduled message that went out late says so, to me', (tester) async {
    final (_, chatId) = await openChat(tester);
    final now = DateTime.now().millisecondsSinceEpoch;
    await inApp(tester, () async {
      for (final (id, late) in [('01JLATE0000000000000000000', true), ('01JONTIME00000000000000000', false)]) {
        await alice.db.insertMessageIfAbsent(MessageRow(
          id: id,
          chatId: chatId,
          seq: late ? 1 : 2,
          senderUserId: alice.userId,
          senderDeviceId: alice.deviceId,
          kind: 'text',
          body: jsonEncode({'kind': 'text', 'text': late ? 'late one' : 'on time'}),
          targetId: null,
          envelope: null,
          createdAt: now,
          state: 'sent',
          scheduledFor: late ? now - const Duration(hours: 2).inMilliseconds : now,
        ));
      }
    });
    await settle(tester);
    expect(find.byKey(const Key('sent-late-01JLATE0000000000000000000')), findsOneWidget);
    expect(find.byKey(const Key('sent-late-01JONTIME00000000000000000')), findsNothing);
    expect(ChatSync.scheduleMax, const Duration(days: 366));
  });
}
