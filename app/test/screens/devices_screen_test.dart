import 'package:famchat/session/secure_kv.dart';
import 'package:famchat/session/session_controller.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/app_harness.dart';
import '../support/fake_server.dart';

void main() {
  late FakeServer server;
  late MemorySecureKv kv;

  setUp(() {
    server = FakeServer();
    kv = MemorySecureKv();
  });

  String myUserId() => server.users.keys.single;

  Future<void> openDevices(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Devices'));
    await tester.pumpAndSettle();
  }

  testWidgets('home shows the user name', (tester) async {
    await pumpApp(tester, server: server, kv: kv);
    await signInDirectly(tester, server, name: 'Gran');
    expect(find.text('Hi, Gran'), findsOneWidget);
    expect(find.text('No chats yet'), findsOneWidget);
  });

  testWidgets('devices list marks the current device', (tester) async {
    await pumpApp(tester, server: server, kv: kv);
    await signInDirectly(tester, server);
    server.addDevice(myUserId(), name: 'Old laptop');
    await openDevices(tester);
    expect(find.text('Pixel'), findsOneWidget);
    expect(find.text('Old laptop'), findsOneWidget);
    expect(find.text('This device'), findsOneWidget);
    expect(find.text('Revoke'), findsOneWidget);
  });

  testWidgets('revoking another device removes it', (tester) async {
    await pumpApp(tester, server: server, kv: kv);
    await signInDirectly(tester, server);
    final other = server.addDevice(myUserId(), name: 'Old laptop');
    await openDevices(tester);
    await tester.tap(find.text('Revoke'));
    await tester.pumpAndSettle();
    expect(find.text('Revoke Old laptop?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Revoke'));
    await tester.pumpAndSettle();
    expect(find.text('Old laptop'), findsNothing);
    expect(server.devices[other]!.revokedAt, isNotNull);
  });

  testWidgets('cancelling a revoke keeps the device', (tester) async {
    await pumpApp(tester, server: server, kv: kv);
    await signInDirectly(tester, server);
    final other = server.addDevice(myUserId(), name: 'Old laptop');
    await openDevices(tester);
    await tester.tap(find.text('Revoke'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Old laptop'), findsOneWidget);
    expect(server.devices[other]!.revokedAt, isNull);
  });

  testWidgets('sign out returns to join', (tester) async {
    await pumpApp(tester, server: server, kv: kv);
    await signInDirectly(tester, server);
    await openDevices(tester);
    await tester.tap(find.text('Sign out of this device'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Sign out'));
    await tester.pumpAndSettle();
    expect(find.text('Join FamChat'), findsOneWidget);
    expect(kv.values, isEmpty);
    expect(server.devices.values.single.revokedAt, isNotNull);
  });

  testWidgets('a device revoked elsewhere lands on join with the reason', (tester) async {
    await pumpApp(tester, server: server, kv: kv);
    await signInDirectly(tester, server);
    server.revoke(server.devices.keys.single);
    server.expireAccessTokens();
    await openDevices(tester);
    expect(find.text('Join FamChat'), findsOneWidget);
    expect(find.text(revokedMessage), findsOneWidget);
    expect(kv.values, isEmpty);
  });
}
