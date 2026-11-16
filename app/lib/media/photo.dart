// What sending a photo needs from image processing (implemented with platform codecs in
// photo_processor.dart; tests use a fake).
import 'dart:typed_data';

/// Longest side of a sent photo, and of its thumbnail, in pixels.
const maxPhotoSide = 2048;
const maxThumbSide = 320;

class ProcessedPhoto {
  const ProcessedPhoto({required this.full, required this.thumb, required this.width, required this.height});

  /// JPEG bytes (no EXIF), at most [maxPhotoSide] / [maxThumbSide] on the long side.
  final Uint8List full, thumb;

  /// Size of [full] in pixels.
  final int width, height;
}

class UnsupportedImageException implements Exception {
  const UnsupportedImageException([this.reason = 'unsupported image']);
  final String reason;

  @override
  String toString() => 'UnsupportedImageException: $reason';
}

abstract interface class PhotoProcessor {
  /// Throws [UnsupportedImageException] for bytes this platform can't decode.
  Future<ProcessedPhoto> process(Uint8List original);
}

/// The size [w]×[h] scaled down (never up) so the long side is at most [maxSide].
(int, int) fitWithin(int w, int h, int maxSide) {
  if (w <= maxSide && h <= maxSide) return (w, h);
  if (w >= h) return (maxSide, (h * maxSide / w).round().clamp(1, maxSide));
  return ((w * maxSide / h).round().clamp(1, maxSide), maxSide);
}
