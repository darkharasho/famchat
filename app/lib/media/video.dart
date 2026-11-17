// What sending a video needs: the file to send, a poster frame and its size and length (made by
// the platform in video_processor.dart; tests use a fake).
import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';

import '../crypto/media.dart';
import 'media_api.dart';

/// Largest video file that can be sent (its ciphertext must fit the server's `video` limit).
final int maxVideoBytes = mediaKindLimits['video']! - mediaOverhead;

/// Longest side of a poster frame, in pixels.
const maxPosterSide = 480;

class ProcessedVideo {
  const ProcessedVideo({required this.bytes, this.thumb, required this.width, required this.height, required this.duration});

  /// The MP4 to send.
  final Uint8List bytes;

  /// A JPEG frame to show before it plays, when the platform could make one.
  final Uint8List? thumb;

  /// Display size in pixels (as the video is shown, after rotation).
  final int width, height;
  final Duration duration;
}

/// The video is over [maxVideoBytes], even after compression.
class VideoTooLargeException implements Exception {
  const VideoTooLargeException(this.bytes);
  final int bytes;

  @override
  String toString() => 'VideoTooLargeException: $bytes bytes';
}

/// The platform can't read this file as a video.
class UnsupportedVideoException implements Exception {
  const UnsupportedVideoException([this.reason = 'unsupported video']);
  final String reason;

  @override
  String toString() => 'UnsupportedVideoException: $reason';
}

abstract interface class VideoProcessor {
  /// Compresses where the platform can, and reads the poster frame, size and length. Throws
  /// [VideoTooLargeException] or [UnsupportedVideoException].
  Future<ProcessedVideo> process(XFile file);
}

/// File names treated as videos when a picker gives no MIME type.
const videoExtensions = {'mp4', 'mov', 'm4v', 'webm', 'mkv', 'avi', '3gp', 'qt'};

/// Whether a picked file is a video (by MIME type, else by extension).
bool isVideoFile(XFile f) {
  final mime = f.mimeType;
  if (mime != null && mime.isNotEmpty) return mime.startsWith('video/');
  final name = f.name.isNotEmpty ? f.name : f.path;
  final dot = name.lastIndexOf('.');
  return dot >= 0 && videoExtensions.contains(name.substring(dot + 1).toLowerCase());
}

/// Whether [f] is a container and codec family every platform's player opens (MP4/QuickTime):
/// what Windows, Linux and the web may send without converting.
bool playsEverywhere(XFile f) {
  final mime = f.mimeType;
  if (mime != null && mime.isNotEmpty) return mime == 'video/mp4' || mime == 'video/quicktime' || mime == 'video/x-m4v';
  final name = f.name.isNotEmpty ? f.name : f.path;
  final dot = name.lastIndexOf('.');
  return dot >= 0 && const {'mp4', 'm4v', 'mov'}.contains(name.substring(dot + 1).toLowerCase());
}
