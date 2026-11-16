// Riverpod wiring for notifications. ChatsShell watches [notificationsProvider], which starts
// whatever this platform uses while signed in: FCM (Android, iOS, web) and/or socket notifications
// (desktop, web), plus closing the socket in the background on phones so pushes start at once.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../chat/providers.dart';
import '../router.dart';
import '../session/session_controller.dart';
import 'local_notifier.dart';
import 'notifications.dart';
import 'push_messaging.dart';

/// The app's ScaffoldMessenger, for foreground pushes shown over any screen.
final rootMessengerKeyProvider = Provider<GlobalKey<ScaffoldMessengerState>>((ref) => GlobalKey());

/// This platform's own notifier (desktop, web), or null on phones.
final localNotifierProvider = Provider<LocalNotifier?>((ref) => createLocalNotifier());

bool appInFront() => WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;

String _path(GoRouter router) => router.routerDelegate.currentConfiguration.uri.path;

final pushControllerProvider = Provider<PushController?>((ref) {
  final messaging = ref.watch(pushMessagingProvider);
  final device = ref.watch(sessionProvider.select((s) => s is SignedIn ? s.session.deviceId : null));
  if (messaging == null || device == null) return null;
  final router = ref.read(routerProvider);
  final c = PushController(
    messaging: messaging,
    register: (token) => ref.read(apiClientProvider).authedJson('PUT', '/devices/me/push', body: {'token': token}),
    openRoute: router.go,
    isChatVisible: (id) => appInFront() && _path(router) == '/chats/$id',
    showInApp: (m, route) => showPushSnackBar(ref.read(rootMessengerKeyProvider).currentState, m, route, router.go),
    askNow: !kIsWeb,
  );
  unawaited(c.start());
  ref.onDispose(() => unawaited(c.stop()));
  return c;
});

void showPushSnackBar(ScaffoldMessengerState? messenger, PushMessage m, String? route, void Function(String) go) {
  if (messenger == null) return;
  final text = [m.title, m.body].whereType<String>().where((s) => s.isNotEmpty).join(': ');
  messenger.showSnackBar(SnackBar(
    content: Text(text.isEmpty ? 'New message' : text),
    action: route == null ? null : SnackBarAction(label: 'Open', onPressed: () => go(route)),
  ));
}

final messageNotifierProvider = Provider<MessageNotifier?>((ref) {
  final notifier = ref.watch(localNotifierProvider);
  final me = ref.watch(myUserIdProvider);
  if (notifier == null || me == null) return null;
  final router = ref.read(routerProvider);
  final n = MessageNotifier(
    events: ref.watch(hubLinkProvider).events,
    myUserId: me,
    db: ref.watch(chatDbProvider),
    notifier: notifier,
    inFront: appInFront,
  );
  unawaited(() async {
    await notifier.init(router.go);
    if (!notifier.needsPermission) await notifier.requestPermission();
  }());
  n.start();
  ref.onDispose(() => unawaited(n.stop()));
  return n;
});

/// Phones: close the socket while the app is in the background, so the server counts this device
/// as offline and pushes right away; reconnect (and sync) on return.
final socketLifecycleProvider = Provider<void>((ref) {
  if (kIsWeb || !(defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS)) return;
  final sync = ref.watch(chatSyncProvider);
  if (sync == null) return;
  final hub = sync.hub;
  final listener = AppLifecycleListener(
    onPause: () => unawaited(hub.stop()),
    onResume: () => unawaited(hub.start()),
  );
  ref.onDispose(listener.dispose);
});

/// Everything notification-related for the signed-in home screen.
final notificationsProvider = Provider<void>((ref) {
  ref.watch(pushControllerProvider);
  ref.watch(messageNotifierProvider);
  ref.watch(socketLifecycleProvider);
});

/// Web only: whether to offer "Turn on notifications" (browsers only ask from a click).
class NotifyOfferNotifier extends Notifier<bool> {
  @override
  bool build() {
    if (!kIsWeb) return false;
    return ref.watch(localNotifierProvider)?.needsPermission ?? false;
  }

  Future<void> enable() async {
    state = false;
    await ref.read(localNotifierProvider)?.requestPermission();
    await ref.read(pushControllerProvider)?.enable();
  }

  void dismiss() => state = false;
}

final notifyOfferProvider = NotifierProvider<NotifyOfferNotifier, bool>(NotifyOfferNotifier.new);
