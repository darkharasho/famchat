// What happens around a notification on this device: registering for FCM pushes, routing taps,
// pushes that arrive in the foreground, and the socket-driven notifications of desktop apps and
// background web tabs. Text follows the server's rule: who and where, never what.
import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart' show debugPrint;

import '../chat/chat_sync.dart' show CaughtUp, FiredReminder;
import '../chat/db/chat_db.dart';
import '../chat/message_changes.dart' show mentionsOf;
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

  /// Whether the server has this device's current token (the last registration went through).
  bool _registered = false;

  /// This device gets pushes now (its token is registered).
  bool get registered => _registered;

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

  /// The app came back to the front: if this device's registration hasn't gone through yet
  /// (offline at start, no token yet, a server error), try again. Never asks for permission.
  Future<void> resumed() async {
    if (_stopped || _registered) return;
    try {
      if (await messaging.permissionGranted()) await enable();
    } catch (_) {
      // Next resume.
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
      _registered = true;
    } catch (_) {
      // Offline: retried when the app next comes to the front ([resumed]).
      _registered = false;
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
    final route = m.route;
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
    // A reminder shows even over its chat: it's about one message, maybe far up.
    if (chatId != null && !shown.isReminder && isChatVisible(chatId)) return;
    showInApp(shown, shown.route);
  }

  Future<void> stop() async {
    _stopped = true;
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
  }
}

/// The notification id of [messageId]'s reminder (apart from its chat's message notifications).
int reminderNotificationId(String messageId) => 'reminder-$messageId'.hashCode & 0x7fffffff;

/// A reminder's notification body: with previews on, the message as notifications show it
/// ("Name: text" in groups); otherwise who and where, as the server's push says (docs/protocol.md
/// "Push", reminders). Never throws.
Future<String> reminderBody(
  ChatDb db,
  String chatId,
  String messageId, {
  required String myUserId,
  required Future<bool> Function() previewsOn,
}) async {
  try {
    final row = await db.messageById(messageId);
    final chat = await db.chatById(chatId);
    if (row != null) {
      try {
        if (await previewsOn()) {
          final text = await rowPreviewText(db, row);
          if (text != null) return await previewBody(db: db, chatId: chatId, senderUserId: row.senderUserId, preview: text);
        }
      } catch (_) {
        // The generic text, then.
      }
    }
    final group = chat?.kind == 'group';
    final title = chat?.title == null || chat!.title!.isEmpty ? 'Group' : chat.title!;
    if (row != null && row.senderUserId == myUserId) return group ? '$title: your message' : 'Your message';
    final sender = row == null ? 'Someone' : (await db.userById(row.senderUserId))?.name ?? 'Someone';
    return group ? '$title: message from $sender' : 'Message from $sender';
  } catch (_) {
    return 'A message you asked to be reminded of';
  }
}

/// My reminders as they come ([ChatSync.onReminder]): a notification on desktop apps and the web
/// (the local notifier), the in-app note on phones, whose socket is open only while FamChat is in
/// front (in the background the server pushes them instead). Tapping opens the chat at the message.
class ReminderNotifier {
  ReminderNotifier({
    required this.db,
    required this.myUserId,
    required this.notifier,
    required this.showInApp,
    required this.previewsOn,
    this.pushedHere = _never,
  });

  static bool _never() => false;

  final ChatDb db;
  final String myUserId;

  /// This device gets pushes: a reminder that came while it was away was pushed to it then, so it
  /// isn't shown again as missed.

  /// Null on phones.
  final LocalNotifier? notifier;

  /// Shows it inside the app; [route] is where "Open" goes.
  final void Function(String title, String body, String route) showInApp;
  final Future<bool> Function() previewsOn;
  final bool Function() pushedHere;

  Future<void> show(FiredReminder r) async {
    final route = messageRoute(r.chatId, r.messageId);
    if (route == null || (r.missed && pushedHere())) return;
    final body = await reminderBody(db, r.chatId, r.messageId, myUserId: myUserId, previewsOn: previewsOn);
    final n = notifier;
    // The web shows nothing until the person allowed notifications: then the in-app note too.
    if (n == null || n.needsPermission) showInApp('Reminder', body, route);
    if (n != null) await n.show(id: reminderNotificationId(r.messageId), title: 'Reminder', body: body, route: route);
  }
}

/// Whether [chat]'s notifications are muted at [now].
bool isMuted(ChatRow? chat, DateTime now) => (chat?.mutedUntil ?? 0) > now.millisecondsSinceEpoch;

/// Desktop apps and web tabs: a notification for every `msg` from someone else that arrives over
/// the socket while the app isn't in front (unless silent, or the chat is muted and I wasn't mentioned),
/// and one per chat for unread messages a reconnect caught up on (asleep, offline, closed).
class MessageNotifier {
  MessageNotifier({
    required this.events,
    this.caughtUp = const Stream.empty(),
    required this.myUserId,
    required this.db,
    required this.notifier,
    required this.previewsOn,
    required this.inFront,
  });

  final Stream<Map<String, Object?>> events;

  /// Messages that came in while this device was offline ([ChatSync.caughtUp]).
  final Stream<CaughtUp> caughtUp;
  final String myUserId;
  final ChatDb db;
  final LocalNotifier notifier;

  /// This device's "Show message previews" setting (never true on the web).
  final Future<bool> Function() previewsOn;
  final bool Function() inFront;

  final _subs = <StreamSubscription<Object?>>[];

  void start() {
    _subs
      ..add(events.listen((e) => unawaited(_onEvent(e))))
      ..add(caughtUp.listen((c) => unawaited(_onCaughtUp(c))));
  }

  Future<void> _onCaughtUp(CaughtUp c) async {
    if (inFront()) return;
    final route = chatRoute(c.chatId);
    if (route == null) return;
    try {
      final chat = await db.chatById(c.chatId);
      if (chat == null) return;
      // Read on another device meanwhile: nothing to tell.
      final unread = [for (final r in c.messages) if ((r.seq ?? 0) > chat.myLastReadSeq) r];
      if (unread.isEmpty) return;
      final mention = unread.lastWhereOrNull((r) => mentionsOf(r).contains(myUserId));
      final mentioned = mention != null;
      if (!mentioned && isMuted(chat, DateTime.now())) return;
      final last = unread.last;
      // A mention names who mentioned me, not whoever wrote last.
      final (title, generic) = await notificationText(db, c.chatId, (mention ?? last).senderUserId, mention: mentioned);
      final String body;
      if (unread.length > 1) {
        body = mentioned ? '$generic · ${unread.length} new messages' : '${unread.length} new messages';
      } else {
        body = await _rowPreviewBody(last) ?? generic;
      }
      await notifier.show(id: c.chatId.hashCode & 0x7fffffff, title: title, body: body, route: route);
    } catch (_) {
      // The database closed (signed out) meanwhile.
    }
  }

  Future<String?> _rowPreviewBody(MessageRow row) async {
    try {
      if (!await previewsOn()) return null;
      final preview = await rowPreviewText(db, row);
      return preview == null
          ? null
          : await previewBody(db: db, chatId: row.chatId, senderUserId: row.senderUserId, preview: preview);
    } catch (_) {
      return null;
    }
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
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
  }
}
