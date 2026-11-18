import 'package:famchat/chat/providers.dart';
import 'package:famchat/session/secure_kv.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/app_harness.dart';
import '../support/fake_server.dart';

void main() {
  late FakeServer server;

  setUp(() => server = FakeServer());

  testWidgets('invite screen shows and copies the link', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
      return null;
    });
    await pumpApp(tester, server: server, kv: MemorySecureKv());
    await signInDirectly(tester, server, admin: true);
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.byKey(const Key('settings-families')), 100); // the Display group pushed it down
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-families')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('family-tile-1')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Invite someone'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Invite someone'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('invite-name-field')), 'Grandpa');
    await tester.tap(find.byKey(const Key('create-invite-button')));
    await tester.pumpAndSettle();
    final token = server.invites.entries.singleWhere((e) => e.value.name == 'Grandpa').key;
    final url = 'https://famchat.dev/join#$token';
    expect(server.log, contains('POST /api/families/1/invites -> 201'));
    expect(find.text(url), findsOneWidget);
    expect(find.textContaining('Only share this with Grandpa'), findsOneWidget);
    await tester.tap(find.byKey(const Key('copy-invite-button')));
    await tester.pumpAndSettle();
    expect(copied, url);
    expect(find.text('Link copied'), findsOneWidget);
  });

  testWidgets('non-admin has no invite action', (tester) async {
    await pumpApp(tester, server: server, kv: MemorySecureKv());
    await signInDirectly(tester, server);
    appRouter(tester).go('/settings/families');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('family-tile-1')), findsOneWidget);
    await tester.tap(find.byKey(const Key('family-tile-1')));
    await tester.pumpAndSettle();
    expect(find.text('Invite someone'), findsNothing);
  });

  testWidgets("another family's invite is for that family", (tester) async {
    server.extraFamilies.add(
        {'id': 2, 'name': 'Joneses', 'status': 'approved', 'role': 'admin', 'owner': true, 'memberCount': 1, 'createdAt': 2});
    await pumpApp(tester, server: server, kv: MemorySecureKv());
    await signInDirectly(tester, server, name: 'Gran');
    server.users.values.single.familyRoles[2] = 'admin';
    appRouter(tester).go('/settings/families/2');
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Invite someone'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Invite someone'));
    await tester.pumpAndSettle();
    expect(appRouter(tester).state.uri.path, '/settings/families/2/invite');
    await tester.enterText(find.byKey(const Key('invite-name-field')), 'Cousin');
    await tester.tap(find.byKey(const Key('create-invite-button')));
    await tester.pumpAndSettle();
    expect(server.log, contains('POST /api/families/2/invites -> 201'));
    final invite = server.invites.values.singleWhere((i) => i.name == 'Cousin');
    expect(invite.familyId, 2);
    expect(find.textContaining('Only share this with Cousin'), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(appRouter(tester).state.uri.path, '/settings/families/2');
  });

  testWidgets('admin status from the server shows the invite action', (tester) async {
    await pumpApp(tester, server: server, kv: MemorySecureKv());
    await signInDirectly(tester, server);
    server.users.values.single.isAdmin = true;
    // The server's `family` event refetches the families (roles included).
    await appContainer(tester).read(familiesProvider.notifier).refresh();
    appRouter(tester).go('/settings');
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.byKey(const Key('settings-families')), 100); // the Display group pushed it down
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-families')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('family-tile-1')));
    await tester.pumpAndSettle();
    expect(find.text('Invite someone'), findsOneWidget);
  });
}
