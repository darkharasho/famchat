import 'package:famchat/admin/admin_service.dart';
import 'package:famchat/crypto/reset.dart';
import 'package:famchat/session/secure_kv.dart';
import 'package:famchat/session/session_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../support/app_harness.dart';
import '../support/fake_server.dart';
import '../support/session_overrides.dart';

void main() {
  late FakeServer server;

  setUp(() => server = FakeServer());

  /// Another device, signed in as an admin, outside the app under test.
  Future<AdminService> adminElsewhere(WidgetTester tester, {String name = 'Michael'}) async {
    final c = ProviderContainer(overrides: sessionOverrides(server, MemorySecureKv()));
    addTearDown(c.dispose);
    return (await tester.runAsync(() async {
      await settledSession(c);
      await c.read(sessionProvider.notifier).join(token: server.addInvite(name: name, admin: true), deviceName: 'Phone');
      final s = (c.read(sessionProvider) as SignedIn).session;
      return AdminService(api: c.read(apiClientProvider), userId: s.userId, identity: s.identityKey);
    }))!;
  }

  testWidgets('a reset link joins through the normal join screen, as the same user', (tester) async {
    final admin = await adminElsewhere(tester);
    final momToken = server.addInvite(name: 'Mom');
    final momKv = MemorySecureKv();
    final momC = ProviderContainer(overrides: sessionOverrides(server, momKv));
    addTearDown(momC.dispose);
    final momId = (await tester.runAsync(() async {
      await settledSession(momC);
      await momC.read(sessionProvider.notifier).join(token: momToken, deviceName: 'Old phone');
      return (momC.read(sessionProvider) as SignedIn).session.userId;
    }))!;
    final link = (await tester.runAsync(() => admin.resetUser(momId, currentIdentityPub: server.users[momId]!.identityPub)))!;

    await pumpApp(tester, server: server, kv: MemorySecureKv());
    await tester.enterText(find.byKey(const Key('invite-field')), link.url);
    await tester.enterText(find.byKey(const Key('device-name-field')), 'New phone');
    await tester.ensureVisible(find.byKey(const Key('join-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('join-button')));
    await tester.pumpAndSettle();
    expect(find.text('No chats yet'), findsOneWidget);
    expect(server.liveDevices(momId).map((d) => d.name), ['New phone']);
    expect(server.users.values.where((u) => u.name == 'Mom'), hasLength(1));
  });

  testWidgets('recover admin account with the printed code', (tester) async {
    final admin = await adminElsewhere(tester);
    final code = (await tester.runAsync(admin.createRecoveryCode))!;
    await pumpApp(tester, server: server, kv: MemorySecureKv());
    await tester.ensureVisible(find.byKey(const Key('recover-link')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('recover-link')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('recovery-code-field')), code.display.toLowerCase().replaceAll('-', ' '));
    await tester.enterText(find.byKey(const Key('recover-device-name')), 'Laptop');
    await tester.ensureVisible(find.byKey(const Key('recover-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('recover-button')));
    await tester.pumpAndSettle();
    expect(find.text('No chats yet'), findsOneWidget);
    final michael = server.users.values.singleWhere((u) => u.name == 'Michael');
    expect(server.liveDevices(michael.id).map((d) => d.name), ['Laptop']);
    expect(michael.recoveryPub, isNull, reason: 'single use');
  });

  testWidgets('a wrong or malformed code shows an error', (tester) async {
    final admin = await adminElsewhere(tester);
    await tester.runAsync(admin.createRecoveryCode);
    await pumpApp(tester, server: server, kv: MemorySecureKv());
    appRouter(tester).go('/recover');
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('recovery-code-field')), 'ABCDE');
    await tester.ensureVisible(find.byKey(const Key('recover-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('recover-button')));
    await tester.pumpAndSettle();
    expect(find.textContaining('25 letters and numbers'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('recovery-code-field')), newRecoveryCode().display);
    await tester.ensureVisible(find.byKey(const Key('recover-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('recover-button')));
    await tester.pumpAndSettle();
    expect(find.textContaining("doesn't match an admin account"), findsOneWidget);
  });
}
