// Photos in a conversation: the thumbnail inside a bubble, and the full-screen viewer.

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../chat/plaintext.dart';
import '../../media/media_service.dart';
import '../../media/providers.dart';
import '../../theme/tokens.dart';

const _maxThumbWidth = 260.0, _maxThumbHeight = 320.0;

/// The on-screen size of a photo bubble for an image of [width]×[height].
Size thumbSize(int width, int height) {
  final aspect = width / height;
  var w = _maxThumbWidth, h = w / aspect;
  if (h > _maxThumbHeight) {
    h = _maxThumbHeight;
    w = h * aspect;
  }
  return Size(w.clamp(80.0, _maxThumbWidth), h.clamp(60.0, _maxThumbHeight));
}

bool _isExpired(WidgetRef ref, PhotoBody body) {
  final expired = ref.watch(expiredMediaProvider).value ?? const <String>{};
  return expired.contains(body.mediaKey) || expired.contains(body.thumbKey);
}

class _Expired extends StatelessWidget {
  const _Expired({this.light = false});
  final bool light;

  @override
  Widget build(BuildContext context) {
    final color = light ? Colors.white70 : Theme.of(context).colorScheme.onSurfaceVariant;
    return Center(
      key: const Key('media-expired'),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.hide_image_outlined, color: color),
        const SizedBox(height: 4),
        Text('Photo expired', style: TextStyle(color: color)),
      ]),
    );
  }
}

/// A photo's thumbnail: loading, shown, uploading (progress ring), expired or failed (tap retries).
class PhotoThumb extends ConsumerWidget {
  const PhotoThumb({super.key, required this.body, required this.messageId, required this.onOpen, this.size, this.radius});

  /// A tile in an album: this size (cropped to fill) and corner radius instead of the bubble's.
  final Size? size;
  final double? radius;

  final PhotoBody body;
  final String messageId;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final size = this.size ?? thumbSize(body.width, body.height);
    final progress = ref.watch(uploadProgressProvider(messageId)).value;
    final Widget child;
    VoidCallback? onTap;
    if (_isExpired(ref, body)) {
      child = const _Expired();
    } else {
      final thumb = ref.watch(mediaBytesProvider(body.thumbRef));
      switch (thumb) {
        case AsyncData(value: final Uint8List bytes):
          child = Image.memory(
            bytes,
            key: const Key('photo-thumb'),
            fit: BoxFit.cover,
            gaplessPlayback: true,
            cacheWidth: (size.width * 2).round(),
            errorBuilder: (_, _, _) => Icon(Icons.broken_image_outlined, color: scheme.onSurfaceVariant),
          );
          onTap = onOpen;
        case AsyncData():
          child = const _Expired();
        case AsyncError():
          child = Center(
            key: const Key('photo-error'),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.refresh, color: scheme.onSurfaceVariant),
              Text("Couldn't load photo", style: TextStyle(color: scheme.onSurfaceVariant)),
            ]),
          );
          onTap = () => ref.invalidate(mediaBytesProvider(body.thumbRef));
        default:
          child = const Center(child: SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2)));
      }
    }
    return Semantics(
      label: 'Photo',
      button: onTap != null,
      child: GestureDetector(
        onTap: onTap,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(radius ?? Radii.lg - 4),
          child: Container(
            width: size.width,
            height: size.height,
            color: scheme.surfaceContainerHigh,
            child: Stack(fit: StackFit.expand, children: [
              child,
              if (progress != null && progress < 1)
                ColoredBox(
                  color: Colors.black38,
                  child: Center(
                    child: CircularProgressIndicator(
                      key: const Key('upload-progress'),
                      value: progress == 0 ? null : progress,
                      color: Colors.white,
                    ),
                  ),
                ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Opens [body] full screen.
Future<void> showPhotoViewer(BuildContext context, PhotoBody body) => Navigator.of(context).push(
      PageRouteBuilder<void>(
        opaque: true,
        pageBuilder: (_, _, _) => PhotoViewer(body: body),
        transitionsBuilder: (_, a, _, child) => FadeTransition(opacity: a, child: child),
      ),
    );

/// Whether this device mostly uses a mouse: the viewer shows its zoom bar.
bool get _mouseFirst =>
    kIsWeb || {TargetPlatform.linux, TargetPlatform.macOS, TargetPlatform.windows}.contains(defaultTargetPlatform);

/// The full image on black; the thumbnail shows while it downloads. Pinch, scroll or double-tap to
/// zoom and drag to pan; on desktop a zoom bar (−, slider, +, fit) and the +, − and 0 keys too.
class PhotoViewer extends ConsumerStatefulWidget {
  const PhotoViewer({super.key, required this.body, this.zoomBar});

  final PhotoBody body;

  /// Shows the zoom bar; null shows it on desktop and the web.
  final bool? zoomBar;

  static const minScale = 1.0, maxScale = 8.0;

  @override
  ConsumerState<PhotoViewer> createState() => _PhotoViewerState();
}

class _PhotoViewerState extends ConsumerState<PhotoViewer> {
  final _zoom = TransformationController();
  Size _viewport = Size.zero;
  Offset? _doubleTapAt;

  @override
  void dispose() {
    _zoom.dispose();
    super.dispose();
  }

  double get _scale => _zoom.value.getMaxScaleOnAxis();

  /// Zooms to [scale] keeping the scene point under [focus] (default: the middle) in place, and
  /// keeps the photo covering the viewport.
  void _zoomTo(double scale, [Offset? focus]) {
    final s = scale.clamp(PhotoViewer.minScale, PhotoViewer.maxScale);
    final v = _viewport;
    final f = focus ?? v.center(Offset.zero);
    final scene = _zoom.toScene(f);
    final tx = (f.dx - scene.dx * s).clamp(v.width * (1 - s), 0.0);
    final ty = (f.dy - scene.dy * s).clamp(v.height * (1 - s), 0.0);
    _zoom.value = Matrix4.identity()
      ..translateByDouble(tx, ty, 0, 1)
      ..scaleByDouble(s, s, 1, 1);
  }

  /// A step of the zoom buttons and keys: ×1.5.
  void _step(int dir) => _zoomTo(dir > 0 ? _scale * 1.5 : _scale / 1.5);

  @override
  Widget build(BuildContext context) {
    final body = widget.body;
    final full = ref.watch(mediaBytesProvider(body.fullRef));
    final Widget content;
    var zoomable = false;
    if (_isExpired(ref, body)) {
      content = const _Expired(light: true);
    } else {
      switch (full) {
        case AsyncData(value: final Uint8List bytes):
          zoomable = true;
          content = LayoutBuilder(builder: (context, box) {
            _viewport = box.biggest;
            return GestureDetector(
              onDoubleTapDown: (d) => _doubleTapAt = d.localPosition,
              // Double-tap: in to 2.5× where tapped, or back to fit.
              onDoubleTap: () => _zoomTo(_scale > 1.01 ? 1 : 2.5, _doubleTapAt),
              child: ListenableBuilder(
                listenable: _zoom,
                builder: (context, child) => MouseRegion(
                  cursor: _scale > 1.01 ? SystemMouseCursors.grab : MouseCursor.defer,
                  child: child,
                ),
                child: InteractiveViewer(
                  key: const Key('photo-zoom'),
                  transformationController: _zoom,
                  minScale: PhotoViewer.minScale,
                  maxScale: PhotoViewer.maxScale,
                  child: Center(
                    child: Image.memory(
                      bytes,
                      key: const Key('photo-full'),
                      fit: BoxFit.contain,
                      errorBuilder: (_, _, _) =>
                          const Icon(Icons.broken_image_outlined, color: Colors.white70, size: 48),
                    ),
                  ),
                ),
              ),
            );
          });
        case AsyncData():
          content = const _Expired(light: true);
        case AsyncError():
          content = Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Text("Couldn't load photo", style: TextStyle(color: Colors.white70)),
              TextButton(
                onPressed: () => ref.invalidate(mediaBytesProvider(body.fullRef)),
                child: const Text('Retry'),
              ),
            ]),
          );
        default:
          final thumb = ref.watch(mediaBytesProvider(body.thumbRef)).value;
          content = Stack(fit: StackFit.expand, children: [
            if (thumb != null)
              Center(
                child: AspectRatio(
                  aspectRatio: body.width / body.height,
                  child: Image.memory(thumb, fit: BoxFit.contain, errorBuilder: (_, _, _) => const SizedBox()),
                ),
              ),
            const Center(child: CircularProgressIndicator(color: Colors.white)),
          ]);
      }
    }
    final bar = zoomable && (widget.zoomBar ?? _mouseFirst);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.of(context).maybePop(),
        if (zoomable) ...{
          const SingleActivator(LogicalKeyboardKey.equal): () => _step(1),
          const SingleActivator(LogicalKeyboardKey.equal, shift: true): () => _step(1),
          const SingleActivator(LogicalKeyboardKey.numpadAdd): () => _step(1),
          const SingleActivator(LogicalKeyboardKey.minus): () => _step(-1),
          const SingleActivator(LogicalKeyboardKey.numpadSubtract): () => _step(-1),
          const SingleActivator(LogicalKeyboardKey.digit0): () => _zoomTo(1),
        },
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: Colors.black,
          // Every child is positioned, so the stack fills the screen (the body's constraints are
          // loose: an unpositioned button would size it to the button).
          body: Stack(children: [
            Positioned.fill(child: content),
            Positioned(
              top: 0,
              left: 0,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: IconButton.filled(
                    tooltip: 'Close',
                    // Readable over a bright photo too.
                    style: IconButton.styleFrom(backgroundColor: Colors.black54, foregroundColor: Colors.white),
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                ),
              ),
            ),
            if (bar)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Center(
                      child: ListenableBuilder(
                        listenable: _zoom,
                        builder: (context, _) => _ZoomBar(
                          scale: _scale,
                          onScale: _zoomTo,
                          onStep: _step,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ]),
        ),
      ),
    );
  }
}

/// − [slider] + 150% [fit], on a dark pill. The slider is logarithmic, so each step of it zooms by
/// the same factor.
class _ZoomBar extends StatelessWidget {
  const _ZoomBar({required this.scale, required this.onScale, required this.onStep});

  final double scale;
  final ValueChanged<double> onScale;
  final ValueChanged<int> onStep;

  @override
  Widget build(BuildContext context) {
    const lo = PhotoViewer.minScale, hi = PhotoViewer.maxScale;
    final t = (math.log(scale.clamp(lo, hi)) - math.log(lo)) / (math.log(hi) - math.log(lo));
    const white = Colors.white;
    return Container(
      key: const Key('photo-zoom-bar'),
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.6), borderRadius: BorderRadius.circular(24)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        IconButton(
          tooltip: 'Zoom out',
          color: white,
          icon: const Icon(Icons.remove_rounded),
          onPressed: scale > lo + 0.001 ? () => onStep(-1) : null,
        ),
        // Narrow windows shrink the slider, not the buttons.
        Flexible(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 180),
            child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: white,
              inactiveTrackColor: Colors.white24,
              thumbColor: white,
              overlayColor: Colors.white12,
            ),
            child: Slider(
              key: const Key('photo-zoom-slider'),
              value: t,
              semanticFormatterCallback: (_) => '${(scale * 100).round()}%',
              onChanged: (v) => onScale(math.exp(math.log(lo) + v * (math.log(hi) - math.log(lo)))),
            ),
          ),
          ),
        ),
        IconButton(
          tooltip: 'Zoom in',
          color: white,
          icon: const Icon(Icons.add_rounded),
          onPressed: scale < hi - 0.001 ? () => onStep(1) : null,
        ),
        SizedBox(
          width: 48,
          child: Text(
            '${(scale * 100).round()}%',
            key: const Key('photo-zoom-percent'),
            textAlign: TextAlign.center,
            style: const TextStyle(color: white, fontFeatures: [FontFeature.tabularFigures()]),
          ),
        ),
        IconButton(
          tooltip: 'Fit to screen',
          color: white,
          icon: const Icon(Icons.fit_screen_rounded),
          onPressed: scale > lo + 0.001 ? () => onScale(lo) : null,
        ),
      ]),
    );
  }
}
