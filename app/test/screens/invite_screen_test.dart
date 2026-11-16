import 'package:famchat/session/secure_kv.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
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
    await tester.tap(find.byTooltip('Invite someone'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('invite-name-field')), 'Grandpa');
    await tester.tap(find.byKey(const Key('create-invite-button')));
    await tester.pumpAndSettle();
    final token = server.invites.entries.singleWhere((e) => e.value.name == 'Grandpa').key;
    final url = 'https://famchat.dev/join#$token';
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
    expect(find.byTooltip('Invite someone'), findsNothing);
    appRouter(tester).go('/invite');
    await tester.pumpAndSettle();
    expect(find.text('Chats coming soon'), findsOneWidget);
  });

  testWidgets('admin status from the server shows the invite action', (tester) async {
    await pumpApp(tester, server: server, kv: MemorySecureKv());
    await signInDirectly(tester, server);
    server.users.values.single.isAdmin = true;
    appRouter(tester).go('/devices');
    await tester.pumpAndSettle();
    appRouter(tester).go('/');
    await tester.pumpAndSettle();
    expect(find.byTooltip('Invite someone'), findsOneWidget);
  });
}
