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

  /// Admin Michael signed in, Mom with one device; opens /family.
  Future<void> openFamily(WidgetTester tester, {bool operator = true}) async {
    await pumpApp(tester, server: server, kv: MemorySecureKv());
    await signInDirectly(tester, server, name: 'Michael', admin: true, operator: operator);
    final momKey = await tester.runAsync(() async => b64url(await publicKeyOf(await newIdentityKey())));
    momId = server.addUser('Mom', identityPub: momKey!);
    server.addDevice(momId, name: 'Phone');
    appRouter(tester).go('/settings/family');
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
    expect(find.text('You, Admin, 1 device'), findsOneWidget);
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

  Future<void> scrollTo(WidgetTester tester, Finder f) async {
    await tester.scrollUntilVisible(f, 200, scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
  }

  testWidgets('reviewer invite: create, copy, revoke', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
      return null;
    });
    await openFamily(tester);
    await scrollTo(tester, find.byKey(const Key('create-reviewer-invite')));
    expect(find.byKey(const Key('reviewer-link')), findsNothing);
    await tester.tap(find.byKey(const Key('create-reviewer-invite')));
    await tester.pumpAndSettle();
    final url = tester.widget<SelectableText>(find.byKey(const Key('reviewer-link'))).data!;
    expect(url, startsWith('https://famchat.dev/join#review.'));
    final invite = parseInviteToken(url)!;
    expect(isReviewerInvite(invite), isTrue);
    expect(server.invites[splitInvite(invite).token]!.reviewer, isTrue);
    await tester.ensureVisible(find.byKey(const Key('copy-reviewer-link')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('copy-reviewer-link')));
    await tester.pumpAndSettle();
    expect(copied, url);

    // Still there after leaving and coming back.
    appRouter(tester).go('/settings');
    await tester.pumpAndSettle();
    appRouter(tester).go('/settings/family');
    await tester.pumpAndSettle();
    await scrollTo(tester, find.byKey(const Key('reviewer-link')));
    expect(tester.widget<SelectableText>(find.byKey(const Key('reviewer-link'))).data, url);

    await tester.ensureVisible(find.byKey(const Key('revoke-reviewer-invite')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('revoke-reviewer-invite')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-revoke-reviewer')));
    await tester.pumpAndSettle();
    expect(server.invites[splitInvite(invite).token]!.revoked, isTrue);
    expect(find.byKey(const Key('reviewer-link')), findsNothing);
    expect(find.byKey(const Key('create-reviewer-invite')), findsOneWidget);
  });

  testWidgets('reviewer accounts are listed apart from the family and can be removed', (tester) async {
    final revKey = await tester.runAsync(() async => b64url(await publicKeyOf(await newIdentityKey())));
    final revId = server.addUser('Play Reviewer', identityPub: revKey!, reviewer: true);
    server.addDevice(revId, name: 'Pixel');
    await openFamily(tester);
    expect(find.text('2 people'), findsOneWidget, reason: 'the family count leaves reviewers out');
    expect(find.byKey(Key('family-user-$revId')), findsNothing);
    await scrollTo(tester, find.byKey(Key('reviewer-user-$revId')));
    expect(find.text('Reviewer accounts'), findsOneWidget);
    expect(find.text('Play Reviewer'), findsOneWidget);
    await tester.tap(find.byKey(Key('remove-reviewer-$revId')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-remove')));
    await tester.pumpAndSettle();
    expect(server.users[revId]!.deleted, isTrue);
    expect(find.byKey(Key('reviewer-user-$revId')), findsNothing);
    expect(find.text('Play Reviewer was removed'), findsOneWidget);
  });

  testWidgets('an admin who is not the operator sees no Remove action and no reviewer section', (tester) async {
    await openFamily(tester, operator: false);
    await tester.ensureVisible(find.byKey(Key('family-menu-$momId')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('family-menu-$momId')));
    await tester.pumpAndSettle();
    expect(find.text('Reset account'), findsOneWidget);
    expect(find.text('Make admin'), findsOneWidget);
    expect(find.text('Remove from family'), findsNothing);
    await tester.tapAt(const Offset(1, 1));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Media storage'), 200);
    expect(find.byKey(const Key('create-reviewer-invite')), findsNothing);
    expect(find.text('Reviewer accounts'), findsNothing);
  });

  testWidgets('the operator sees Remove and the reviewer section', (tester) async {
    await openFamily(tester, operator: true);
    await tester.ensureVisible(find.byKey(Key('family-menu-$momId')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('family-menu-$momId')));
    await tester.pumpAndSettle();
    expect(find.text('Remove from family'), findsOneWidget);
    await tester.tapAt(const Offset(1, 1));
    await tester.pumpAndSettle();
    await scrollTo(tester, find.byKey(const Key('create-reviewer-invite')));
    expect(find.byKey(const Key('create-reviewer-invite')), findsOneWidget);
  });

  testWidgets('members have no family screen', (tester) async {
    await pumpApp(tester, server: server, kv: MemorySecureKv());
    await signInDirectly(tester, server);
    expect(find.byKey(const Key('admin-setup-banner')), findsNothing);
    appRouter(tester).go('/settings/family');
    await tester.pumpAndSettle();
    expect(find.text('No chats yet'), findsOneWidget);
  });
}
