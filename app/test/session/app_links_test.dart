import 'dart:async';

import 'package:famchat/session/app_links.dart';
import 'package:famchat/session/secure_kv.dart';
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

  testWidgets('signed in: an invite says so and goes nowhere', (tester) async {
    await start(tester);
    await signInDirectly(tester, server);
    links.tap('https://famchat.dev/join#$token');
    await tester.pumpAndSettle();
    expect(find.text("You're already signed in."), findsOneWidget);
    expect(appRouter(tester).state.uri.path, '/');
  });
}
