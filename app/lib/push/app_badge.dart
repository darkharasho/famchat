// The app-icon badge: while the app runs it shows [unreadTotalProvider]. On phones, pushes set it
// while the app doesn't run (iOS from `aps.badge`; Android from the `badge` data value, in
// firebaseBackgroundHandler). On the desktop apps it's the macOS Dock badge (app_badge_plus), the
// Windows taskbar overlay and the Linux launcher count (lib/window/desktop_badges.dart). The web
// has none.
import 'dart:async';

import 'package:app_badge_plus/app_badge_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../chat/providers.dart';
import '../chat/unread_total.dart';
import '../window/desktop_badges.dart';

/// Sets the app-icon number; 0 clears it.
typedef SetBadge = Future<void> Function(int count);

/// Whether app_badge_plus sets the badge on this platform: the Android and iOS apps, and the macOS
/// Dock.
bool isBadgePlatform({bool web = kIsWeb, TargetPlatform? platform}) {
  if (web) return false;
  final p = platform ?? defaultTargetPlatform;
  return p == TargetPlatform.android || p == TargetPlatform.iOS || p == TargetPlatform.macOS;
}

/// Sets the launcher badge to [count] (0 clears it). Never throws: a launcher without badges, or no
/// notification permission, just shows nothing.
Future<void> setAppBadge(int count) async {
  try {
    await AppBadgePlus.updateBadge(count < 0 ? 0 : count);
  } catch (e) {
    debugPrint('app badge not set: ${e.runtimeType}');
  }
}

/// How to set the badge on this platform, or null where there is none. Replaced in tests.
final appBadgeSetterProvider =
    Provider<SetBadge?>((ref) => ref.watch(desktopBadgeSetterProvider) ?? (isBadgePlatform() ? setAppBadge : null));

/// The number the badge should show: null until the chat list has loaded (so a badge a push set
/// isn't cleared by an empty first frame), 0 when signed out.
final appBadgeCountProvider = Provider<int?>((ref) {
  if (ref.watch(myUserIdProvider) == null) return 0;
  if (!ref.watch(chatListProvider).hasValue) return null;
  return ref.watch(unreadTotalProvider);
});

/// Keeps the icon badge equal to [appBadgeCountProvider] while the app runs, and sets it again on
/// return to the foreground (a push may have changed it meanwhile). Watched by the app root, so it
/// also clears the badge on sign-out.
final appBadgeProvider = Provider<void>((ref) {
  final set = ref.watch(appBadgeSetterProvider);
  if (set == null) return;
  ref.listen<int?>(appBadgeCountProvider, (_, n) {
    if (n != null) unawaited(set(n));
  }, fireImmediately: true);
  final lifecycle = AppLifecycleListener(
    onResume: () {
      final n = ref.read(appBadgeCountProvider);
      if (n != null) unawaited(set(n));
    },
  );
  ref.onDispose(lifecycle.dispose);
});
