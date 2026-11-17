// Videos in a conversation: the poster inside a bubble, and the full-screen player.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:video_player/video_player.dart';

import '../../chat/plaintext.dart';
import '../../media/media_service.dart';
import '../../media/providers.dart';
import '../../theme/tokens.dart';
import 'photo_view.dart' show thumbSize;

/// "0:07", "12:30", "1:02:03".
String videoLength(Duration d) {
  final s = d.inSeconds;
  String two(int v) => v.toString().padLeft(2, '0');
  if (s >= 3600) return '${s ~/ 3600}:${two(s % 3600 ~/ 60)}:${two(s % 60)}';
  return '${s ~/ 60}:${two(s % 60)}';
}

bool _isExpired(WidgetRef ref, VideoBody body) {
  final expired = ref.watch(expiredMediaProvider).value ?? const <String>{};
  return expired.contains(body.mediaKey);
}

/// A video's poster frame (or a plain tile), its length and a play button; upload progress while
/// sending. Tapping opens the player.
class VideoThumb extends ConsumerWidget {
  const VideoThumb({super.key, required this.body, required this.messageId, required this.onOpen});

  final VideoBody body;
  final String messageId;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final size = thumbSize(body.width, body.height);
    final progress = ref.watch(uploadProgressProvider(messageId)).value;
    final expired = _isExpired(ref, body);
    final thumbRef = body.thumbRef;
    final poster = thumbRef == null ? null : ref.watch(mediaBytesProvider(thumbRef)).value;
    final length = videoLength(Duration(milliseconds: body.durationMs));
    return Semantics(
      label: expired ? 'Video expired' : 'Video, $length',
      button: !expired,
      child: GestureDetector(
        onTap: expired ? null : onOpen,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(Radii.lg - 4),
          child: Container(
            key: Key('video-$messageId'),
            width: size.width,
            height: size.height,
            color: Colors.black,
            child: Stack(fit: StackFit.expand, children: [
              if (poster != null && !expired)
                Image.memory(
                  poster,
                  key: const Key('video-poster'),
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  cacheWidth: (size.width * 2).round(),
                  errorBuilder: (_, _, _) => const SizedBox(),
                ),
              if (expired)
                const Center(
                  key: Key('media-expired'),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.videocam_off_outlined, color: Colors.white70),
                    SizedBox(height: 4),
                    Text('Video expired', style: TextStyle(color: Colors.white70)),
                  ]),
                )
              else if (progress != null && progress < 1)
                ColoredBox(
                  color: Colors.black38,
                  child: Center(
                    child: CircularProgressIndicator(
                      key: const Key('upload-progress'),
                      value: progress == 0 ? null : progress,
                      color: Colors.white,
                    ),
                  ),
                )
              else
                const Center(
                  child: DecoratedBox(
                    decoration: BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                    child: Padding(
                      padding: EdgeInsets.all(10),
                      child: Icon(Icons.play_arrow_rounded, color: Colors.white, size: 36),
                    ),
                  ),
                ),
              if (!expired)
                Positioned(
                  left: 8,
                  bottom: 8,
                  child: DecoratedBox(
                    decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(99)),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        const Icon(Icons.videocam_rounded, color: Colors.white, size: 14),
                        const SizedBox(width: 4),
                        Text(length, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
                      ]),
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

/// Opens message [messageId]'s video [body] full screen.
Future<void> showVideoViewer(BuildContext context, VideoBody body, String messageId) => Navigator.of(context).push(
      PageRouteBuilder<void>(
        opaque: true,
        pageBuilder: (_, _, _) => VideoViewer(body: body, messageId: messageId),
        transitionsBuilder: (_, a, _, child) => FadeTransition(opacity: a, child: child),
      ),
    );

/// Downloads and decrypts the video (the poster shows meanwhile), then plays it with controls.
class VideoViewer extends ConsumerStatefulWidget {
  const VideoViewer({super.key, required this.body, required this.messageId});

  final VideoBody body;
  final String messageId;

  @override
  ConsumerState<VideoViewer> createState() => _VideoViewerState();
}

enum _Load { loading, ready, expired, failed }

class _VideoViewerState extends ConsumerState<VideoViewer> {
  _Load _state = _Load.loading;
  VideoPlayerController? _controller;
  Uri? _uri;
  late final VideoFiles _files = ref.read(videoFilesProvider);
  bool _showControls = true;
  Timer? _hide;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() => _state = _Load.loading);
    try {
      final media = ref.read(mediaServiceProvider);
      if (media == null) throw StateError('signed out');
      final bytes = await media.load(widget.body.ref);
      if (!mounted) return;
      if (bytes == null) return setState(() => _state = _Load.expired);
      final uri = _uri ??= await _files.playable(widget.messageId, bytes);
      final c = _files.controllerFor(uri);
      await c.initialize();
      if (!mounted) {
        await c.dispose();
        return;
      }
      _controller = c..addListener(_changed);
      setState(() => _state = _Load.ready);
      await c.play();
      _hideSoon();
    } catch (_) {
      if (mounted) setState(() => _state = _Load.failed);
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _hideSoon() {
    _hide?.cancel();
    _hide = Timer(const Duration(seconds: 3), () {
      if (mounted && (_controller?.value.isPlaying ?? false)) setState(() => _showControls = false);
    });
  }

  void _toggle() {
    final c = _controller;
    if (c == null) return;
    if (c.value.isPlaying) {
      unawaited(c.pause());
    } else {
      if (c.value.position >= c.value.duration) unawaited(c.seekTo(Duration.zero));
      unawaited(c.play());
    }
    setState(() => _showControls = true);
    _hideSoon();
  }

  @override
  void dispose() {
    _hide?.cancel();
    final c = _controller, uri = _uri, files = _files;
    c?.removeListener(_changed);
    unawaited(() async {
      await c?.dispose();
      if (uri != null) await files.release(uri);
    }());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final thumbRef = widget.body.thumbRef;
    final poster = thumbRef == null ? null : ref.watch(mediaBytesProvider(thumbRef)).value;
    final c = _controller;
    final Widget content = switch (_state) {
      _Load.ready when c != null => GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            setState(() => _showControls = !_showControls);
            if (_showControls) _hideSoon();
          },
          child: Stack(fit: StackFit.expand, children: [
            Center(
              child: AspectRatio(
                aspectRatio: c.value.aspectRatio > 0 ? c.value.aspectRatio : widget.body.width / widget.body.height,
                child: VideoPlayer(c, key: const Key('video-player')),
              ),
            ),
            AnimatedOpacity(
              opacity: _showControls ? 1 : 0,
              duration: const Duration(milliseconds: 200),
              child: IgnorePointer(ignoring: !_showControls, child: _controls(c)),
            ),
          ]),
        ),
      _Load.expired => const Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.videocam_off_outlined, color: Colors.white70, size: 40),
            SizedBox(height: 8),
            Text('Video expired', style: TextStyle(color: Colors.white70)),
          ]),
        ),
      _Load.failed => Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text("Couldn't play this video", style: TextStyle(color: Colors.white70)),
            TextButton(onPressed: _load, child: const Text('Retry')),
          ]),
        ),
      _ => Stack(fit: StackFit.expand, children: [
          if (poster != null)
            Center(
              child: AspectRatio(
                aspectRatio: widget.body.width / widget.body.height,
                child: Image.memory(poster, fit: BoxFit.contain, errorBuilder: (_, _, _) => const SizedBox()),
              ),
            ),
          const Center(child: CircularProgressIndicator(key: Key('video-loading'), color: Colors.white)),
        ]),
    };
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.of(context).maybePop(),
        const SingleActivator(LogicalKeyboardKey.space): _toggle,
      },
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

  Widget _controls(VideoPlayerController c) {
    final v = c.value;
    return Stack(children: [
      Center(
        child: IconButton.filled(
          tooltip: v.isPlaying ? 'Pause' : 'Play',
          iconSize: 40,
          style: IconButton.styleFrom(backgroundColor: Colors.black54, foregroundColor: Colors.white),
          icon: Icon(v.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded),
          onPressed: _toggle,
        ),
      ),
      Positioned(
        left: 0,
        right: 0,
        bottom: 0,
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, Space.md),
            child: LayoutBuilder(builder: (context, box) {
              // Times only where they fit beside a usable scrubber.
              final times = box.maxWidth >= 200;
              return Row(children: [
                if (times) ...[
                  Text(videoLength(v.position), style: const TextStyle(color: Colors.white, fontSize: 12)),
                  const SizedBox(width: Space.sm),
                ],
                Expanded(
                  child: VideoProgressIndicator(
                    c,
                    allowScrubbing: true,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    colors: const VideoProgressColors(
                        playedColor: Colors.white, bufferedColor: Colors.white38, backgroundColor: Colors.white24),
                  ),
                ),
                if (times) ...[
                  const SizedBox(width: Space.sm),
                  Text(videoLength(v.duration), style: const TextStyle(color: Colors.white, fontSize: 12)),
                ],
              ]);
            }),
          ),
        ),
      ),
    ]);
  }
}
