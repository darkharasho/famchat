import 'package:famchat/screens/join_screen.dart' show offerAppProvider;
import 'package:famchat/session/secure_kv.dart';
import 'package:famchat/session/session_controller.dart';
import 'package:famchat/session/stored_session.dart';
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

  Future<void> tapJoin(WidgetTester tester) async {
    await tester.ensureVisible(find.byKey(const Key('join-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('join-button')));
    await tester.pumpAndSettle();
  }

  testWidgets('join with a pasted link signs in', (tester) async {
    await pumpApp(tester, server: server, kv: kv);
    expect(find.text('Join FamChat'), findsOneWidget);
    final token = server.addInvite(name: 'Mom');
    await tester.enterText(find.byKey(const Key('invite-field')), '  https://famchat.dev/join#$token\n');
    await tester.enterText(find.byKey(const Key('device-name-field')), 'Kitchen tablet');
    await tapJoin(tester);
    expect(find.text('No chats yet'), findsOneWidget);
    expect(server.devices.values.single.name, 'Kitchen tablet');
    expect(kv.values, isNotEmpty);
  });

  testWidgets('a reviewer link asks for your name and makes a reviewer account', (tester) async {
    await pumpApp(tester, server: server, kv: kv);
    expect(find.byKey(const Key('display-name-field')), findsNothing);
    final token = server.addReviewerInvite();
    await tester.enterText(find.byKey(const Key('invite-field')), 'https://famchat.dev/join#review.$token');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('display-name-field')), findsOneWidget);
    await tapJoin(tester);
    expect(find.text('Enter your name (up to 40 characters).'), findsOneWidget);
    expect(server.requestCount, 0);
    await tester.enterText(find.byKey(const Key('display-name-field')), ' Play Reviewer ');
    await tapJoin(tester);
    expect(find.text('No chats yet'), findsOneWidget);
    final u = server.users.values.single;
    expect((u.name, u.reviewer, u.isAdmin), ('Play Reviewer', true, false));
    // Reusable: the invite still works.
    expect(server.invites[token]!.usedBy, isNull);
  });

  testWidgets('a revoked reviewer link says so', (tester) async {
    await pumpApp(tester, server: server, kv: kv);
    final token = server.addReviewerInvite();
    server.invites[token]!.revoked = true;
    await tester.enterText(find.byKey(const Key('invite-field')), 'review.$token');
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('display-name-field')), 'Reviewer');
    await tapJoin(tester);
    expect(find.text('This invite has expired or was already used. Ask for a new one.'), findsOneWidget);
    expect(server.users, isEmpty);
  });

  testWidgets('device name defaults from the platform', (tester) async {
    await pumpApp(tester, server: server, kv: kv);
    expect(find.text('Android phone'), findsOneWidget);
  });

  testWidgets('bad invite shows an error without calling the server', (tester) async {
    await pumpApp(tester, server: server, kv: kv);
    await tester.enterText(find.byKey(const Key('invite-field')), 'hello there');
    await tapJoin(tester);
    expect(find.text("That doesn't look like a FamChat invite link."), findsOneWidget);
    expect(server.requestCount, 0);
  });

  testWidgets('empty device name is refused', (tester) async {
    await pumpApp(tester, server: server, kv: kv);
    await tester.enterText(find.byKey(const Key('invite-field')), server.addInvite());
    await tester.enterText(find.byKey(const Key('device-name-field')), '   ');
    await tapJoin(tester);
    expect(find.text('Give this device a name (up to 60 characters).'), findsOneWidget);
    expect(server.requestCount, 0);
  });

  testWidgets('used invite shows the expired message', (tester) async {
    await pumpApp(tester, server: server, kv: kv);
    final token = server.addInvite();
    server.invites[token]!.usedBy = 'someone';
    server.invites[token]!.usedAt = DateTime(2000);
    await tester.enterText(find.byKey(const Key('invite-field')), token);
    await tapJoin(tester);
    expect(find.text('This invite has expired or was already used. Ask for a new one.'), findsOneWidget);
    expect(kv.values, isEmpty);
  });

  testWidgets('lost response shows a connection error and the retry succeeds', (tester) async {
    await pumpApp(tester, server: server, kv: kv);
    await tester.enterText(find.byKey(const Key('invite-field')), server.addInvite());
    server.dropNextRedeemResponse = true;
    await tapJoin(tester);
    expect(find.text("Couldn't reach FamChat. Check your connection and try again."), findsOneWidget);
    await tapJoin(tester);
    expect(find.text('No chats yet'), findsOneWidget);
    expect(server.devices, hasLength(1));
  });

  testWidgets('web link prefill joins without pasting', (tester) async {
    final token = server.addInvite();
    await pumpApp(tester, server: server, kv: kv, extra: [initialInviteTokenProvider.overrideWithValue(token)]);
    expect(find.text('Joining with the invite link you opened.'), findsOneWidget);
    expect(find.byKey(const Key('invite-field')), findsNothing);
    await tapJoin(tester);
    expect(find.text('No chats yet'), findsOneWidget);
  });

  testWidgets('on a phone browser, Join offers the app', (tester) async {
    await pumpApp(tester, server: server, kv: kv, extra: [offerAppProvider.overrideWithValue(true)]);
    expect(find.text('Get the app'), findsOneWidget);
  });

  testWidgets('elsewhere it does not', (tester) async {
    await pumpApp(tester, server: server, kv: kv, extra: [offerAppProvider.overrideWithValue(false)]);
    expect(find.text('Get the app'), findsNothing);
  });

  testWidgets('storage failure shows the explanation and retry', (tester) async {
    await pumpApp(tester, server: server, kv: _BrokenKv());
    expect(find.text(storageUnavailableMessage), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
  });

  testWidgets('storage failure offers to start over', (tester) async {
    final broken = _BrokenKv()..values[SessionStore.key] = 'unreadable';
    await pumpApp(tester, server: server, kv: broken);
    await tester.ensureVisible(find.text('Start over'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start over'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.widgetWithText(FilledButton, 'Start over'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Start over'));
    await tester.pumpAndSettle();
    expect(find.text('Join FamChat'), findsOneWidget);
    expect(broken.values, isEmpty);
  });
}

class _BrokenKv extends MemorySecureKv {
  @override
  Future<String?> read(String key) async => throw StateError('no keyring');
  @override
  Future<void> write(String key, String value) async => throw StateError('no keyring');
}
