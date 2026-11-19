import 'package:famchat/push/local_notifier_io.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records the plugin calls DesktopLocalNotifier makes.
class FakePlugin implements FlutterLocalNotificationsPlugin {
  final calls = <String>[];

  @override
  Future<bool?> initialize({
    required InitializationSettings settings,
    DidReceiveNotificationResponseCallback? onDidReceiveNotificationResponse,
    DidReceiveBackgroundNotificationResponseCallback? onDidReceiveBackgroundNotificationResponse,
  }) async =>
      true;

  @override
  Future<NotificationAppLaunchDetails?> getNotificationAppLaunchDetails() async => null;

  @override
  Future<void> cancel({required int id, String? tag}) async => calls.add('cancel $id');

  @override
  Future<void> show({
    required int id,
    String? title,
    String? body,
    NotificationDetails? notificationDetails,
    String? payload,
  }) async =>
      calls.add('show $id $body');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  Future<FakePlugin> showTwice(TargetPlatform platform) async {
    final plugin = FakePlugin();
    final n = DesktopLocalNotifier(plugin: plugin, platform: platform);
    await n.init((_) {});
    await n.show(id: 7, title: 'Amanda', body: 'one', route: '/chats/c');
    await n.show(id: 7, title: 'Amanda', body: 'two', route: '/chats/c');
    return plugin;
  }

  test('Linux closes the chat\'s last notification first, so Plasma pops the new one up', () async {
    // A Notify that replaces an existing notification only updates it in Plasma's history.
    final plugin = await showTwice(TargetPlatform.linux);
    expect(plugin.calls, ['cancel 7', 'show 7 one', 'cancel 7', 'show 7 two']);
  });

  test('macOS and Windows replace in place', () async {
    for (final p in [TargetPlatform.macOS, TargetPlatform.windows]) {
      final plugin = await showTwice(p);
      expect(plugin.calls, ['show 7 one', 'show 7 two'], reason: '$p');
    }
  });
}
