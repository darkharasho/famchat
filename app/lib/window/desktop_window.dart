// Which desktop app this is, and its window as providers, so tests can stand in for both.
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'window_controls.dart';

/// The desktop platform the app runs on (Windows, macOS, Linux), or null on phones and the web.
TargetPlatform? desktopPlatform({bool web = kIsWeb, TargetPlatform? platform}) {
  if (web) return null;
  final p = platform ?? defaultTargetPlatform;
  return switch (p) {
    TargetPlatform.windows || TargetPlatform.macOS || TargetPlatform.linux => p,
    _ => null,
  };
}

final desktopPlatformProvider = Provider<TargetPlatform?>((ref) => desktopPlatform());

/// The app's window on the desktop apps; null elsewhere.
final desktopWindowProvider = Provider<DesktopWindow?>(
  (ref) => ref.watch(desktopPlatformProvider) == null ? null : WindowControls.instance,
);

/// Whether the system has a tray for FamChat's icon (see [DesktopWindow.trayAvailable]). False
/// off the desktop.
final trayHostAvailableProvider = Provider<bool>((ref) {
  final window = ref.watch(desktopWindowProvider);
  if (window == null) return false;
  final available = window.trayAvailable;
  void changed() => ref.invalidateSelf();
  available.addListener(changed);
  ref.onDispose(() => available.removeListener(changed));
  return available.value;
});
