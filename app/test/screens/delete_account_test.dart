import 'package:famchat/crypto/encoding.dart';
import 'package:famchat/crypto/keys.dart';
import 'package:famchat/session/secure_kv.dart';
import 'package:famchat/session/session_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../support/app_harness.dart';
import '../support/fake_server.dart';

void main() {
  late FakeServer server;
  late MemorySecureKv kv;

  setUp(() {
    server = FakeServer();
    kv = MemorySecureKv();
  });

  String myId(WidgetTester tester) => (appContainer(tester).read(sessionProvider) as SignedIn).session.userId;

  Future<void> openDialog(WidgetTester tester, {bool admin = false}) async {
    await pumpApp(tester, server: server, kv: kv);
    await signInDirectly(tester, server, name: 'Gran', admin: admin);
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    final tile = find.byKey(const Key('settings-delete-account'));
    await tester.ensureVisible(tile);
    await tester.pumpAndSettle();
    await tester.tap(tile);
    await tester.pumpAndSettle();
  }

  FilledButton confirmButton(WidgetTester tester) =>
      tester.widget<FilledButton>(find.byKey(const Key('confirm-delete-account')));

  Future<String> addMember(WidgetTester tester, String name) async {
    final key = await tester.runAsync(() async => b64url(await publicKeyOf(await newIdentityKey())));
    final id = server.addUser(name, identityPub: key!);
    server.addDevice(id, name: 'Phone');
    return id;
  }

  testWidgets('settings end with "Delete my account", which explains and asks to type DELETE', (tester) async {
    await openDialog(tester);
    expect(find.text('Delete your account?'), findsOneWidget);
    expect(find.textContaining('the messages, photos and voice messages you sent'), findsOneWidget);
    expect(find.textContaining("It can't be undone"), findsOneWidget);
    expect(confirmButton(tester).onPressed, isNull);

    await tester.enterText(find.byKey(const Key('delete-account-confirm-field')), 'delet');
    await tester.pump();
    expect(confirmButton(tester).onPressed, isNull);
    await tester.enterText(find.byKey(const Key('delete-account-confirm-field')), 'DELETE');
    await tester.pump();
    expect(confirmButton(tester).onPressed, isNotNull);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Delete your account?'), findsNothing);
    expect(server.users[myId(tester)]!.deleted, isFalse);
    expect(appContainer(tester).read(sessionProvider), isA<SignedIn>());
  });

  testWidgets('confirming deletes the account on the server and wipes this device', (tester) async {
    await openDialog(tester);
    final id = myId(tester);
    await tester.enterText(find.byKey(const Key('delete-account-confirm-field')), 'DELETE');
    await tester.pump();
    await tester.tap(find.byKey(const Key('confirm-delete-account')));
    await tester.pumpAndSettle();

    final u = server.users[id]!;
    expect(u.deleted, isTrue);
    expect(u.name, 'Deleted user');
    expect(server.liveDevices(id), isEmpty);
    expect(server.log, contains('DELETE /api/me -> 204'));
    expect(appContainer(tester).read(sessionProvider), isA<SignedOut>());
    expect(find.text(accountDeletedMessage), findsOneWidget);
    expect(kv.values, isEmpty);
  });

  testWidgets("the only admin is told to make another admin first, and stays signed in", (tester) async {
    await openDialog(tester, admin: true);
    await addMember(tester, 'Mom');
    await tester.enterText(find.byKey(const Key('delete-account-confirm-field')), 'delete');
    await tester.pump();
    await tester.tap(find.byKey(const Key('confirm-delete-account')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('delete-account-error')), findsOneWidget);
    expect(find.textContaining("You're the family's only admin"), findsOneWidget);
    expect(server.users[myId(tester)]!.deleted, isFalse);
    expect(appContainer(tester).read(sessionProvider), isA<SignedIn>());
    expect(kv.values, isNotEmpty);
  });

  testWidgets("the operator deletes someone's account after confirming", (tester) async {
    await pumpApp(tester, server: server, kv: kv);
    await signInDirectly(tester, server, name: 'Michael', admin: true);
    final momId = await addMember(tester, 'Mom');
    appRouter(tester).go('/settings/families/1');
    await tester.pumpAndSettle();
    expect(find.text('Mom'), findsOneWidget);

    Future<void> openRemove() async {
      await tester.ensureVisible(find.byKey(Key('family-menu-$momId')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('family-menu-$momId')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete account').last);
      await tester.pumpAndSettle();
    }

    await openRemove();
    expect(find.text("Delete Mom's account?"), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(server.users[momId]!.deleted, isFalse);

    await openRemove();
    await tester.tap(find.byKey(const Key('confirm-delete')));
    await tester.pumpAndSettle();
    expect(server.users[momId]!.deleted, isTrue);
    expect(server.liveDevices(momId), isEmpty);
    expect(find.text("Mom's account was deleted"), findsOneWidget);
    // Deleted accounts aren't listed as family.
    expect(find.byKey(Key('family-user-$momId')), findsNothing);
    expect(find.text('1 person'), findsOneWidget);
  });
}
