// A browser notification for a message that arrives while the tab is in the background. (A closed
// tab gets an FCM push through web/firebase-messaging-sw.js instead.)
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

import 'local_notifier.dart';

LocalNotifier? createLocalNotifier() => WebLocalNotifier();

class WebLocalNotifier implements LocalNotifier {
  void Function(String route)? _onTap;

  bool get _supported => globalContext.has('Notification');

  @override
  bool get needsPermission => _supported && web.Notification.permission == 'default';

  @override
  Future<void> init(void Function(String route) onTap) async => _onTap = onTap;

  @override
  Future<bool> requestPermission() async {
    if (!_supported) return false;
    final result = await web.Notification.requestPermission().toDart;
    return result.toDart == 'granted';
  }

  @override
  Future<void> show({required int id, required String title, required String body, required String route}) async {
    if (!_supported || web.Notification.permission != 'granted') return;
    try {
      final n = web.Notification(title, web.NotificationOptions(body: body, tag: 'famchat-$id', icon: '/icons/Icon-192.png'));
      n.onclick = (web.Event _) {
        web.window.focus();
        n.close();
        _onTap?.call(route);
      }.toJS;
    } catch (_) {
      // Some mobile browsers only allow notifications from a service worker; the tab still works.
    }
  }
}
