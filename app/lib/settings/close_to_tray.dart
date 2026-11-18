// The per-device "Close to tray" setting of the desktop apps ("Keep running in the menu bar" on
// macOS). Stored locally with SharedPreferencesAsync, like the time format.
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../window/desktop_window.dart';

const closeToTrayPrefKey = 'close_to_tray';

/// On by default on Windows, where apps living in the notification area is usual; off on Linux
/// (not every desktop has a tray) and macOS (where closing the window quits FamChat today).
bool closeToTrayDefault(TargetPlatform platform) => platform == TargetPlatform.windows;

/// What the setting is called on [platform].
String closeToTrayTitle(TargetPlatform platform) =>
    platform == TargetPlatform.macOS ? 'Keep running in the menu bar' : 'Close to tray';

/// The stored choice, or [platform]'s default when there is none.
Future<bool> readCloseToTray(TargetPlatform platform, [SharedPreferencesAsync? prefs]) async =>
    await (prefs ?? SharedPreferencesAsync()).getBool(closeToTrayPrefKey) ?? closeToTrayDefault(platform);

Future<void> writeCloseToTray(bool on, [SharedPreferencesAsync? prefs]) =>
    (prefs ?? SharedPreferencesAsync()).setBool(closeToTrayPrefKey, on);

/// The stored setting; false off the desktop.
class CloseToTrayNotifier extends AsyncNotifier<bool> {
  @override
  Future<bool> build() async {
    final platform = ref.watch(desktopPlatformProvider);
    return platform == null ? false : readCloseToTray(platform);
  }

  Future<void> set(bool on) async {
    await writeCloseToTray(on);
    state = AsyncData(on);
  }
}

final closeToTrayProvider = AsyncNotifierProvider<CloseToTrayNotifier, bool>(CloseToTrayNotifier.new);

/// Whether Settings offers the option: on the desktop apps while there is a tray to close to. A
/// Linux desktop without a StatusNotifierItem host hides it, and closing always quits there.
final closeToTrayOfferedProvider = Provider<bool>(
  (ref) => ref.watch(desktopPlatformProvider) != null && ref.watch(trayHostAvailableProvider),
);

/// Whether closing the window hides it to the tray now: offered and switched on. Off while the
/// setting loads.
final closeToTrayActiveProvider = Provider<bool>(
  (ref) => ref.watch(closeToTrayOfferedProvider) && (ref.watch(closeToTrayProvider).value ?? false),
);
