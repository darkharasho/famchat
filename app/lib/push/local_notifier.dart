// Notifications the running app shows itself, from its socket: desktop apps (macOS, Windows, Linux)
// and a web tab in the background. Phones get FCM pushes instead.
import 'local_notifier_stub.dart'
    if (dart.library.js_interop) 'local_notifier_web.dart'
    if (dart.library.io) 'local_notifier_io.dart' as impl;

abstract class LocalNotifier {
  /// Prepares the notifier; [onTap] gets the route of a tapped notification.
  Future<void> init(void Function(String route) onTap);

  /// Whether the user still has to be asked (only the web asks from a button).
  bool get needsPermission;

  /// Asks for permission where the platform needs it; true when notifications may show.
  Future<bool> requestPermission();

  /// Shows (or replaces, per [id]) a notification that opens [route] when tapped.
  Future<void> show({required int id, required String title, required String body, required String route});
}

/// The notifier for this platform, or null where the app gets pushes instead (Android, iOS).
LocalNotifier? createLocalNotifier() => impl.createLocalNotifier();
