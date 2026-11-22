import 'dart:typed_data';

import 'package:famchat/chat/providers.dart';
import 'package:famchat/media/photo_picker.dart';
import 'package:image/image.dart' as img;
import 'package:famchat/chat/wire.dart';
import 'package:famchat/main.dart';
import 'package:famchat/router.dart';
import 'package:famchat/screens/chats/group_info_screen.dart';
import 'package:famchat/screens/chats/new_chat_screen.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../support/chat_harness.dart';
import '../support/fake_chat_backend.dart';
import '../support/fake_server.dart';

void main() {
  late FakeChatBackend backend;
  late TestDevice alice, bob, carol, dan;

  setUp(() async {
    backend = FakeChatBackend();
    alice = await backend.addUser('Alice');
    bob = await backend.addUser('Bob');
    carol = await backend.addUser('Carol');
    dan = await backend.addUser('Dan');
  });

  ProviderContainer c(WidgetTester tester) => ProviderScope.containerOf(tester.element(find.byType(FamChatApp)));

  Future<String> openInfo(WidgetTester tester, Future<String> Function(ProviderContainer) make, {MediaPicker? picker}) async {
    setWindow(tester, const Size(400, 800));
    await pumpChatApp(tester, alice, picker: picker);
    final id = await inApp(tester, () => make(c(tester)));
    c(tester).read(routerProvider).go('/chats/$id/info');
    await settle(tester);
    return id;
  }

  chatTestWidgets('members are listed and the creator can remove one', (tester) async {
    final id = await openInfo(tester, (c) => c.read(chatSyncProvider)!.createGroup('Cousins', [bob.userId, carol.userId]));
    expect(find.text('Cousins'), findsWidgets);
    expect(find.text('Alice (you)'), findsOneWidget);
    expect(find.text('Bob'), findsOneWidget);
    await tester.tap(find.byTooltip('Remove Carol'));
    await settle(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
    await settle(tester);
    expect(backend.chatDto(id).members.map((m) => m.userId), isNot(contains(carol.userId)));
    expect(backend.chatDto(id).currentEpoch, 2);
    expect(find.text('Carol'), findsNothing);
  });

  test('muteLabel', () {
    final now = DateTime(2026, 11, 16, 9, 30);
    expect(muteLabel(null, now, h24: true), 'Off');
    expect(muteLabel(DateTime(2026, 11, 16, 9).millisecondsSinceEpoch, now, h24: true), 'Off', reason: 'expired');
    expect(muteLabel(DateTime(2026, 11, 16, 10, 30).millisecondsSinceEpoch, now, h24: true), 'Until 10:30');
    expect(muteLabel(DateTime(2026, 11, 17, 8, 5).millisecondsSinceEpoch, now, h24: true), 'Until tomorrow, 08:05');
    expect(muteLabel(DateTime(2026, 11, 17, 8, 5).millisecondsSinceEpoch, now, h24: false), 'Until tomorrow, 8:05 AM');
    expect(muteLabel(DateTime(2026, 11, 23, 9, 30).millisecondsSinceEpoch, now, h24: true), 'Until 11/23');
    expect(muteLabel(muteForever, now, h24: true), 'Until you turn them back on');
  });

  chatTestWidgets('muting a chat for a while, then unmuting', (tester) async {
    final id = await openInfo(tester, (c) => c.read(chatSyncProvider)!.openDirect(bob.userId));
    expect(find.text('Mute notifications'), findsOneWidget);
    await tester.tap(find.text('Mute notifications'));
    await settle(tester);
    await tester.tap(find.text('For 8 hours'));
    await settle(tester);
    final until = (await inApp(tester, () => alice.db.chatById(id)))!.mutedUntil!;
    expect(until, greaterThan(DateTime.now().add(const Duration(hours: 7)).millisecondsSinceEpoch));
    expect(backend.chatDto(id).members, isNotEmpty);
    expect(find.textContaining('Until'), findsOneWidget);
    await tester.tap(find.text('Mute notifications'));
    await settle(tester);
    await tester.tap(find.text('Unmute'));
    await settle(tester);
    expect((await inApp(tester, () => alice.db.chatById(id)))!.mutedUntil, isNull);
    expect(find.text('Off'), findsOneWidget);
  });

  chatTestWidgets('leaving returns to the chat list', (tester) async {
    final id = await openInfo(tester, (c) => c.read(chatSyncProvider)!.createGroup('Cousins', [bob.userId, carol.userId]));
    await tester.ensureVisible(find.text('Leave group'));
    await settle(tester);
    await tester.tap(find.text('Leave group'));
    await settle(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Leave'));
    await settle(tester);
    expect(backend.chatDto(id).members.map((m) => m.userId), isNot(contains(alice.userId)));
    expect(find.text('No chats yet'), findsOneWidget);
  });

  chatTestWidgets('adding people to a group', (tester) async {
    final id = await openInfo(tester, (c) => c.read(chatSyncProvider)!.createGroup('Cousins', [bob.userId]));
    await tester.tap(find.text('Add people'));
    await settle(tester);
    expect(find.text('Bob'), findsNothing); // already a member
    await tester.tap(find.text('Dan'));
    await settle(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await settle(tester);
    expect(backend.chatDto(id).members.map((m) => m.userId), contains(dan.userId));
    expect(backend.hasWrap(id, 1, dan.deviceId), isTrue);
  });

  chatTestWidgets('adding from a 1:1 starts a new group with that person', (tester) async {
    await openInfo(tester, (c) => c.read(chatSyncProvider)!.openDirect(bob.userId));
    expect(find.text('Leave group'), findsNothing);
    await tester.tap(find.text('Add people'));
    await settle(tester);
    expect(find.byType(NewChatScreen), findsOneWidget);
    expect(tester.widget<CheckboxListTile>(find.widgetWithText(CheckboxListTile, 'Bob')).value, isTrue);
  });

  chatTestWidgets('a multi-family user sees which family the group is in', (tester) async {
    setWindow(tester, const Size(400, 800));
    final server = FakeServer()..family1Name = 'Hearth';
    server.extraFamilies.add({
      'id': 10, 'name': 'Smiths', 'status': 'approved', 'role': 'member', 'owner': false, 'ownerId': 'x', 'memberCount': 3, 'createdAt': 1,
    });
    backend.addFamilyRole(alice.userId, const FamilyRoleDto(id: 10, admin: false));
    backend.addFamilyRole(bob.userId, const FamilyRoleDto(id: 10, admin: false));
    await pumpChatApp(tester, alice, server: server);
    final id = await inApp(tester, () => c(tester).read(chatSyncProvider)!.createGroup('Cousins', [bob.userId], familyId: 10));
    c(tester).read(routerProvider).go('/chats/$id/info');
    await settle(tester);
    expect(find.text('Family: Smiths'), findsOneWidget);
  });

  chatTestWidgets('a single-family user sees no family line', (tester) async {
    await openInfo(tester, (c) => c.read(chatSyncProvider)!.createGroup('Cousins', [bob.userId]));
    expect(find.textContaining('Family:'), findsNothing);
  });

  chatTestWidgets('any member renames the group', (tester) async {
    final id = await openInfo(tester, (c) => c.read(chatSyncProvider)!.createGroup('Cousins', [bob.userId]));
    await tester.tap(find.byKey(const Key('rename-group')));
    await settle(tester);
    await tester.enterText(find.byKey(const Key('rename-group-field')), '  The Cousins ');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await settle(tester);
    expect(backend.chatDto(id).title, 'The Cousins');
    expect(find.text('The Cousins'), findsWidgets);
  });

  chatTestWidgets('a direct chat has no rename or photo button', (tester) async {
    await openInfo(tester, (c) => c.read(chatSyncProvider)!.openDirect(bob.userId));
    expect(find.byKey(const Key('rename-group')), findsNothing);
    expect(find.bySemanticsLabel('Change group photo'), findsNothing);
  });

  chatTestWidgets('set a group photo, then remove it', (tester) async {
    final png = Uint8List.fromList(img.encodePng(img.Image(width: 12, height: 8)));
    final id = await openInfo(tester, (c) => c.read(chatSyncProvider)!.createGroup('Cousins', [bob.userId]),
        picker: (source) async => [PickedPhoto(png)]);
    expect(find.byKey(const Key('avatar-photo')), findsNothing);
    await tester.tap(find.byKey(const Key('group-photo')));
    await settle(tester);
    await tester.tap(find.text('Choose a photo'));
    await settle(tester);
    expect(backend.chatDto(id).avatarKey, isNotNull);
    expect(find.byKey(const Key('avatar-photo')), findsOneWidget);

    await tester.tap(find.byKey(const Key('group-photo')));
    await settle(tester);
    await tester.tap(find.text('Remove photo'));
    await settle(tester);
    expect(backend.chatDto(id).avatarKey, isNull);
    expect(find.byKey(const Key('avatar-photo')), findsNothing);
  });

  chatTestWidgets('members who are offline show when they were last seen', (tester) async {
    final id = await openInfo(tester, (c) => c.read(chatSyncProvider)!.createGroup('Cousins', [bob.userId, carol.userId]));
    await inApp(tester, () => alice.db.setLastSeen(bob.userId, DateTime.now().subtract(const Duration(minutes: 5)).millisecondsSinceEpoch));
    await settle(tester);
    expect(find.textContaining('Last seen today at'), findsOneWidget);
    expect(id, isNotEmpty);
  });
}
