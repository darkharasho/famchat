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

  setUp(() => server = FakeServer());

  Map<String, Object?> request(int id, String name, {String? creator = 'Gran', String status = 'pending'}) => {
        'id': id,
        'name': name,
        'status': status,
        'createdAt': DateTime(2026, 11, 3).millisecondsSinceEpoch,
        'decidedAt': null,
        'creator': creator == null ? null : {'id': 'u-$id', 'name': creator},
        'memberCount': 1,
      };

  Future<void> openOperator(WidgetTester tester, {bool operator = true}) async {
    await pumpApp(tester, server: server, kv: MemorySecureKv());
    await signInDirectly(tester, server, name: 'Michael', admin: true, operator: operator);
    appRouter(tester).go('/settings/operator');
    await tester.pumpAndSettle();
  }

  Future<void> scrollTo(WidgetTester tester, Finder f) async {
    await tester.scrollUntilVisible(f, 200, scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
  }

  testWidgets('lists the pending requests with who asked and when', (tester) async {
    server.operatorRequests.addAll([request(4, 'Club'), request(5, 'Choir', creator: null), request(6, 'Old', status: 'declined')]);
    await openOperator(tester);
    expect(find.text('Family requests'), findsWidgets);
    expect(find.text('Club'), findsOneWidget);
    expect(find.text('Requested by Gran on Tue, Nov 3'), findsOneWidget);
    expect(find.text('Choir'), findsOneWidget);
    expect(find.text('Requested on Tue, Nov 3'), findsOneWidget);
    expect(find.text('Old'), findsNothing, reason: 'only pending requests wait');
  });

  testWidgets('says so when nothing is waiting', (tester) async {
    await openOperator(tester);
    expect(find.text('No requests waiting'), findsOneWidget);
  });

  testWidgets('approve calls the API and removes the row', (tester) async {
    server.operatorRequests.addAll([request(4, 'Club'), request(5, 'Choir')]);
    await openOperator(tester);
    await tester.tap(find.byKey(const Key('approve-family-4')));
    await tester.pumpAndSettle();
    expect(server.log, contains('POST /api/operator/families/4/approve -> 204'));
    expect(server.operatorRequests.first['status'], 'approved');
    expect(find.text('Club'), findsNothing);
    expect(find.text('Choir'), findsOneWidget);
  });

  testWidgets('decline asks first, and Cancel declines nothing', (tester) async {
    server.operatorRequests.add(request(4, 'Club'));
    await openOperator(tester);
    await tester.tap(find.byKey(const Key('decline-family-4')));
    await tester.pumpAndSettle();
    expect(find.text('Decline Club?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(server.operatorRequests.single['status'], 'pending');
    expect(find.text('Club'), findsOneWidget);

    await tester.tap(find.byKey(const Key('decline-family-4')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-decline')));
    await tester.pumpAndSettle();
    expect(server.log, contains('POST /api/operator/families/4/decline -> 204'));
    expect(server.operatorRequests.single['status'], 'declined');
    expect(find.text('Club'), findsNothing);
  });

  testWidgets('a request someone else already decided says so and leaves the list', (tester) async {
    server.operatorRequests.add(request(4, 'Club'));
    await openOperator(tester);
    server.operatorRequests.single['status'] = 'approved';
    await tester.tap(find.byKey(const Key('approve-family-4')));
    await tester.pumpAndSettle();
    expect(find.text('Already decided.'), findsOneWidget);
    expect(find.text('Club'), findsNothing);
  });

  group('Settings', () {
    Future<void> openSettings(WidgetTester tester, {required bool operator}) async {
      await pumpApp(tester, server: server, kv: MemorySecureKv());
      await signInDirectly(tester, server, name: 'Michael', admin: true, operator: operator);
      appRouter(tester).go('/settings');
      await tester.pumpAndSettle();
    }

    testWidgets('the operator has a Family requests tile with the count', (tester) async {
      server.operatorRequests.addAll([request(4, 'Club'), request(5, 'Choir')]);
      await openSettings(tester, operator: true);
      expect(find.descendant(of: find.byKey(const Key('settings-operator')), matching: find.text('Family requests')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('settings-operator')), matching: find.text('2 waiting')), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('settings-operator')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('settings-operator')));
      await tester.pumpAndSettle();
      expect(appRouter(tester).state.uri.path, '/settings/operator');
    });

    testWidgets('with none pending it says None waiting', (tester) async {
      await openSettings(tester, operator: true);
      expect(find.descendant(of: find.byKey(const Key('settings-operator')), matching: find.text('None waiting')), findsOneWidget);
    });

    testWidgets('a non-operator has no tile and is sent back from the route', (tester) async {
      await openSettings(tester, operator: false);
      expect(find.byKey(const Key('settings-operator')), findsNothing);
      appRouter(tester).go('/settings/operator');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('settings-families')), findsOneWidget, reason: 'back on Settings');
      expect(find.byKey(const Key('approve-family-4')), findsNothing);
    });
  });

  testWidgets('reviewer invite: create, copy, revoke', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
      return null;
    });
    await openOperator(tester);
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
    appRouter(tester).go('/settings/operator');
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

  testWidgets('reviewer accounts are listed and can be removed', (tester) async {
    final revKey = await tester.runAsync(() async => b64url(await publicKeyOf(await newIdentityKey())));
    final revId = server.addUser('Play Reviewer', identityPub: revKey!, reviewer: true);
    server.addDevice(revId, name: 'Pixel');
    await openOperator(tester);
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
}
