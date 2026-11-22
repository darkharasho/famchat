import 'dart:async';

import 'package:famchat/chat/providers.dart';
import 'package:famchat/session/app_links.dart';
import 'package:famchat/session/invite_link.dart' show openInviteInApp;
import 'package:famchat/session/secure_kv.dart';
import 'package:famchat/session/session_controller.dart';
import 'package:famchat/widgets/link_text.dart' show openLink;
import 'package:flutter_test/flutter_test.dart';

import '../support/app_harness.dart';
import '../support/fake_server.dart';

class FakeLinks implements IncomingLinks {
  Uri? first;
  final _links = StreamController<Uri>.broadcast();

  void tap(String url) => _links.add(Uri.parse(url));

  @override
  Future<Uri?> initial() async => first;

  @override
  Stream<Uri> get links => _links.stream;
}

void main() {
  late FakeServer server;
  late FakeLinks links;
  final token = 'A' * 32;

  setUp(() {
    server = FakeServer();
    links = FakeLinks();
  });

  Future<void> start(WidgetTester tester) =>
      pumpApp(tester, server: server, kv: MemorySecureKv(), links: links);

  testWidgets('an invite link that opened the app fills in Join', (tester) async {
    links.first = Uri.parse('https://famchat.dev/join#$token');
    await start(tester);
    await tester.pumpAndSettle();
    expect(find.text('Joining with the invite link you opened.'), findsOneWidget);
  });

  testWidgets('a link tapped while the app is open, on another screen, opens Join with it', (tester) async {
    await start(tester);
    appRouter(tester).go('/pair');
    await tester.pumpAndSettle();
    links.tap('https://famchat.dev/join#$token');
    await tester.pumpAndSettle();
    expect(find.text('Joining with the invite link you opened.'), findsOneWidget);
  });

  testWidgets("links that aren't invites from famchat.dev are ignored", (tester) async {
    await start(tester);
    for (final u in ['https://famchat.dev/join', 'https://famchat.dev/other#$token', 'https://evil.example/join#$token']) {
      links.tap(u);
      await tester.pumpAndSettle();
      expect(find.text('Paste the invite link someone in your family sent you.'), findsOneWidget, reason: u);
    }
  });

  Map<String, Object?> approvedFamily() => {'id': 10, 'name': 'Smiths', 'status': 'approved', 'role': 'member', 'owner': false, 'ownerId': 'x', 'memberCount': 3, 'createdAt': 1};

  testWidgets('signed in: an invite to another family offers to join it, and Join does', (tester) async {
    server.extraFamilies.add({...approvedFamily(), 'role': 'admin'});
    final invite = server.addInvite(name: 'Mom', familyId: 10);
    await start(tester);
    await signInDirectly(tester, server);
    server.users.values.single.familyRoles.remove(10);
    links.tap('https://famchat.dev/join#$invite');
    await tester.pumpAndSettle();
    expect(find.text('Join Smiths?'), findsOneWidget);
    await tester.tap(find.text('Join'));
    await tester.pumpAndSettle();
    expect(find.text('You joined Smiths'), findsOneWidget);
    expect(find.text('Join Smiths?'), findsNothing);
    expect(server.users.values.single.familyRoles[10], 'member');
    expect(appRouter(tester).state.uri.path, '/');
  });

  testWidgets('signed in: a join that succeeds refreshes the families even if the sheet was dismissed meanwhile', (tester) async {
    server.extraFamilies.add(approvedFamily());
    final invite = server.addInvite(familyId: 10);
    await start(tester);
    await signInDirectly(tester, server);
    server.users.values.single.familyRoles.remove(10);
    links.tap('https://famchat.dev/join#$invite');
    await tester.pumpAndSettle();
    server.joinGate = Completer<void>();
    await tester.tap(find.text('Join'));
    await tester.pump();
    await tester.tapAt(const Offset(10, 10)); // the barrier
    await tester.pumpAndSettle();
    appContainer(tester).read(familiesProvider); // keep it alive
    final before = server.log.where((l) => l.startsWith('GET /api/families ')).length;
    server.joinGate!.complete();
    await tester.pumpAndSettle();
    expect(server.users.values.single.familyRoles[10], 'member');
    expect(server.log.where((l) => l.startsWith('GET /api/families ')).length, greaterThan(before));
  });

  testWidgets('signed in: Not now leaves the invite unused', (tester) async {
    server.extraFamilies.add(approvedFamily());
    final invite = server.addInvite(familyId: 10);
    await start(tester);
    await signInDirectly(tester, server);
    links.tap('https://famchat.dev/join#$invite');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
    expect(find.text('Join Smiths?'), findsNothing);
    expect(server.invites[invite]!.usedBy, isNull);
  });

  testWidgets("signed in: an invite to a family you're in says so", (tester) async {
    final invite = server.addInvite(name: 'Dad');
    await start(tester);
    await signInDirectly(tester, server);
    links.tap('https://famchat.dev/join#$invite');
    await tester.pumpAndSettle();
    expect(find.text("You're already in Family"), findsOneWidget);
    expect(find.text('Join Family?'), findsNothing);
  });

  testWidgets('signed in: becoming a member before tapping Join says so', (tester) async {
    server.extraFamilies.add(approvedFamily());
    final invite = server.addInvite(familyId: 10);
    await start(tester);
    await signInDirectly(tester, server);
    links.tap('https://famchat.dev/join#$invite');
    await tester.pumpAndSettle();
    server.users.values.single.familyRoles[10] = 'member';
    await tester.tap(find.text('Join'));
    await tester.pumpAndSettle();
    expect(find.text("You're already in Smiths"), findsOneWidget);
  });

  testWidgets('signed in: an expired or used invite says so', (tester) async {
    await start(tester);
    await signInDirectly(tester, server);
    links.tap('https://famchat.dev/join#$token');
    await tester.pumpAndSettle();
    expect(find.text('This invite link has expired or was already used.'), findsOneWidget);
  });

  testWidgets('signed in: an invite that goes bad before Join gets the same message', (tester) async {
    server.extraFamilies.add(approvedFamily());
    final invite = server.addInvite(familyId: 10);
    await start(tester);
    await signInDirectly(tester, server);
    links.tap('https://famchat.dev/join#$invite');
    await tester.pumpAndSettle();
    server.invites[invite]!.revoked = true;
    await tester.tap(find.text('Join'));
    await tester.pumpAndSettle();
    expect(find.text('This invite link has expired or was already used.'), findsOneWidget);
  });

  testWidgets('a reviewer link while signed in says already signed in', (tester) async {
    final invite = server.addReviewerInvite();
    await start(tester);
    await signInDirectly(tester, server);
    links.tap('https://famchat.dev/join#review.$invite');
    await tester.pumpAndSettle();
    expect(find.text("You're already signed in."), findsOneWidget);
  });

  testWidgets('a reviewer session keeps "You\'re already signed in."', (tester) async {
    server.extraFamilies.add(approvedFamily());
    final invite = server.addInvite(familyId: 10);
    await start(tester);
    await appContainer(tester).read(sessionProvider.notifier).join(
        token: 'review.${server.addReviewerInvite()}', deviceName: 'Pixel', displayName: 'Rev');
    await tester.pumpAndSettle();
    links.tap('https://famchat.dev/join#$invite');
    await tester.pumpAndSettle();
    expect(find.text("You're already signed in."), findsOneWidget);
    expect(find.text('Join Smiths?'), findsNothing);
  });

  // iOS never sends an app its own universal links: opened through the system, an invite link
  // tapped in a FamChat message would land in Safari. So the app handles it itself.
  testWidgets('signed in: an invite link tapped in a message offers to join, in the app', (tester) async {
    server.extraFamilies.add({...approvedFamily(), 'role': 'admin'});
    final invite = server.addInvite(name: 'Mom', familyId: 10);
    await start(tester);
    await signInDirectly(tester, server);
    server.users.values.single.familyRoles.remove(10);
    await openLink(Uri.parse('https://famchat.dev/join#$invite'));
    await tester.pumpAndSettle();
    expect(find.text('Join Smiths?'), findsOneWidget);
  });

  testWidgets('signed out: an invite link tapped in the app opens Join with it', (tester) async {
    await start(tester);
    await openLink(Uri.parse('https://famchat.dev/join#$token'));
    await tester.pumpAndSettle();
    expect(find.text('Joining with the invite link you opened.'), findsOneWidget);
  });

  test('only invite links are handled in the app; others go to the browser', () {
    expect(openInviteInApp(Uri.parse('https://famchat.dev/join#$token')), isTrue);
    for (final u in ['https://famchat.dev/download.html', 'https://example.com/join#$token', 'https://famchat.dev/join']) {
      expect(openInviteInApp(Uri.parse(u)), isFalse, reason: u);
    }
  });
}
