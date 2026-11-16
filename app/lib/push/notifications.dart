// What happens around a notification on this device: registering for FCM pushes, routing taps,
// pushes that arrive in the foreground, and the socket-driven notifications of desktop apps and
// background web tabs. Text follows the server's rule: who and where, never what.
import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;

import '../chat/db/chat_db.dart';
import 'chat_route.dart';
import 'local_notifier.dart';
import 'push_messaging.dart';

/// Direct chat: (sender, "New message"). Group: (title, "New message from `sender`").
Future<(String, String)> notificationText(ChatDb db, String chatId, String senderUserId) async {
  final sender = (await db.userById(senderUserId))?.name ?? 'Someone';
  final chat = await db.chatById(chatId);
  if (chat == null || chat.kind != 'group') return (sender, 'New message');
  final title = chat.title;
  return (title == null || title.isEmpty ? 'Group' : title, 'New message from $sender');
}

/// FCM on this device while signed in: permission, token registration (and refreshes), taps, and
/// foreground pushes.
class PushController {
  PushController({
    required this.messaging,
    required this.register,
    required this.openRoute,
    required this.isChatVisible,
    required this.showInApp,
    required this.askNow,
  });

  final PushMessaging messaging;

  /// Sends the token to the server (`PUT /devices/me/push`).
  final Future<void> Function(String token) register;
  final void Function(String route) openRoute;

  /// True while that chat is on screen and the app is in front.
  final bool Function(String chatId) isChatVisible;

  /// Shows a foreground push inside the app; [route] is where "Open" goes (null: nowhere).
  final void Function(PushMessage message, String? route) showInApp;

  /// Ask for permission at start (phones). The web asks from a button instead ([enable]); there
  /// a permission granted earlier is still used at start.
  final bool askNow;

  final _subs = <StreamSubscription<Object?>>[];
  bool _stopped = false;

  Future<void> start() async {
    _subs.add(messaging.onMessageOpenedApp.listen(_open));
    _subs.add(messaging.onMessage.listen(_foreground));
    _subs.add(messaging.onTokenRefresh.listen(_register));
    try {
      final initial = await messaging.getInitialMessage();
      if (initial != null && !_stopped) _open(initial);
      if (askNow || await messaging.permissionGranted()) await enable();
    } catch (_) {
      // Push is a convenience: a failure here must never affect the app.
    }
  }

  /// Asks for permission (if needed) and registers this device's token. True when push is on.
  Future<bool> enable() async {
    if (_stopped) return false;
    try {
      if (!await messaging.requestPermission()) return false;
      final token = await messaging.getToken();
      if (token == null || _stopped) return false;
      await _register(token);
      return true;
    } catch (e) {
      // iOS without the aps-environment entitlement ends here (no APNs token, so no FCM token).
      debugPrint('push registration failed: $e');
      return false;
    }
  }

  Future<void> _register(String token) async {
    if (_stopped) return;
    try {
      await register(token);
    } catch (_) {
      // Offline: the next start registers again.
    }
  }

  void _open(PushMessage m) {
    final route = chatRoute(m.chatId);
    if (route != null) openRoute(route);
  }

  void _foreground(PushMessage m) {
    final chatId = m.chatId;
    if (chatId != null && isChatVisible(chatId)) return;
    showInApp(m, chatRoute(chatId));
  }

  Future<void> stop() async {
    _stopped = true;
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
  }
}

/// Desktop apps and web tabs: a notification for every `msg` from someone else that arrives over
/// the socket while the app isn't in front.
class MessageNotifier {
  MessageNotifier({
    required this.events,
    required this.myUserId,
    required this.db,
    required this.notifier,
    required this.inFront,
  });

  final Stream<Map<String, Object?>> events;
  final String myUserId;
  final ChatDb db;
  final LocalNotifier notifier;
  final bool Function() inFront;

  StreamSubscription<Object?>? _sub;

  void start() {
    _sub = events.listen((e) => unawaited(_onEvent(e)));
  }

  Future<void> _onEvent(Map<String, Object?> e) async {
    if (e['type'] != 'msg') return;
    final m = e['message'];
    if (m is! Map) return;
    final chatId = m['chatId'], sender = m['senderUserId'];
    if (chatId is! String || sender is! String || sender == myUserId || inFront()) return;
    final route = chatRoute(chatId);
    if (route == null) return;
    try {
      final (title, body) = await notificationText(db, chatId, sender);
      await notifier.show(id: chatId.hashCode & 0x7fffffff, title: title, body: body, route: route);
    } catch (_) {
      // The database closed (signed out) meanwhile.
    }
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
  }
}
