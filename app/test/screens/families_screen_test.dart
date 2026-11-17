import 'package:famchat/chat/providers.dart';
import 'package:famchat/session/secure_kv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../support/app_harness.dart';
import '../support/fake_server.dart';

void main() {
  late FakeServer server;

  setUp(() => server = FakeServer());

  Map<String, Object?> family(int id, String name, String status, {String role = 'admin', bool owner = true}) =>
      {'id': id, 'name': name, 'status': status, 'role': role, 'owner': owner, 'memberCount': 1, 'createdAt': 2};

  Future<void> openFamilies(WidgetTester tester, {bool admin = true}) async {
    await pumpApp(tester, server: server, kv: MemorySecureKv());
    await signInDirectly(tester, server, name: 'Gran', admin: admin);
    appRouter(tester).go('/settings/families');
    await tester.pumpAndSettle();
  }

  testWidgets('lists each family with my role and its status', (tester) async {
    server.extraFamilies.addAll([
      family(4, 'Club', 'pending'),
      family(5, 'Choir', 'declined'),
      family(6, 'Joneses', 'approved', role: 'member', owner: false)..['memberCount'] = 3,
    ]);
    await openFamilies(tester);
    expect(find.text('Family'), findsOneWidget);
    expect(find.text('Owner · 1 person'), findsOneWidget);
    expect(find.text('Club'), findsOneWidget);
    expect(find.text('Waiting for approval'), findsOneWidget);
    expect(find.text('Declined'), findsOneWidget);
    expect(find.text('Member · 3 people'), findsOneWidget);
  });

  testWidgets("Media storage is on family 1's screen, not in the list", (tester) async {
    await openFamilies(tester);
    expect(find.byKey(const Key('settings-storage')), findsNothing);
  });

  testWidgets('every family opens its own screen', (tester) async {
    server.extraFamilies.addAll([
      family(4, 'Club', 'pending'),
      family(6, 'Joneses', 'approved', role: 'member', owner: false),
    ]);
    await openFamilies(tester, admin: false);
    for (final (id, name) in [(1, 'Family'), (4, 'Club'), (6, 'Joneses')]) {
      await tester.tap(find.byKey(Key('family-tile-$id')));
      await tester.pumpAndSettle();
      expect(appRouter(tester).state.uri.path, '/settings/families/$id');
      expect(find.widgetWithText(AppBar, name), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
    }
  });

  testWidgets('a failed refresh keeps the list', (tester) async {
    await openFamilies(tester);
    server.failFamilies = true;
    appContainer(tester).read(familiesProvider.notifier).refresh().ignore();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('family-tile-1')), findsOneWidget, reason: 'while retrying');
    await tester.pump(const Duration(minutes: 2)); // past Riverpod's retries
    await tester.pumpAndSettle();
    expect(appContainer(tester).read(familiesProvider), isA<AsyncError<Object?>>());
    expect(find.byKey(const Key('family-tile-1')), findsOneWidget);
    expect(find.text('Try again'), findsNothing);
  });

  testWidgets('starting a family validates the name, then asks the operator', (tester) async {
    await openFamilies(tester);
    await tester.tap(find.byKey(const Key('start-family')));
    await tester.pumpAndSettle();
    FilledButton send() => tester.widget<FilledButton>(find.byKey(const Key('start-family-send')));
    expect(send().onPressed, isNull, reason: 'empty name');
    await tester.enterText(find.byKey(const Key('family-name-field')), '   ');
    await tester.pump();
    expect(send().onPressed, isNull, reason: 'blank name');
    await tester.enterText(find.byKey(const Key('family-name-field')), ' Club ');
    await tester.pump();
    expect(send().onPressed, isNotNull);
    await tester.tap(find.byKey(const Key('start-family-send')));
    await tester.pumpAndSettle();
    expect(server.extraFamilies.single['name'], 'Club');
    expect(find.text("Request sent. You'll be told when it's approved."), findsOneWidget);
    expect(find.text('Waiting for approval'), findsOneWidget);
  });

  testWidgets('a request that went through but whose refresh failed still says it was sent', (tester) async {
    await openFamilies(tester);
    server.failFamilies = true;
    await tester.tap(find.byKey(const Key('start-family')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('family-name-field')), 'Club');
    await tester.pump();
    await tester.tap(find.byKey(const Key('start-family-send')));
    await tester.pump(const Duration(minutes: 2));
    await tester.pumpAndSettle();
    expect(server.extraFamilies, hasLength(1));
    expect(find.text("Request sent. You'll be told when it's approved."), findsOneWidget);
  });

  testWidgets('the name is capped at 40 characters', (tester) async {
    await openFamilies(tester);
    await tester.tap(find.byKey(const Key('start-family')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('family-name-field')), 'x' * 60);
    await tester.pump();
    expect(tester.widget<TextField>(find.byKey(const Key('family-name-field'))).controller!.text.length, 40);
  });

  testWidgets('a declined family can be dismissed', (tester) async {
    server.extraFamilies.addAll([family(4, 'Club', 'pending'), family(5, 'Choir', 'declined')]);
    await openFamilies(tester);
    expect(find.text('Dismiss'), findsOneWidget);
    await tester.tap(find.byKey(const Key('dismiss-family-5')));
    await tester.pumpAndSettle();
    expect(server.extraFamilies.map((f) => f['id']), [4]);
    expect(find.text('Choir'), findsNothing);
    expect(find.text('Club'), findsOneWidget);
  });

  testWidgets('a request approved while I look says so', (tester) async {
    server.extraFamilies.add(family(4, 'Club', 'pending'));
    await openFamilies(tester);
    expect(find.text('Club was approved'), findsNothing);
    server.extraFamilies.single['status'] = 'approved';
    await appContainer(tester).read(familiesProvider.notifier).refresh();
    await tester.pumpAndSettle();
    expect(find.text('Club was approved'), findsOneWidget);
    expect(find.text('Waiting for approval'), findsNothing);
    // Refreshing again with nothing new says nothing more.
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();
    await appContainer(tester).read(familiesProvider.notifier).refresh();
    await tester.pumpAndSettle();
    expect(find.text('Club was approved'), findsNothing);
  });
}
