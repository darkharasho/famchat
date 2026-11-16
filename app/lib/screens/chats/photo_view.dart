// Photos in a conversation: the thumbnail inside a bubble, and the full-screen viewer.

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
  const PhotoThumb({super.key, required this.body, required this.messageId, required this.onOpen});

  final PhotoBody body;
  final String messageId;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final size = thumbSize(body.width, body.height);
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
          borderRadius: BorderRadius.circular(Radii.lg - 4),
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

/// The full image on black, pinch/scroll to zoom; the thumbnail shows while it downloads.
class PhotoViewer extends ConsumerWidget {
  const PhotoViewer({super.key, required this.body});

  final PhotoBody body;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final full = ref.watch(mediaBytesProvider(body.fullRef));
    final Widget content;
    if (_isExpired(ref, body)) {
      content = const _Expired(light: true);
    } else {
      switch (full) {
        case AsyncData(value: final Uint8List bytes):
          content = InteractiveViewer(
            maxScale: 8,
            child: Center(
              child: Image.memory(
                bytes,
                key: const Key('photo-full'),
                fit: BoxFit.contain,
                errorBuilder: (_, _, _) => const Icon(Icons.broken_image_outlined, color: Colors.white70, size: 48),
              ),
            ),
          );
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
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.of(context).maybePop()},
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: Colors.black,
          body: Stack(children: [
            Positioned.fill(child: content),
            SafeArea(
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
          ]),
        ),
      ),
    );
  }
}
