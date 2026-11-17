import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cross_file/cross_file.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_compress/video_compress.dart';
import 'package:video_player/video_player.dart';

import 'video.dart';

/// Phones and Macs compress to 720p with the system encoder (video_compress); Windows and Linux
/// send the file as it is and read it with libmpv (media_kit).
class PlatformVideoProcessor implements VideoProcessor {
  @override
  Future<ProcessedVideo> process(XFile file) =>
      Platform.isAndroid || Platform.isIOS || Platform.isMacOS ? _compressed(file) : _asIs(file);

  Future<ProcessedVideo> _compressed(XFile file) async {
    MediaInfo? info;
    try {
      info = await VideoCompress.compressVideo(file.path, quality: VideoQuality.Res1280x720Quality, includeAudio: true);
    } catch (_) {
      info = null; // sent as it is, if it fits
    }
    final path = info?.path ?? file.path;
    try {
      final f = File(path);
      final size = await f.length();
      if (size > maxVideoBytes) throw VideoTooLargeException(size);
      final meta = info ?? await VideoCompress.getMediaInfo(path);
      Uint8List? thumb;
      try {
        thumb = await VideoCompress.getByteThumbnail(path, quality: 70);
      } catch (_) {
        thumb = null;
      }
      final shown = thumb == null ? null : await _imageSize(thumb);
      final width = shown?.$1 ?? meta.width ?? 0;
      final height = shown?.$2 ?? meta.height ?? 0;
      final ms = (meta.duration ?? 0).round();
      if (width < 1 || height < 1 || ms < 1) throw const UnsupportedVideoException('no size or length');
      return ProcessedVideo(
        bytes: await f.readAsBytes(),
        thumb: shown == null ? null : thumb,
        width: width,
        height: height,
        duration: Duration(milliseconds: ms),
      );
    } finally {
      if (info?.path != null && info!.path != file.path) {
        try {
          await File(info.path!).delete();
        } on FileSystemException {
          // the plugin's cache folder; cleared below too
        }
      }
    }
  }

  Future<ProcessedVideo> _asIs(XFile file) async {
    final size = await file.length();
    if (size > maxVideoBytes) throw VideoTooLargeException(size);
    final player = Player(configuration: const PlayerConfiguration(muted: true));
    try {
      await player.open(Media(Uri.file(file.path).toString()), play: false);
      final width = await _first(player.stream.width, player.state.width);
      final height = await _first(player.stream.height, player.state.height);
      final duration = await _first(player.stream.duration, player.state.duration, (d) => d > Duration.zero);
      if (width == null || height == null || duration == null) throw const UnsupportedVideoException('unreadable');
      Uint8List? thumb;
      try {
        await player.seek(Duration(milliseconds: (duration.inMilliseconds ~/ 10).clamp(0, 1000)));
        thumb = await player.screenshot().timeout(const Duration(seconds: 5));
      } catch (_) {
        thumb = null;
      }
      return ProcessedVideo(bytes: await file.readAsBytes(), thumb: thumb, width: width, height: height, duration: duration);
    } finally {
      await player.dispose();
    }
  }

  /// The first value of [s] (or [now]) passing [ok] (default: positive), or null after a while.
  static Future<T?> _first<T>(Stream<T?> s, T? now, [bool Function(T)? ok]) async {
    bool good(T? v) => v != null && (ok?.call(v) ?? (v is num ? v > 0 : true));
    if (good(now)) return now;
    try {
      return await s.firstWhere(good).timeout(const Duration(seconds: 10));
    } catch (_) {
      return null;
    }
  }
}

/// [jpeg]'s size in pixels, or null when it won't decode.
Future<(int, int)?> _imageSize(Uint8List jpeg) async {
  try {
    final codec = await ui.instantiateImageCodec(jpeg);
    final frame = await codec.getNextFrame();
    final size = (frame.image.width, frame.image.height);
    frame.image.dispose();
    codec.dispose();
    return size;
  } catch (_) {
    return null;
  }
}

/// Decrypted videos are written to the app's own cache directory for the player, and removed when
/// it closes (and at the next start).
Future<Directory> _dir() async {
  final d = Directory('${(await getApplicationCacheDirectory()).path}/video');
  await d.create(recursive: true);
  return d;
}

String _safe(String id) => id.replaceAll(RegExp('[^A-Za-z0-9_-]'), '_');

/// A file the player can open holding [bytes] (the decrypted video of message [id]).
Future<Uri> playableVideo(String id, Uint8List bytes) async {
  final f = File('${(await _dir()).path}/play_${_safe(id)}.mp4');
  await f.writeAsBytes(bytes, flush: true);
  return Uri.file(f.path);
}

/// Deletes what [playableVideo] wrote.
Future<void> releaseVideo(Uri uri) async {
  if (uri.scheme != 'file') return;
  try {
    await File.fromUri(uri).delete();
  } on FileSystemException {
    // already gone, or swept at the next start
  }
}

/// Removes decrypted videos left by a previous run, and video_compress's leftovers.
Future<void> sweepVideoFiles() async {
  try {
    final d = await _dir();
    await for (final f in d.list()) {
      await f.delete(recursive: true);
    }
  } catch (_) {
    // nothing to sweep
  }
  if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) {
    try {
      await VideoCompress.deleteAllCache();
    } catch (_) {
      // no plugin (tests) or nothing cached
    }
  }
}

/// A player for what [playableVideo] returned.
VideoPlayerController videoControllerFor(Uri uri) => VideoPlayerController.file(File.fromUri(uri));
