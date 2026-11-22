// Riverpod wiring for notifications. ChatsShell watches [notificationsProvider], which starts
// whatever this platform uses while signed in: FCM (Android, iOS, web) and/or socket notifications
// (desktop, web), plus closing the socket in the background on phones so pushes start at once.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../chat/background_send.dart';
import '../chat/providers.dart';
import '../router.dart';
import '../session/session_controller.dart';
import '../window/desktop_window.dart';
import '../window/window_controls.dart';
import 'android_previews.dart';
import 'local_notifier.dart';
import 'notifications.dart';
import 'preview_keyring.dart';
import 'preview_setting.dart';
import 'push_messaging.dart';

/// The app's ScaffoldMessenger, for foreground pushes shown over any screen.
final rootMessengerKeyProvider = Provider<GlobalKey<ScaffoldMessengerState>>((ref) => GlobalKey());

/// This platform's own notifier (desktop, web), or null on phones.
final localNotifierProvider = Provider<LocalNotifier?>((ref) => createLocalNotifier());

/// Whether the user is looking at FamChat: resumed, and on the desktop apps not hidden to the tray.
bool appInFront() =>
    WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed &&
    (desktopPlatform() == null || !WindowControls.instance.hidden.value);

String _path(GoRouter router) => router.routerDelegate.currentConfiguration.uri.path;

final pushControllerProvider = Provider<PushController?>((ref) {
  final messaging = ref.watch(pushMessagingProvider);
  final device = ref.watch(sessionProvider.select((s) => s is SignedIn ? s.session.deviceId : null));
  if (messaging == null || device == null) return null;
  final router = ref.read(routerProvider);
  final c = PushController(
    messaging: messaging,
    register: (token, previews) =>
        ref.read(apiClientProvider).authedJson('PUT', '/devices/me/push', body: {'token': token, 'previews': previews}),
    previewsOn: readPreviewsOn,
    openRoute: router.go,
    isChatVisible: (id) => appInFront() && _path(router) == '/chats/$id',
    showInApp: (m, route) => showPushSnackBar(ref.read(rootMessengerKeyProvider).currentState, m, route, router.go),
    enrich: (m) async {
      if (!m.isPreview) return m;
      final text = await previewNotificationText(m, previewsOn: readPreviewsOn, openDb: () async => ref.read(chatDbProvider));
      return m.withBody(text.body);
    },
    askNow: !kIsWeb,
  );
  // Android draws preview notifications itself, so FCM's tap streams miss their taps.
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) unawaited(routeAndroidNotificationTaps(router.go));
  unawaited(c.start());
  // A registration that failed (offline, no token yet) is retried each time the app comes back.
  final lifecycle = AppLifecycleListener(onResume: () => unawaited(c.resumed()));
  ref.onDispose(() {
    lifecycle.dispose();
    unawaited(c.stop());
  });
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
    caughtUp: ref.watch(chatSyncProvider)?.caughtUp ?? const Stream.empty(),
    myUserId: me,
    db: ref.watch(chatDbProvider),
    notifier: notifier,
    previewsOn: () async => previewsSupported() && await readPreviewsOn(),
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
/// as offline and pushes right away; reconnect (and sync) on return. A message still sending gets
/// a little time to go out first.
final socketLifecycleProvider = Provider<void>((ref) {
  if (kIsWeb || !(defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS)) return;
  final sync = ref.watch(chatSyncProvider);
  if (sync == null) return;
  final send = BackgroundSend(
    hub: sync.hub,
    unsent: sync.hasUnsent,
    task: defaultTargetPlatform == TargetPlatform.iOS ? IosBackgroundTask() : const NoBackgroundTask(),
  );
  final listener = AppLifecycleListener(
    onPause: () => unawaited(send.paused()),
    onResume: () => unawaited(send.resumed()),
  );
  ref.onDispose(listener.dispose);
});

/// Everything notification-related for the signed-in home screen.
final notificationsProvider = Provider<void>((ref) {
  ref.watch(pushControllerProvider);
  ref.watch(messageNotifierProvider);
  ref.watch(socketLifecycleProvider);
  ref.watch(previewKeyringSyncProvider);
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

/// Phones: whether this device's notifications are off (never allowed, or turned off in the
/// phone's settings), so pushes reach it but never show. Checked at start and each time the app
/// comes back to the front; "Not now" hides it until the next start.
class NotificationsOffNotifier extends Notifier<bool> {
  bool _dismissed = false;

  @override
  bool build() {
    final messaging = ref.watch(pushMessagingProvider);
    if (kIsWeb || messaging == null) return false;
    final lifecycle = AppLifecycleListener(onResume: () => unawaited(_check(messaging)));
    ref.onDispose(lifecycle.dispose);
    unawaited(_check(messaging));
    return false;
  }

  Future<void> _check(PushMessaging messaging) async {
    final bool off;
    try {
      off = !await messaging.permissionGranted();
    } catch (_) {
      return;
    }
    if (ref.mounted) state = off && !_dismissed;
  }

  /// Asks for permission and registers. False when the phone said no without asking (it only asks
  /// so many times); then the user has to turn them on in the phone's settings.
  Future<bool> turnOn() async {
    final messaging = ref.read(pushMessagingProvider);
    if (messaging == null) return true;
    bool allowed;
    try {
      allowed = await messaging.requestPermission();
    } catch (_) {
      allowed = false;
    }
    if (!allowed || !ref.mounted) return allowed;
    state = false;
    await ref.read(pushControllerProvider)?.enable();
    return true;
  }

  void dismiss() {
    _dismissed = true;
    state = false;
  }
}

final notificationsOffProvider = NotifierProvider<NotificationsOffNotifier, bool>(NotificationsOffNotifier.new);
