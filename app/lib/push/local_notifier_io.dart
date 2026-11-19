// Desktop notifications through flutter_local_notifications: UserNotifications on macOS, toast
// notifications on Windows, the freedesktop notification service (D-Bus) on Linux.
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../window/window_controls.dart';
import 'chat_route.dart';
import 'local_notifier.dart';

LocalNotifier? createLocalNotifier() => switch (defaultTargetPlatform) {
      TargetPlatform.macOS || TargetPlatform.windows || TargetPlatform.linux => DesktopLocalNotifier(),
      _ => null,
    };

class DesktopLocalNotifier implements LocalNotifier {
  DesktopLocalNotifier({FlutterLocalNotificationsPlugin? plugin, TargetPlatform? platform})
      : _plugin = plugin ?? FlutterLocalNotificationsPlugin(),
        _platform = platform ?? defaultTargetPlatform;

  final FlutterLocalNotificationsPlugin _plugin;
  final TargetPlatform _platform;
  bool _ready = false;

  @override
  bool get needsPermission => false;

  @override
  Future<void> init(void Function(String route) onTap) async {
    try {
      _ready = await _plugin.initialize(
            settings: const InitializationSettings(
              macOS: DarwinInitializationSettings(
                requestAlertPermission: false,
                requestBadgePermission: false,
                requestSoundPermission: false,
              ),
              linux: LinuxInitializationSettings(defaultActionName: 'Open'),
              windows: WindowsInitializationSettings(
                appName: 'FamChat',
                appUserModelId: 'dev.famchat.app',
                guid: '5b0d8a52-7c4e-4f6e-9a7c-3e1f2d6b8c41',
              ),
            ),
            onDidReceiveNotificationResponse: (r) {
              // The window may be hidden to the tray: a tap on a notification brings it back.
              WindowControls.instance.show();
              final route = r.payload;
              if (isChatRoute(route)) onTap(route!);
            },
          ) ??
          false;
      // A tap on a notification left in the notification center that launched the app.
      final launch = _ready ? await _plugin.getNotificationAppLaunchDetails() : null;
      final route = launch?.notificationResponse?.payload;
      if (launch?.didNotificationLaunchApp == true && isChatRoute(route)) onTap(route!);
    } catch (e) {
      // No notification service (a Linux desktop without one, say): the app works without.
      debugPrint('desktop notifications unavailable: $e');
    }
  }

  @override
  Future<bool> requestPermission() async {
    if (!_ready) return false;
    if (_platform != TargetPlatform.macOS) return true;
    final mac = _plugin.resolvePlatformSpecificImplementation<MacOSFlutterLocalNotificationsPlugin>();
    return await mac?.requestPermissions(alert: true, sound: true) ?? false;
  }

  @override
  Future<void> show({required int id, required String title, required String body, required String route}) async {
    if (!_ready) return;
    try {
      // Linux: the plugin sends a notification that reuses an id as a replacement of the last one
      // (Notify's replaces_id), and Plasma only updates a replaced notification in its history, with
      // no popup. Closing the chat's last notification first makes each message a new one that pops
      // up; the chat still keeps a single notification.
      if (_platform == TargetPlatform.linux) await _plugin.cancel(id: id);
      await _plugin.show(
        id: id,
        title: title,
        body: body,
        payload: route,
        notificationDetails: const NotificationDetails(
          macOS: DarwinNotificationDetails(presentSound: true),
          linux: LinuxNotificationDetails(),
          windows: WindowsNotificationDetails(),
        ),
      );
    } catch (e) {
      debugPrint('notification failed: $e');
    }
  }
}
