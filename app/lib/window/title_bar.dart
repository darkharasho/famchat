// FamChat's own title bar on the desktop apps. Windows and Linux hide the system title bar (see
// windows/runner/win32_window.cpp and linux/runner/my_application.cc) and get this one, with the
// platform's caption buttons; macOS keeps its traffic lights over a transparent title bar and gets
// a blank band under them (macos/Runner/MainFlutterWindow.swift). Phones and the web are unchanged.
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show kPrimaryMouseButton;
import 'package:material_ui/material_ui.dart';

import '../theme/app_theme.dart';
import '../widgets/brand_mark.dart';
import 'window_controls.dart';

/// Which title bar the app draws.
enum WindowChrome {
  /// None: the platform's own (phones, the web).
  system,

  /// A blank, draggable band under the macOS traffic lights.
  macos,

  /// Icon and name on the left, rectangular caption buttons on the right; close turns red.
  windows,

  /// Centered name, round GNOME-style caption buttons on the right.
  linux,
}

WindowChrome windowChromeFor(TargetPlatform platform, {bool web = kIsWeb}) {
  if (web) return WindowChrome.system;
  return switch (platform) {
    TargetPlatform.macOS => WindowChrome.macos,
    TargetPlatform.windows => WindowChrome.windows,
    TargetPlatform.linux => WindowChrome.linux,
    _ => WindowChrome.system,
  };
}

/// Puts the title bar above [child], the whole app, on desktop. Elsewhere returns [child].
class WindowFrame extends StatelessWidget {
  const WindowFrame({super.key, required this.child, this.chrome, this.controls});

  final Widget child;

  /// Defaults to the running platform's.
  final WindowChrome? chrome;

  /// Defaults to [WindowControls.instance].
  final WindowControls? controls;

  @override
  Widget build(BuildContext context) {
    final chrome = this.chrome ?? windowChromeFor(defaultTargetPlatform);
    if (chrome == WindowChrome.system) return child;
    return Column(children: [
      AppTitleBar(chrome: chrome, controls: controls ?? WindowControls.instance),
      // Its own semantics container: the routes block the semantics of whatever was painted before them
      // in theirs, which would hide the title bar from screen readers.
      Expanded(child: Semantics(container: true, child: child)),
    ]);
  }
}

class AppTitleBar extends StatelessWidget {
  const AppTitleBar({super.key, required this.chrome, required this.controls});

  final WindowChrome chrome;
  final WindowControls controls;

  static const macosHeight = 28.0, windowsHeight = 32.0, linuxHeight = 38.0;

  /// Room for the traffic lights, which sit over the band's left end.
  static const macosLeading = 80.0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: Listenable.merge([controls.maximized, controls.fullScreen]),
      builder: (context, _) {
        final maximized = controls.maximized.value;
        // Full screen has no title bar; macOS slides its own in when the pointer reaches the top.
        if (controls.fullScreen.value) return const SizedBox.shrink();
        return Semantics(
          container: true,
          explicitChildNodes: true,
          child: Material(
            color: scheme.surface,
            child: switch (chrome) {
              WindowChrome.macos => SizedBox(
                  height: macosHeight,
                  child: _DragArea(controls: controls, child: const SizedBox.expand()),
                ),
              WindowChrome.windows => _windows(context, maximized),
              WindowChrome.linux => _linux(context, maximized),
              WindowChrome.system => const SizedBox.shrink(),
            },
          ),
        );
      },
    );
  }

  Widget _windows(BuildContext context, bool maximized) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: windowsHeight,
      child: Stack(children: [
        Row(children: [
          Expanded(
            child: _DragArea(
              controls: controls,
              child: Padding(
                padding: const EdgeInsets.only(left: 12),
                child: Row(children: [
                  const ExcludeSemantics(child: BrandMark(size: 16)),
                  const SizedBox(width: 10),
                  Flexible(child: _Title(color: scheme.onSurface, size: 12.5)),
                ]),
              ),
            ),
          ),
          _WindowsButton(glyph: _Glyph.minimize, label: 'Minimize', onPressed: controls.minimize),
          _WindowsButton(
            glyph: maximized ? _Glyph.restore : _Glyph.maximize,
            label: maximized ? 'Restore' : 'Maximize',
            onPressed: controls.toggleMaximize,
          ),
          _WindowsButton(glyph: _Glyph.close, label: 'Close', onPressed: controls.close, close: true),
        ]),
        // The frameless window leaves its top edge to the app; the system resizes the other three.
        if (!maximized) _TopResizeEdge(controls: controls),
      ]),
    );
  }

  Widget _linux(BuildContext context, bool maximized) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: linuxHeight,
      child: Stack(children: [
        Positioned.fill(
          child: _DragArea(
            controls: controls,
            child: Center(
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const ExcludeSemantics(child: BrandMark(size: 16)),
                const SizedBox(width: 8),
                _Title(color: scheme.onSurface, size: 14),
              ]),
            ),
          ),
        ),
        Positioned(
          right: 8,
          top: 0,
          bottom: 0,
          child: Row(children: [
            _LinuxButton(glyph: _Glyph.minimize, label: 'Minimize', onPressed: controls.minimize),
            const SizedBox(width: 10),
            _LinuxButton(
              glyph: maximized ? _Glyph.restore : _Glyph.maximize,
              label: maximized ? 'Restore' : 'Maximize',
              onPressed: controls.toggleMaximize,
            ),
            const SizedBox(width: 10),
            _LinuxButton(glyph: _Glyph.close, label: 'Close', onPressed: controls.close),
          ]),
        ),
      ]),
    );
  }
}

class _Title extends StatelessWidget {
  const _Title({required this.color, required this.size});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => Text(
        'FamChat',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontFamily: kDisplayFont,
          fontWeight: FontWeight.w600,
          fontSize: size,
          height: 1,
          letterSpacing: -0.1,
          color: color,
        ),
      );
}

/// Drags the window; a double click maximizes or restores it, a right click opens the window menu.
class _DragArea extends StatelessWidget {
  const _DragArea({required this.controls, required this.child});

  final WindowControls controls;
  final Widget child;

  @override
  Widget build(BuildContext context) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        // Window moves are the window manager's; screen readers have its own keys for them.
        excludeFromSemantics: true,
        onPanStart: (_) => controls.startDrag(),
        onDoubleTap: controls.toggleMaximize,
        onSecondaryTap: controls.showMenu,
        child: child,
      );
}

/// A thin strip along the top that resizes the window (Windows).
class _TopResizeEdge extends StatelessWidget {
  const _TopResizeEdge({required this.controls});

  final WindowControls controls;

  static const thickness = 4.0, corner = 12.0;

  @override
  Widget build(BuildContext context) {
    Widget edge(ResizeEdge e, MouseCursor cursor) => MouseRegion(
          cursor: cursor,
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (event) {
              if (event.buttons == kPrimaryMouseButton) controls.startResize(e);
            },
          ),
        );
    return Positioned(
      left: 0,
      right: 0,
      top: 0,
      height: thickness,
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(width: corner, child: edge(ResizeEdge.topLeft, SystemMouseCursors.resizeUpLeft)),
        Expanded(child: edge(ResizeEdge.top, SystemMouseCursors.resizeUp)),
        SizedBox(width: corner, child: edge(ResizeEdge.topRight, SystemMouseCursors.resizeUpRight)),
      ]),
    );
  }
}

/// Hover and press state for a caption button.
class _CaptionButton extends StatefulWidget {
  const _CaptionButton({required this.label, required this.onPressed, required this.builder});

  final String label;
  final VoidCallback onPressed;
  final Widget Function(BuildContext context, bool hovered, bool pressed) builder;

  @override
  State<_CaptionButton> createState() => _CaptionButtonState();
}

class _CaptionButtonState extends State<_CaptionButton> {
  var _hovered = false, _pressed = false;

  @override
  Widget build(BuildContext context) => Semantics(
        container: true,
        button: true,
        label: widget.label,
        child: MouseRegion(
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() {
            _hovered = false;
            _pressed = false;
          }),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (_) => setState(() => _pressed = true),
            onTapCancel: () => setState(() => _pressed = false),
            onTapUp: (_) => setState(() => _pressed = false),
            onTap: widget.onPressed,
            child: widget.builder(context, _hovered, _pressed),
          ),
        ),
      );
}

class _WindowsButton extends StatelessWidget {
  const _WindowsButton({required this.glyph, required this.label, required this.onPressed, this.close = false});

  final _Glyph glyph;
  final String label;
  final VoidCallback onPressed;
  final bool close;

  /// Windows 11's close-button red.
  static const closeRed = Color(0xFFC42B1C);

  @override
  Widget build(BuildContext context) {
    final fg = Theme.of(context).colorScheme.onSurface;
    return _CaptionButton(
      label: label,
      onPressed: onPressed,
      builder: (context, hovered, pressed) {
        final Color bg;
        if (close) {
          bg = pressed ? closeRed.withValues(alpha: 0.85) : (hovered ? closeRed : Colors.transparent);
        } else {
          bg = pressed ? fg.withValues(alpha: 0.12) : (hovered ? fg.withValues(alpha: 0.07) : Colors.transparent);
        }
        final iconColor = close && (hovered || pressed) ? Colors.white : fg;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 90),
          width: 46,
          color: bg,
          alignment: Alignment.center,
          child: CustomPaint(size: const Size.square(10), painter: _GlyphPainter(glyph, iconColor, 1)),
        );
      },
    );
  }
}

class _LinuxButton extends StatelessWidget {
  const _LinuxButton({required this.glyph, required this.label, required this.onPressed});

  final _Glyph glyph;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final fg = Theme.of(context).colorScheme.onSurface;
    return _CaptionButton(
      label: label,
      onPressed: onPressed,
      builder: (context, hovered, pressed) => Center(
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 90),
          width: 24,
          height: 24,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: fg.withValues(alpha: pressed ? 0.2 : (hovered ? 0.14 : 0.08)),
          ),
          child: CustomPaint(size: const Size.square(8), painter: _GlyphPainter(glyph, fg, 1.5)),
        ),
      ),
    );
  }
}

enum _Glyph { minimize, maximize, restore, close }

/// Caption glyphs as hairlines, so they stay crisp at any scale.
class _GlyphPainter extends CustomPainter {
  const _GlyphPainter(this.glyph, this.color, this.stroke);

  final _Glyph glyph;
  final Color color;
  final double stroke;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..strokeWidth = stroke
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true;
    final w = size.width, h = size.height, half = stroke / 2;
    switch (glyph) {
      case _Glyph.minimize:
        canvas.drawLine(Offset(0, h / 2), Offset(w, h / 2), p);
      case _Glyph.maximize:
        canvas.drawRect(Rect.fromLTRB(half, half, w - half, h - half), p);
      case _Glyph.restore:
        final o = w * 0.22;
        canvas.drawRect(Rect.fromLTRB(half, o + half, w - o - half, h - half), p);
        canvas.drawPath(
          Path()
            ..moveTo(o + half, o + half)
            ..lineTo(o + half, half)
            ..lineTo(w - half, half)
            ..lineTo(w - half, h - o - half)
            ..lineTo(w - o - half, h - o - half),
          p,
        );
      case _Glyph.close:
        canvas
          ..drawLine(Offset.zero, Offset(w, h), p)
          ..drawLine(Offset(w, 0), Offset(0, h), p);
    }
  }

  @override
  bool shouldRepaint(_GlyphPainter old) => old.glyph != glyph || old.color != color || old.stroke != stroke;
}
