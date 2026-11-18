// What happens around a notification on this device: registering for FCM pushes, routing taps,
// pushes that arrive in the foreground, and the socket-driven notifications of desktop apps and
// background web tabs. Text follows the server's rule: who and where, never what.
import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;

import '../chat/db/chat_db.dart';
import 'chat_route.dart';
import 'local_notifier.dart';
import 'preview.dart';
import 'push_messaging.dart';

/// Direct chat: (sender, "New message"). Group: (title, "New message from `sender`").
Future<(String, String)> notificationText(ChatDb db, String chatId, String senderUserId, {bool mention = false}) async {
  final sender = (await db.userById(senderUserId))?.name ?? 'Someone';
  final chat = await db.chatById(chatId);
  if (chat == null || chat.kind != 'group') return (sender, 'New message');
  final title = chat.title;
  return (title == null || title.isEmpty ? 'Group' : title, mention ? '$sender mentioned you' : 'New message from $sender');
}

/// FCM on this device while signed in: permission, token registration (and refreshes), taps, and
/// foreground pushes.
class PushController {
  PushController({
    required this.messaging,
    required this.register,
    required this.previewsOn,
    required this.openRoute,
    required this.isChatVisible,
    required this.showInApp,
    required this.enrich,
    required this.askNow,
  });

  final PushMessaging messaging;

  /// Sends the token and this device's previews setting to the server (`PUT /devices/me/push`).
  final Future<void> Function(String token, bool previews) register;

  /// This device's "Show message previews" setting.
  final Future<bool> Function() previewsOn;
  final void Function(String route) openRoute;

  /// True while that chat is on screen and the app is in front.
  final bool Function(String chatId) isChatVisible;

  /// Shows a foreground push inside the app; [route] is where "Open" goes (null: nowhere).
  final void Function(PushMessage message, String? route) showInApp;

  /// A foreground push as it should show: a preview push gets its decrypted text. Never throws.
  final Future<PushMessage> Function(PushMessage message) enrich;

  /// Ask for permission at start (phones). The web asks from a button instead ([enable]); there
  /// a permission granted earlier is still used at start.
  final bool askNow;

  final _subs = <StreamSubscription<Object?>>[];
  bool _stopped = false;

  Future<void> start() async {
    _subs.add(messaging.onMessageOpenedApp.listen(_open));
    _subs.add(messaging.onMessage.listen((m) => unawaited(_foreground(m))));
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

  Future<void> _register(String token, [bool? previews]) async {
    if (_stopped) return;
    try {
      await register(token, previews ?? await previewsOn());
    } catch (_) {
      // Offline: the next start registers again.
    }
  }

  /// Tells the server the new setting by re-sending the current token. Without notification
  /// permission (never asked here) or a token, nothing is registered and the stored value is all
  /// there is; [enable] sends it once push is allowed.
  Future<void> setPreviews(bool on) async {
    if (_stopped) return;
    try {
      if (!await messaging.permissionGranted()) return;
      final token = await messaging.getToken();
      if (token != null) await _register(token, on);
    } catch (_) {
      // Offline or no push: the stored value is used at the next registration.
    }
  }

  void _open(PushMessage m) {
    final route = chatRoute(m.chatId);
    if (route != null) openRoute(route);
  }

  Future<void> _foreground(PushMessage m) async {
    // A badge update shows nothing; while the app runs it keeps the badge itself (app_badge.dart).
    if (m.isBadgeUpdate) return;
    var shown = m;
    try {
      shown = await enrich(m);
    } catch (_) {
      // The generic text, then.
    }
    if (_stopped) return;
    final chatId = shown.chatId;
    if (chatId != null && isChatVisible(chatId)) return;
    showInApp(shown, chatRoute(chatId));
  }

  Future<void> stop() async {
    _stopped = true;
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
  }
}

/// Whether [chat]'s notifications are muted at [now].
bool isMuted(ChatRow? chat, DateTime now) => (chat?.mutedUntil ?? 0) > now.millisecondsSinceEpoch;

/// Desktop apps and web tabs: a notification for every `msg` from someone else that arrives over
/// the socket while the app isn't in front (unless silent, or the chat is muted and I wasn't mentioned).
class MessageNotifier {
  MessageNotifier({
    required this.events,
    required this.myUserId,
    required this.db,
    required this.notifier,
    required this.previewsOn,
    required this.inFront,
  });

  final Stream<Map<String, Object?>> events;
  final String myUserId;
  final ChatDb db;
  final LocalNotifier notifier;

  /// This device's "Show message previews" setting (never true on the web).
  final Future<bool> Function() previewsOn;
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
    // Silent: a reaction, edit or delete (docs/protocol.md "send").
    if (chatId is! String || sender is! String || sender == myUserId || e['silent'] == true || inFront()) return;
    final route = chatRoute(chatId);
    if (route == null) return;
    // An @mention of me notifies even in a muted chat (docs/protocol.md "msg").
    final mentioned = (e['mentions'] as List?)?.contains(myUserId) ?? false;
    try {
      if (!mentioned && isMuted(await db.chatById(chatId), DateTime.now())) return;
      final (title, generic) = await notificationText(db, chatId, sender, mention: mentioned);
      final body = await _previewBody(m, chatId, sender) ?? generic;
      await notifier.show(id: chatId.hashCode & 0x7fffffff, title: title, body: body, route: route);
    } catch (_) {
      // The database closed (signed out) meanwhile.
    }
  }

  /// The notification body with previews on, or null (previews off, or no preview) for the generic text.
  Future<String?> _previewBody(Map<Object?, Object?> m, String chatId, String sender) async {
    try {
      if (!await previewsOn()) return null;
      // The socket carries the envelope as a parsed JSON object; anything else means no preview.
      final envelope = m['envelope'], id = m['id'], deviceId = m['senderDeviceId'];
      if (envelope is! Map || id is! String || deviceId is! String) return null;
      final preview = await previewText(
        db: db,
        chatId: chatId,
        messageId: id,
        senderUserId: sender,
        senderDeviceId: deviceId,
        envelope: Map<String, Object?>.from(envelope),
      );
      return preview == null ? null : await previewBody(db: db, chatId: chatId, senderUserId: sender, preview: preview);
    } catch (_) {
      return null; // Any failure still notifies, with the generic text.
    }
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
  }
}
