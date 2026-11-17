// Android with "Show message previews" on: the server sends a data-only push carrying the message's
// encrypted envelope, and the app draws the notification itself, with the decrypted text when it can
// and the server's generic text otherwise. Background and terminated pushes come through
// [firebaseBackgroundHandler] (its own isolate); foreground pushes through PushController's enrich.
// Never log a preview or an envelope.
import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../chat/db/chat_db.dart';
import 'chat_route.dart';
import 'preview.dart';
import 'preview_setting.dart';
import 'push_messaging.dart';

/// The text [m] carried from the server: who and where, never what.
({String title, String body}) _genericText(PushMessage m) => (title: m.title ?? 'FamChat', body: m.body ?? 'New message');

/// The notification text for [m]: the decrypted preview when it's a preview push, previews are on
/// here and the message decrypts; otherwise the generic title and body it carried. Never throws.
Future<({String title, String body})> previewNotificationText(
  PushMessage m, {
  required Future<bool> Function() previewsOn,
  required Future<ChatDb> Function() openDb,
}) async {
  final generic = _genericText(m);
  final chatId = m.chatId, messageId = m.messageId, user = m.senderUserId, device = m.senderDeviceId;
  final envelope = m.envelope;
  if (!m.isPreview || chatId == null || messageId == null || user == null || device == null || envelope == null) {
    return generic;
  }
  try {
    if (!await previewsOn()) return generic;
    final db = await openDb();
    final preview = await previewText(
      db: db,
      chatId: chatId,
      messageId: messageId,
      senderUserId: user,
      senderDeviceId: device,
      envelope: envelope,
    );
    if (preview == null) return generic;
    return (title: generic.title, body: await previewBody(db: db, chatId: chatId, senderUserId: user, preview: preview));
  } catch (_) {
    return generic;
  }
}

const _channel = AndroidNotificationChannel(
  'messages',
  'Messages',
  description: 'New messages from your family',
  importance: Importance.high,
);

/// Initialises flutter_local_notifications for Android and makes sure the `messages` channel exists
/// (MainActivity creates the same one; creating it again changes nothing).
Future<FlutterLocalNotificationsPlugin> _androidNotifications({void Function(String route)? onTap}) async {
  final plugin = FlutterLocalNotificationsPlugin();
  await plugin.initialize(
    settings: const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')),
    onDidReceiveNotificationResponse: onTap == null
        ? null
        : (r) {
            final route = r.payload;
            if (isChatRoute(route)) onTap(route!);
          },
  );
  await plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()?.createNotificationChannel(_channel);
  return plugin;
}

/// Shows a preview push in the background or with the app closed. Other pushes carry a
/// notification block the OS shows itself.
@pragma('vm:entry-point')
Future<void> firebaseBackgroundHandler(RemoteMessage message) async {
  final m = PushMessage.fromData(message.data, title: message.notification?.title, body: message.notification?.body);
  final chatId = m.chatId;
  if (!m.isPreview || chatId == null) return;
  try {
    final options = firebaseOptions();
    if (Firebase.apps.isEmpty && options != null) await Firebase.initializeApp(options: options);
  } catch (e) {
    // The notification doesn't need Firebase; carry on.
    debugPrint('background push: Firebase failed to start: ${e.runtimeType}');
  }
  try {
    final plugin = await _androidNotifications();
    ChatDb? db;
    final text = await previewNotificationText(
      m,
      previewsOn: readPreviewsOn,
      openDb: () async => db = openChatDb(),
    ).timeout(const Duration(seconds: 10), onTimeout: () => _genericText(m));
    try {
      await db?.close();
    } catch (_) {}
    await plugin.show(
      id: chatId.hashCode & 0x7fffffff,
      title: text.title,
      body: text.body,
      payload: chatRoute(chatId),
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          _channel.id,
          _channel.name,
          channelDescription: _channel.description,
          importance: Importance.high,
          priority: Priority.high,
          tag: chatId,
          // flutter_local_notifications 23 has no publicVersion; the lock screen's own "contents
          // hidden" redaction stands in for a generic public version.
          visibility: NotificationVisibility.private,
        ),
      ),
    );
  } catch (e) {
    // Nothing more to do. Only the error's type: its message could hold message text.
    debugPrint('background push: notification failed: ${e.runtimeType}');
  }
}

bool _launchHandled = false;

/// Android: routes taps on the notifications [firebaseBackgroundHandler] draws (FCM's own tap
/// streams don't see them), including the tap that launched the app, once per process.
Future<void> routeAndroidNotificationTaps(void Function(String route) go) async {
  try {
    final plugin = await _androidNotifications(onTap: go);
    if (_launchHandled) return;
    _launchHandled = true;
    final launch = await plugin.getNotificationAppLaunchDetails();
    final route = launch?.notificationResponse?.payload;
    if (launch?.didNotificationLaunchApp == true && isChatRoute(route)) go(route!);
  } catch (e) {
    debugPrint('notification taps unavailable: ${e.runtimeType}');
  }
}
