import 'package:famchat/main.dart';
import 'package:famchat/session/secure_kv.dart';
import 'package:famchat/session/session_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:famchat/router.dart';

import 'fake_server.dart';
import 'session_overrides.dart';

/// Pumps the whole app against [server] and [kv] and waits for it to settle.
Future<void> pumpApp(
  WidgetTester tester, {
  required FakeServer server,
  required SecureKv kv,
  List<Override> extra = const [],
}) async {
  await tester.pumpWidget(ProviderScope(overrides: [...sessionOverrides(server, kv), ...extra], child: const FamChatApp()));
  await tester.pumpAndSettle();
}

ProviderContainer appContainer(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(FamChatApp)));

GoRouter appRouter(WidgetTester tester) => appContainer(tester).read(routerProvider);

/// Signs in through the controller (not the UI) and settles on the home screen.
Future<void> signInDirectly(WidgetTester tester, FakeServer server, {String name = 'Mom', bool admin = false}) async {
  await appContainer(tester).read(sessionProvider.notifier).join(token: server.addInvite(name: name, admin: admin), deviceName: 'Pixel');
  await tester.pumpAndSettle();
}
