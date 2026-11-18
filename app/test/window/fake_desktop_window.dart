import 'package:famchat/window/window_controls.dart';
import 'package:flutter/foundation.dart';

/// A [DesktopWindow] that records what the app asks of it.
class FakeDesktopWindow implements DesktopWindow {
  FakeDesktopWindow({bool trayAvailable = true}) : trayAvailable = ValueNotifier(trayAvailable);

  @override
  final ValueNotifier<bool> trayAvailable;

  @override
  final ValueNotifier<bool> hidden = ValueNotifier(false);

  final closeToTray = <bool>[];
  final badges = <Map<String, Object?>>[];
  final trays = <Map<String, Object?>>[];
  var shows = 0;

  @override
  void setCloseToTray(bool on) => closeToTray.add(on);

  @override
  void show() => shows++;

  @override
  Future<void> setBadge(Map<String, Object?> badge) async => badges.add(badge);

  @override
  Future<void> setTray(Map<String, Object?> tray) async => trays.add(tray);
}
