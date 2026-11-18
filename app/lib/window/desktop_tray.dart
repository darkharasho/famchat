// Close to tray on the desktop apps: tells the runner whether closing hides the window, and keeps
// the tray icon (shown while the setting is on) in step with the unread count.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../push/app_badge.dart';
import '../settings/close_to_tray.dart';
import 'desktop_badges.dart';
import 'desktop_window.dart';

/// The tray icon's state: shown or not, and the count on it.
typedef TrayState = ({bool visible, int count});

final trayStateProvider = Provider<TrayState>((ref) => (
      visible: ref.watch(closeToTrayActiveProvider),
      count: ref.watch(appBadgeCountProvider) ?? 0,
    ));

/// Watched by the app root. Does nothing off the desktop.
final desktopTrayProvider = Provider<void>((ref) {
  final window = ref.watch(desktopWindowProvider);
  final platform = ref.watch(desktopPlatformProvider);
  if (window == null || platform == null) return;
  final art = ref.watch(desktopBadgeArtProvider);
  final latest = LatestOnly();
  ref.listen<bool>(closeToTrayActiveProvider, (_, on) => window.setCloseToTray(on), fireImmediately: true);
  var everShown = false;
  ref.listen<TrayState>(trayStateProvider, (_, next) {
    // Nothing to take down while the icon has never been up.
    if (!next.visible && !everShown) return;
    everShown = true;
    unawaited(latest.run(
      () => trayPayload(platform, visible: next.visible, count: next.count, art: art),
      window.setTray,
    ));
  }, fireImmediately: true);
});
