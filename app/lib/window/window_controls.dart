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

  void close();

  /// The system's window menu at the pointer (move, resize, always on top, …).
  void showMenu();

  /// The running app's window. Talks to the runners on [ChannelWindowControls.channelName].
  static final WindowControls instance = ChannelWindowControls();
}

/// [WindowControls] over the `famchat/window` channel, answered by
/// linux/runner/my_application.cc, windows/runner/flutter_window.cpp and
/// macos/Runner/MainFlutterWindow.swift.
class ChannelWindowControls implements WindowControls {
  ChannelWindowControls() {
    _channel.setMethodCallHandler(_onCall);
    _call<Map<Object?, Object?>>('state').then(_apply);
  }

  static const channelName = 'famchat/window';

  final _channel = const MethodChannel(channelName);
  final _maximized = ValueNotifier(false);
  final _fullScreen = ValueNotifier(false);

  @override
  ValueListenable<bool> get maximized => _maximized;

  @override
  ValueListenable<bool> get fullScreen => _fullScreen;

  Future<Object?> _onCall(MethodCall call) async {
    if (call.method == 'stateChanged') _apply(call.arguments as Map<Object?, Object?>?);
    return null;
  }

  void _apply(Map<Object?, Object?>? state) {
    if (state == null) return;
    _maximized.value = state['maximized'] == true;
    _fullScreen.value = state['fullScreen'] == true;
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
  void close() => _call<void>('close');

  @override
  void showMenu() => _call<void>('showMenu');
}
