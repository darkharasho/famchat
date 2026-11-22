// Phones: a banner on the chat list when notifications are off, so they don't fail silently.

import 'package:famchat/push/push_messaging.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/chat_harness.dart';
import '../support/fake_chat_backend.dart';

class _Messaging implements PushMessaging {
  _Messaging({this.granted = false, this.grantOnRequest = true});
  bool granted, grantOnRequest;
  int requests = 0;

  @override
  Future<bool> requestPermission() async {
    requests++;
    if (grantOnRequest) granted = true;
    return granted;
  }

  @override
  Future<bool> permissionGranted() async => granted;
  @override
  Future<String?> getToken() async => granted ? 'tok' : null;
  @override
  Stream<String> get onTokenRefresh => const Stream.empty();
  @override
  Stream<PushMessage> get onMessage => const Stream.empty();
  @override
  Stream<PushMessage> get onMessageOpenedApp => const Stream.empty();
  @override
  Future<PushMessage?> getInitialMessage() async => null;
}

void main() {
  late FakeChatBackend backend;
  late TestDevice alice;
  setUp(() async {
    backend = FakeChatBackend();
    alice = await backend.addUser('Alice');
  });
  tearDown(() => alice.dispose());

  final banner = find.byKey(const Key('notifications-off'));

  chatTestWidgets('notifications off: the banner shows, and Turn on asks and hides it', (tester) async {
    // Starting asks once (askNow); she says no.
    final push = _Messaging(grantOnRequest: false);
    await pumpChatApp(tester, alice, push: push);
    expect(banner, findsOneWidget);
    expect(find.textContaining("won't hear about new messages"), findsOneWidget);
    push.grantOnRequest = true;
    final before = push.requests;
    await tester.tap(find.descendant(of: banner, matching: find.text('Turn on')));
    await settle(tester);
    expect(push.requests, greaterThan(before));
    expect(banner, findsNothing);
  });

  chatTestWidgets("when the phone won't ask again, Turn on says where to allow them", (tester) async {
    final push = _Messaging(grantOnRequest: false);
    await pumpChatApp(tester, alice, push: push);
    await tester.tap(find.descendant(of: banner, matching: find.text('Turn on')));
    await settle(tester);
    expect(find.byKey(const Key('notifications-blocked')), findsOneWidget);
    expect(find.textContaining('Apps, FamChat'), findsOneWidget);
    await tester.tap(find.text('OK'));
    await settle(tester);
    expect(banner, findsOneWidget, reason: 'still off');
  });

  chatTestWidgets('allowed in the settings meanwhile: the banner goes when the app comes back', (tester) async {
    final push = _Messaging(grantOnRequest: false);
    await pumpChatApp(tester, alice, push: push);
    expect(banner, findsOneWidget);
    push.granted = true;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await settle(tester);
    expect(banner, findsNothing);
  });

  chatTestWidgets('Not now hides it; with notifications allowed there is none', (tester) async {
    await pumpChatApp(tester, alice, push: _Messaging(grantOnRequest: false));
    await tester.tap(find.descendant(of: banner, matching: find.text('Not now')));
    await settle(tester);
    expect(banner, findsNothing);
  });

  chatTestWidgets('allowed: no banner', (tester) async {
    await pumpChatApp(tester, alice, push: _Messaging(granted: true));
    expect(banner, findsNothing);
  });
}
