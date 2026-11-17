import 'package:famchat/chat/providers.dart';
import 'package:famchat/crypto/encoding.dart';
import 'package:famchat/crypto/keys.dart';
import 'package:famchat/session/invite_link.dart';
import 'package:famchat/session/secure_kv.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../support/app_harness.dart';
import '../support/fake_server.dart';

void main() {
  late FakeServer server;
  late String momId;

  setUp(() async {
    server = FakeServer();
  });

  /// Admin Michael signed in, Mom with one device; opens family 1's screen.
  Future<void> openFamily(WidgetTester tester, {bool operator = true}) async {
    await pumpApp(tester, server: server, kv: MemorySecureKv());
    await signInDirectly(tester, server, name: 'Michael', admin: true, operator: operator);
    final momKey = await tester.runAsync(() async => b64url(await publicKeyOf(await newIdentityKey())));
    momId = server.addUser('Mom', identityPub: momKey!);
    server.addDevice(momId, name: 'Phone');
    appRouter(tester).go('/settings/families/1');
    await tester.pumpAndSettle();
  }

  Future<void> menu(WidgetTester tester, String userId, String item) async {
    await tester.ensureVisible(find.byKey(Key('family-menu-$userId')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('family-menu-$userId')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(item).last);
    await tester.pumpAndSettle();
  }

  testWidgets('lists the family with admins and devices', (tester) async {
    await openFamily(tester);
    expect(find.text('Michael'), findsOneWidget);
    expect(find.text('You, Owner, 1 device'), findsOneWidget);
    expect(find.text('Mom'), findsOneWidget);
    expect(find.text('1 device'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Media storage'), 200);
    expect(find.text('Media storage'), findsOneWidget, reason: 'usage screen linked');
  });

  testWidgets('former people are not listed as family', (tester) async {
    await openFamily(tester);
    final key = await tester.runAsync(() async => b64url(await publicKeyOf(await newIdentityKey())));
    final exId = server.addUser('Ex Cousin', identityPub: key!);
    server.users[exId]!.former = true;
    await tester.tap(find.byTooltip('Refresh'));
    await tester.pumpAndSettle();
    expect(find.text('Mom'), findsOneWidget);
    expect(find.text('Ex Cousin'), findsNothing);
  });

  testWidgets('reset needs confirmation, then shows the new link', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
      return null;
    });
    await openFamily(tester);
    await menu(tester, momId, 'Reset account');
    expect(find.text("Reset Mom's account?"), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(server.users[momId]!.resets, isEmpty);

    await menu(tester, momId, 'Reset account');
    await tester.tap(find.byKey(const Key('confirm-reset')));
    await tester.pumpAndSettle();
    expect(server.users[momId]!.resets, hasLength(1));
    expect(server.liveDevices(momId), isEmpty);
    final url = tester.widget<SelectableText>(find.byKey(const Key('reset-link'))).data!;
    final parts = splitInvite(parseInviteToken(url)!);
    expect(parts.claimSeed, isNotNull);
    await tester.tap(find.byKey(const Key('copy-reset-link')));
    await tester.pumpAndSettle();
    expect(copied, url);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.text('No devices'), findsOneWidget);
  });

  testWidgets('make admin, and the second-admin prompt goes away', (tester) async {
    await openFamily(tester);
    expect(find.byKey(const Key('second-admin-card')), findsOneWidget);
    await menu(tester, momId, 'Make admin');
    await tester.tap(find.byKey(const Key('confirm-admin')));
    await tester.pumpAndSettle();
    expect(server.users[momId]!.isAdmin, isTrue);
    expect(find.byKey(const Key('second-admin-card')), findsNothing);
    expect(find.text('Admin, 1 device'), findsOneWidget);
  });

  testWidgets('recovery code is shown once with copy and a print view', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
      return null;
    });
    await openFamily(tester);
    expect(find.byKey(const Key('recovery-code-card')), findsOneWidget);
    await tester.tap(find.byKey(const Key('open-recovery-code')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('create-recovery-code')));
    await tester.pumpAndSettle();
    final shown = tester.widget<SelectableText>(find.byKey(const Key('recovery-code'))).data!;
    expect(shown, matches(RegExp(r'^([0-9A-Z]{5}-){4}[0-9A-Z]{5}$')));
    final me = server.users.values.firstWhere((u) => u.name == 'Michael');
    expect(me.recoveryPub, isNotNull);
    expect(me.recoveryPub, isNot(contains(shown.replaceAll('-', ''))));
    await tester.tap(find.byKey(const Key('copy-recovery-code')));
    await tester.pumpAndSettle();
    expect(copied, shown);
    await tester.tap(find.byKey(const Key('print-recovery-code')));
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(find.byKey(const Key('printed-recovery-code'))).data, shown);
    await tester.tap(find.byType(CloseButton));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('recovery-code-saved')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('recovery-code-card')), findsNothing);
    expect(find.byKey(const Key('new-recovery-code')), findsOneWidget);
  });

  testWidgets('home asks admins to finish setup until the code is saved', (tester) async {
    await pumpApp(tester, server: server, kv: MemorySecureKv());
    await signInDirectly(tester, server, name: 'Michael', admin: true);
    expect(find.byKey(const Key('admin-setup-banner')), findsOneWidget);
    await tester.tap(find.text('Set up'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('recovery-code-card')), findsOneWidget);
  });

  testWidgets('reviewer accounts are not family, and their section lives on the operator screen', (tester) async {
    final revKey = await tester.runAsync(() async => b64url(await publicKeyOf(await newIdentityKey())));
    final revId = server.addUser('Play Reviewer', identityPub: revKey!, reviewer: true);
    await openFamily(tester);
    expect(find.text('2 people'), findsOneWidget, reason: 'the family count leaves reviewers out');
    expect(find.byKey(Key('family-user-$revId')), findsNothing);
    await tester.scrollUntilVisible(find.text('Media storage'), 200);
    expect(find.byKey(const Key('create-reviewer-invite')), findsNothing);
    expect(find.text('Reviewer accounts'), findsNothing);
  });

  testWidgets('an admin who is not the operator sees no Delete action', (tester) async {
    await openFamily(tester, operator: false);
    await tester.ensureVisible(find.byKey(Key('family-menu-$momId')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('family-menu-$momId')));
    await tester.pumpAndSettle();
    expect(find.text('Reset account'), findsOneWidget);
    expect(find.text('Make admin'), findsOneWidget);
    expect(find.text('Remove from Family'), findsOneWidget);
    expect(find.text('Delete account'), findsNothing);
    await tester.tapAt(const Offset(1, 1));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Media storage'), 200);
    expect(find.byKey(const Key('create-reviewer-invite')), findsNothing);
  });

  testWidgets('the operator deletes an account', (tester) async {
    await openFamily(tester, operator: true);
    await menu(tester, momId, 'Delete account');
    expect(find.text("Delete Mom's account?"), findsOneWidget);
    await tester.tap(find.byKey(const Key('confirm-delete')));
    await tester.pumpAndSettle();
    expect(server.users[momId]!.deleted, isTrue);
    expect(find.text('Mom'), findsNothing);
  });

  testWidgets('the old family route opens family 1; members are sent home from it', (tester) async {
    await openFamily(tester);
    appRouter(tester).go('/settings/family');
    await tester.pumpAndSettle();
    expect(appRouter(tester).state.uri.path, '/settings/families/1');
  });

  testWidgets('a member of family 1 sees the people but no admin actions', (tester) async {
    await pumpApp(tester, server: server, kv: MemorySecureKv());
    await signInDirectly(tester, server);
    expect(find.byKey(const Key('admin-setup-banner')), findsNothing);
    appRouter(tester).go('/settings/families/1');
    await tester.pumpAndSettle();
    expect(find.text('You, 1 device'), findsOneWidget);
    expect(find.byType(PopupMenuButton<String>), findsOneWidget, reason: 'only the app bar overflow');
    expect(find.text('Invite someone'), findsNothing);
    expect(find.text('Media storage'), findsNothing);
    expect(find.byTooltip('Rename'), findsNothing);
    appRouter(tester).go('/settings/family');
    await tester.pumpAndSettle();
    expect(find.text('No chats yet'), findsOneWidget);
  });

  group('another family', () {
    late String dadId, kidId;

    /// Family 2 ("Joneses"): Michael with [role], Dad its other admin, Kid a member. Mom is only in
    /// family 1.
    Future<void> openFamily2(WidgetTester tester, {String role = 'admin', bool owner = false, bool dadAdmin = true}) async {
      server.extraFamilies.add(
          {'id': 2, 'name': 'Joneses', 'status': 'approved', 'role': role, 'owner': owner, 'memberCount': 3, 'createdAt': 2});
      await pumpApp(tester, server: server, kv: MemorySecureKv());
      await signInDirectly(tester, server, name: 'Michael', admin: true, operator: false);
      server.users.values.singleWhere((u) => u.name == 'Michael').familyRoles[2] = role;
      Future<String> key() async => b64url(await publicKeyOf(await newIdentityKey()));
      final keys = (await tester.runAsync(() async => [await key(), await key(), await key()]))!;
      momId = server.addUser('Mom', identityPub: keys[0]);
      dadId = server.addUser('Dad', identityPub: keys[1]);
      kidId = server.addUser('Kid', identityPub: keys[2]);
      server.users[dadId]!
        ..inFamily1 = false
        ..familyRoles[2] = dadAdmin ? 'admin' : 'member';
      server.users[kidId]!
        ..inFamily1 = false
        ..familyRoles[2] = 'member';
      appRouter(tester).go('/settings/families/2');
      await tester.pumpAndSettle();
    }

    Future<void> openMenu(WidgetTester tester, String userId) async {
      await tester.ensureVisible(find.byKey(Key('family-menu-$userId')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('family-menu-$userId')));
      await tester.pumpAndSettle();
    }

    Future<void> leave(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('family-overflow')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Leave Joneses'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm-leave')));
      await tester.pumpAndSettle();
    }

    testWidgets("lists only family 2's members, with their roles", (tester) async {
      await openFamily2(tester);
      expect(find.text('Joneses'), findsOneWidget);
      expect(find.text('3 people'), findsOneWidget);
      expect(find.text('Michael'), findsOneWidget);
      expect(find.text('You, Admin, 1 device'), findsOneWidget);
      expect(find.text('Dad'), findsOneWidget);
      expect(find.text('Admin, No devices'), findsOneWidget);
      expect(find.text('Kid'), findsOneWidget);
      expect(find.text('Mom'), findsNothing);
    });

    testWidgets('a member sees no admin actions', (tester) async {
      await openFamily2(tester, role: 'member');
      expect(find.text('You, 1 device'), findsOneWidget);
      expect(find.byKey(Key('family-menu-$kidId')), findsNothing);
      expect(find.byKey(Key('family-menu-$dadId')), findsNothing);
      expect(find.text('Invite someone'), findsNothing);
      expect(find.byKey(const Key('second-admin-card')), findsNothing);
      expect(find.byTooltip('Rename'), findsNothing);
    });

    testWidgets('an admin removes a member, but not another admin', (tester) async {
      await openFamily2(tester);
      await openMenu(tester, dadId);
      expect(find.text('Reset account'), findsOneWidget);
      expect(find.text('Remove from Joneses'), findsNothing);
      expect(find.text('Remove admin'), findsNothing, reason: 'only the owner demotes');
      expect(find.text('Make admin'), findsNothing);
      await tester.tapAt(const Offset(1, 1));
      await tester.pumpAndSettle();

      await openMenu(tester, kidId);
      await tester.tap(find.text('Remove from Joneses'));
      await tester.pumpAndSettle();
      expect(find.text('Remove Kid from Joneses?'), findsOneWidget);
      await tester.tap(find.byKey(const Key('confirm-remove')));
      await tester.pumpAndSettle();
      expect(server.log, contains('DELETE /api/families/2/members/$kidId -> 204'));
      expect(server.users[kidId]!.deleted, isFalse, reason: 'the account stays');
      expect(find.text('Kid'), findsNothing);
      expect(find.text('Kid was removed from Joneses'), findsOneWidget);
    });

    testWidgets('the owner demotes an admin', (tester) async {
      await openFamily2(tester, owner: true);
      expect(find.text('You, Owner, 1 device'), findsOneWidget);
      await openMenu(tester, dadId);
      await tester.tap(find.text('Remove admin'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm-demote')));
      await tester.pumpAndSettle();
      expect(server.log, contains('DELETE /api/families/2/admins/$dadId -> 204'));
      expect(server.users[dadId]!.familyRoles[2], 'member');
      expect(find.text('No devices'), findsNWidgets(2));
    });

    testWidgets('make admin signs a v2 promotion for family 2', (tester) async {
      await openFamily2(tester);
      await openMenu(tester, kidId);
      await tester.tap(find.text('Make admin'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm-admin')));
      await tester.pumpAndSettle();
      // The fake server checks the signature is a v2 promotion bound to family 2.
      expect(server.log, contains('POST /api/families/2/admins/$kidId -> 204'));
      expect(server.users[kidId]!.familyRoles[2], 'admin');
      expect(find.text('Admin, No devices'), findsNWidgets(2));
    });

    testWidgets('the last admin is told to make another admin before leaving', (tester) async {
      await openFamily2(tester, dadAdmin: false);
      await leave(tester);
      expect(server.log, contains('DELETE /api/families/2/members/${server.users.values.singleWhere((u) => u.name == 'Michael').id} -> 409'));
      expect(find.text("You're the last admin. Make someone else an admin first."), findsOneWidget);
      expect(appRouter(tester).state.uri.path, '/settings/families/2');
    });

    testWidgets('leaving goes back to the families list', (tester) async {
      await openFamily2(tester, role: 'member');
      await leave(tester);
      expect(appRouter(tester).state.uri.path, '/settings/families');
      expect(find.text('Joneses'), findsNothing);
    });

    testWidgets('an admin renames the family', (tester) async {
      await openFamily2(tester);
      await tester.tap(find.byTooltip('Rename'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('family-rename-field')), ' Smiths ');
      await tester.tap(find.byKey(const Key('family-rename-save')));
      await tester.pumpAndSettle();
      expect(server.extraFamilies.single['name'], 'Smiths');
      expect(find.text('Smiths'), findsOneWidget);
    });

    testWidgets('media storage is only on family 1', (tester) async {
      await openFamily2(tester);
      await tester.scrollUntilVisible(find.text('Invite someone'), 200);
      expect(find.text('Media storage'), findsNothing);
    });

    testWidgets('a pending family shows only its name, rename and leave', (tester) async {
      await openFamily2(tester);
      server.extraFamilies.add(
          {'id': 4, 'name': 'Club', 'status': 'pending', 'role': 'admin', 'owner': true, 'memberCount': 1, 'createdAt': 3});
      await appContainer(tester).read(familiesProvider.notifier).refresh();
      appRouter(tester).go('/settings/families/4');
      await tester.pumpAndSettle();
      expect(find.text('Club'), findsOneWidget);
      expect(find.text('Waiting for approval'), findsOneWidget);
      expect(find.text('Michael'), findsNothing);
      expect(find.text('Invite someone'), findsNothing);
      expect(find.byKey(const Key('recovery-code-card')), findsNothing);
      expect(find.byTooltip('Rename'), findsOneWidget);
      await tester.tap(find.byKey(const Key('family-overflow')));
      await tester.pumpAndSettle();
      expect(find.text('Leave Club'), findsOneWidget);
    });
  });

  testWidgets('an unknown family shows not found', (tester) async {
    await pumpApp(tester, server: server, kv: MemorySecureKv());
    await signInDirectly(tester, server);
    appRouter(tester).go('/settings/families/99');
    await tester.pumpAndSettle();
    expect(find.text('Family not found'), findsOneWidget);
    appRouter(tester).go('/settings/families/abc');
    await tester.pumpAndSettle();
    expect(find.text('Family not found'), findsOneWidget);
  });
}
