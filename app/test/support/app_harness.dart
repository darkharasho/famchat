import 'package:drift/drift.dart' show DatabaseConnection, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:famchat/chat/db/chat_db.dart';
import 'package:famchat/chat/hub_link.dart';
import 'package:famchat/chat/providers.dart';
import 'package:famchat/main.dart';
import 'package:famchat/media/media_db.dart';
import 'package:famchat/media/providers.dart';
import 'package:famchat/session/app_links.dart';
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
  IncomingLinks links = const NoIncomingLinks(),
}) async {
  await tester.pumpWidget(ProviderScope(
    overrides: [
      ...sessionOverrides(server, kv),
      ...quietChatOverrides(),
      incomingLinksProvider.overrideWithValue(links),
      ...extra,
    ],
    child: const FamChatApp(),
  ));
  await tester.pumpAndSettle();
}

ProviderContainer appContainer(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(FamChatApp)));

GoRouter appRouter(WidgetTester tester) => appContainer(tester).read(routerProvider);

/// Signs in through the controller (not the UI) and settles on the home screen.
Future<void> signInDirectly(WidgetTester tester, FakeServer server, {String name = 'Mom', bool admin = false, bool? operator}) async {
  await appContainer(tester).read(sessionProvider.notifier).join(token: server.addInvite(name: name, admin: admin, operator: operator), deviceName: 'Pixel');
  await tester.pumpAndSettle();
}

/// An in-memory chat database and a hub that never connects, for tests about other screens.
List<Override> quietChatOverrides() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  return [
    chatDbProvider.overrideWith((ref) {
      // Streams close at once, so no drift timer outlives the widget tree.
      final db = ChatDb(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
      ref.onDispose(db.close);
      return db;
    }),
    mediaDbProvider.overrideWith((ref) {
      final db = MediaDb(NativeDatabase.memory());
      ref.onDispose(db.close);
      return db;
    }),
    expiredMediaProvider.overrideWith((ref) => Stream.value(const <String>{})),
    mediaOffloadProvider.overrideWithValue(null),
    hubLinkProvider.overrideWith((ref) => _IdleHub()),
    // No drift stream queries: their close timers would trip the pending-timer check.
    chatListProvider.overrideWith((ref) => Stream.value(const <ChatListItem>[])),
    usersProvider.overrideWith((ref) => Stream.value(const <String, UserRow>{})),
  ];
}

class _IdleHub implements HubLink {
  @override
  Stream<Map<String, Object?>> get events => const Stream.empty();
  @override
  Stream<bool> get connection => const Stream.empty();
  @override
  bool get connected => false;
  @override
  bool send(Map<String, Object?> msg) => false;
  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async {}
}
