// What the desktop runners get for the unread badge and the tray icon, per platform:
//   Windows: taskbar overlay and tray icons as BGRA pixels at several sizes; the runner picks the
//            size its DPI wants.
//   Linux:   the launcher count (Unity LauncherEntry over D-Bus) and tray icons as ARGB pixmaps
//            (StatusNotifierItem's format); the tray host picks the size.
//   macOS:   the Dock badge comes from app_badge_plus (lib/push/app_badge.dart); the menu bar item
//            gets a template glyph (PNG) and the count as its title.
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'desktop_window.dart';
import 'unread_badge_art.dart';

typedef IconSet = List<Map<String, Object?>>;

/// Renders the badge and tray art once per label and keeps it: there are only eleven labels.
class DesktopBadgeArt {
  final _overlays = <String, Future<IconSet>>{};
  final _trays = <String, Future<IconSet>>{};
  Future<Uint8List>? _glyph;

  static Future<IconSet> _icons(Future<ui.Image> Function(int size) render, Uint8List Function(Uint8List) convert) async {
    final out = <Map<String, Object?>>[];
    for (final size in iconSizes) {
      final image = await render(size);
      try {
        out.add({'size': size, 'pixels': convert(await straightRgba(image))});
      } finally {
        image.dispose();
      }
    }
    return out;
  }

  /// The Windows overlay for [label], BGRA.
  Future<IconSet> overlay(String label) =>
      _overlays[label] ??= _icons((s) => renderOverlayIcon(label, s), rgbaToBgra);

  /// The tray icon, BGRA on Windows and ARGB on Linux.
  Future<IconSet> tray(String? label, {required bool argb}) => _trays['${argb ? 'a' : 'b'}${label ?? ''}'] ??=
      _icons((s) => renderTrayIcon(label, s), argb ? rgbaToArgb : rgbaToBgra);

  /// The macOS menu bar glyph: 18 points at 2x.
  Future<Uint8List> templateGlyph() => _glyph ??= () async {
        final image = await renderTemplateGlyph(36);
        try {
          return await pngBytes(image);
        } finally {
          image.dispose();
        }
      }();
}

/// The `setBadge` arguments for [count] on [platform], or null where the window channel doesn't
/// carry the badge (macOS, phones).
Future<Map<String, Object?>?> badgePayload(TargetPlatform platform, int count, DesktopBadgeArt art) async {
  switch (platform) {
    case TargetPlatform.linux:
      return {'count': count < 0 ? 0 : count};
    case TargetPlatform.windows:
      final label = badgeLabel(count);
      return {
        'description': unreadDescription(count),
        'icons': label == null ? null : await art.overlay(label),
      };
    default:
      return null;
  }
}

/// The `setTray` arguments: hidden, or the icon for [count] with its tooltip.
Future<Map<String, Object?>> trayPayload(
  TargetPlatform platform, {
  required bool visible,
  required int count,
  required DesktopBadgeArt art,
}) async {
  if (!visible) return {'visible': false};
  final label = badgeLabel(count);
  final tooltip = trayTooltip(count);
  return switch (platform) {
    TargetPlatform.macOS => {
        'visible': true,
        'tooltip': tooltip,
        'title': label ?? '',
        'icon': await art.templateGlyph(),
      },
    _ => {
        'visible': true,
        'tooltip': tooltip,
        'icons': await art.tray(label, argb: platform == TargetPlatform.linux),
      },
  };
}

/// Runs async updates so only the newest one is sent: a fast run of count changes can't leave an
/// older count on screen.
class LatestOnly {
  var _generation = 0;

  Future<void> run<T>(Future<T> Function() build, FutureOr<void> Function(T value) send) async {
    final mine = ++_generation;
    final T value;
    try {
      value = await build();
    } catch (e) {
      debugPrint('desktop badge not drawn: $e');
      return;
    }
    if (mine == _generation) await send(value);
  }
}

final desktopBadgeArtProvider = Provider<DesktopBadgeArt>((ref) => DesktopBadgeArt());

/// Sets the Windows taskbar overlay or the Linux launcher count; null on other platforms (macOS
/// uses app_badge_plus). Used by lib/push/app_badge.dart.
final desktopBadgeSetterProvider = Provider<Future<void> Function(int count)?>((ref) {
  final platform = ref.watch(desktopPlatformProvider);
  final window = ref.watch(desktopWindowProvider);
  if (window == null || (platform != TargetPlatform.windows && platform != TargetPlatform.linux)) return null;
  final art = ref.watch(desktopBadgeArtProvider);
  final latest = LatestOnly();
  return (count) => latest.run(
        () => badgePayload(platform!, count, art),
        (payload) => payload == null ? null : window.setBadge(payload),
      );
});
