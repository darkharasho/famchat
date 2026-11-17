import 'package:famchat/dev_tools.dart';
import 'package:famchat/screens/spikes_screen.dart';
import 'package:famchat/session/secure_kv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../support/app_harness.dart';
import '../support/fake_server.dart';

void main() {
  late FakeServer server;

  setUp(() => server = FakeServer());

  Future<void> openSettings(WidgetTester tester, {bool admin = false, bool dev = false}) async {
    await pumpApp(tester, server: server, kv: MemorySecureKv(), extra: [developerToolsProvider.overrideWithValue(dev)]);
    await signInDirectly(tester, server, name: 'Gran', admin: admin);
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
  }

  testWidgets("a member's settings: their name, devices and sign out, no admin pages", (tester) async {
    await openSettings(tester);
    expect(find.text('Gran'), findsWidgets); // the header and the Your name row
    expect(find.textContaining('Family member'), findsOneWidget);
    expect(find.text('Devices'), findsOneWidget);
    expect(find.text('Sign out'), findsOneWidget);
    expect(find.byKey(const Key('settings-family')), findsNothing);
    expect(find.text('Invite someone'), findsNothing);
    expect(find.text('Media storage'), findsNothing);
    expect(find.text('Platform spikes'), findsNothing);
  });

  testWidgets("an admin's settings add the family pages", (tester) async {
    await openSettings(tester, admin: true);
    expect(find.textContaining('Family admin'), findsOneWidget);
    expect(find.byKey(const Key('settings-family')), findsOneWidget);
    expect(find.text('Invite someone'), findsOneWidget);
    expect(find.text('Media storage'), findsOneWidget);
    await tester.tap(find.byKey(const Key('settings-family')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('recovery-code-card')), findsOneWidget);
  });

  testWidgets('developer tools show the platform spikes', (tester) async {
    await openSettings(tester, dev: true);
    await tester.scrollUntilVisible(find.text('Platform spikes'), 100);
    await tester.tap(find.text('Platform spikes'));
    await tester.pumpAndSettle();
    expect(find.byType(SpikesScreen), findsOneWidget);
  });

  testWidgets('back from settings returns to the chats', (tester) async {
    await openSettings(tester);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('No chats yet'), findsOneWidget);
  });
}
