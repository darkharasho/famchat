import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The window edges the app starts resizes from. Only Windows uses these: its frameless window
/// gives the top edge to the app, while the system keeps the other three.
enum ResizeEdge { top, topLeft, topRight }

/// What the in-app title bar asks of the native window.
abstract class WindowControls {
  /// Whether the window is maximized, kept current by the platform.
  ValueListenable<bool> get maximized;

  /// Whether the window is full screen (macOS hides the title bar band then).
  ValueListenable<bool> get fullScreen;

  /// Moves the window with the pointer that is pressed now.
  void startDrag();

  /// Resizes the window from [edge] with the pointer that is pressed now.
  void startResize(ResizeEdge edge);

  void minimize();

  /// Maximizes, or restores a maximized window. macOS does what its "double-click a window's title
  /// bar to" setting says.
  void toggleMaximize();

  /// The close button: hides the window to the tray when Close to tray is on
  /// ([DesktopWindow.setCloseToTray]), else quits.
  void close();

  /// The system's window menu at the pointer (move, resize, always on top, …).
  void showMenu();

  /// The running app's window. Talks to the runners on [ChannelWindowControls.channelName].
  static final ChannelWindowControls instance = ChannelWindowControls();
}

/// The desktop app's window beyond its title bar: closing to the tray, the tray icon and the
/// taskbar or launcher badge (docs/superpowers/specs/2026-11-18-desktop-badges-tray-design.md).
abstract class DesktopWindow {
  /// Whether a tray (notification area, menu bar) can take FamChat's icon: always on Windows and
  /// macOS; on Linux while a StatusNotifierItem host runs.
  ValueListenable<bool> get trayAvailable;

  /// Whether the window is hidden to the tray right now.
  ValueListenable<bool> get hidden;

  /// When on, closing the window (the title bar's button, Alt+F4, the macOS red button) hides it
  /// and keeps the app running; when off, closing quits. The runners still close for real when
  /// the tray icon isn't showing, so the window can't be lost.
  void setCloseToTray(bool on);

  /// Shows the window and brings it to the front.
  void show();

  /// The taskbar overlay (Windows) or launcher count (Linux), as built by
  /// `lib/window/desktop_badges.dart` for the running platform.
  Future<void> setBadge(Map<String, Object?> badge);

  /// The tray icon: shown or not, its image and its tooltip (`lib/window/desktop_badges.dart`).
  Future<void> setTray(Map<String, Object?> tray);
}

/// [WindowControls] and [DesktopWindow] over the `famchat/window` channel, answered by
/// linux/runner/my_application.cc, windows/runner/flutter_window.cpp and
/// macos/Runner/MainFlutterWindow.swift.
class ChannelWindowControls implements WindowControls, DesktopWindow {
  ChannelWindowControls() {
    _channel.setMethodCallHandler(_onCall);
    _call<Map<Object?, Object?>>('state').then(_apply);
  }

  static const channelName = 'famchat/window';

  final _channel = const MethodChannel(channelName);
  final _maximized = ValueNotifier(false);
  final _fullScreen = ValueNotifier(false);
  final _trayAvailable = ValueNotifier(false);
  final _hidden = ValueNotifier(false);
  bool _closeToTray = false;

  @override
  ValueListenable<bool> get maximized => _maximized;

  @override
  ValueListenable<bool> get fullScreen => _fullScreen;

  @override
  ValueListenable<bool> get trayAvailable => _trayAvailable;

  @override
  ValueListenable<bool> get hidden => _hidden;

  Future<Object?> _onCall(MethodCall call) async {
    if (call.method == 'stateChanged') _apply(call.arguments as Map<Object?, Object?>?);
    return null;
  }

  void _apply(Map<Object?, Object?>? state) {
    if (state == null) return;
    _maximized.value = state['maximized'] == true;
    _fullScreen.value = state['fullScreen'] == true;
    _trayAvailable.value = state['trayAvailable'] == true;
    _hidden.value = state['hidden'] == true;
  }

  /// Calls [method], or does nothing where no runner answers (the web, tests).
  Future<T?> _call<T>(String method, [Object? arguments]) async {
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on MissingPluginException {
      return null;
    } on PlatformException catch (e) {
      debugPrint('window $method failed: ${e.message}');
      return null;
    }
  }

  @override
  void startDrag() => _call<void>('startDrag');

  @override
  void startResize(ResizeEdge edge) => _call<void>('startResize', edge.name);

  @override
  void minimize() => _call<void>('minimize');

  @override
  void toggleMaximize() => _call<void>('toggleMaximize');

  @override
  void close() => _call<void>(_closeToTray ? 'hide' : 'quit');

  @override
  void showMenu() => _call<void>('showMenu');

  @override
  void setCloseToTray(bool on) {
    _closeToTray = on;
    _call<void>('setCloseToTray', on);
  }

  @override
  void show() => _call<void>('show');

  @override
  Future<void> setBadge(Map<String, Object?> badge) => _call<void>('setBadge', badge);

  @override
  Future<void> setTray(Map<String, Object?> tray) => _call<void>('setTray', tray);
}
