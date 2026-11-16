// Turns a picked image into what's sent: a JPEG at most 2048 px on the long side and a 320 px
// thumbnail, EXIF orientation applied and all metadata (camera, location) dropped.
// JPEG/PNG/GIF/WebP/BMP/TIFF decode with the `image` package in a background isolate (inline on the
// web); anything else (HEIC) goes through the platform's decoders (dart:ui), where the OS supports it.
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import 'photo.dart';

/// Refuse images bigger than this many pixels before decoding (a decompression bomb would exhaust memory).
const maxSourcePixels = 60 * 1000 * 1000;

const _fullQuality = 85;
const _thumbQuality = 75;

class PlatformPhotoProcessor implements PhotoProcessor {
  @override
  Future<ProcessedPhoto> process(Uint8List original) async {
    if (kIsWeb) {
      // No isolates on the web: let the browser decode and scale (image_picker's canvas resize has
      // already applied orientation); only the JPEG encode runs in Dart.
      try {
        return await _processWithPlatformCodec(original);
      } on UnsupportedImageException {
        // Try the image package below.
      }
    }
    final viaImage = await compute(_processWithImagePackage, original);
    if (viaImage != null) return viaImage;
    if (kIsWeb) throw const UnsupportedImageException();
    return _processWithPlatformCodec(original);
  }
}

/// Null when the `image` package can't decode the bytes. Runs in an isolate off the web.
ProcessedPhoto? _processWithImagePackage(Uint8List bytes) {
  final decoder = img.findDecoderForData(bytes);
  if (decoder == null) return null;
  final info = decoder.startDecode(bytes);
  if (info == null) return null; // no size to check: the platform path checks it before decoding
  if (info.width * info.height > maxSourcePixels) {
    throw const UnsupportedImageException('image too large');
  }
  final img.Image? decoded;
  try {
    decoded = decoder.decode(bytes, frame: 0);
  } catch (_) {
    return null;
  }
  if (decoded == null) return null;
  return _encode(img.bakeOrientation(decoded));
}

ProcessedPhoto _encode(img.Image src) {
  final (w, h) = fitWithin(src.width, src.height, maxPhotoSide);
  final full = _resized(src, w, h);
  final (tw, th) = fitWithin(w, h, maxThumbSide);
  final thumb = _resized(full, tw, th);
  return ProcessedPhoto(
    full: img.encodeJpg(full, quality: _fullQuality),
    thumb: img.encodeJpg(thumb, quality: _thumbQuality),
    width: w,
    height: h,
  );
}

/// A metadata-free RGB copy at [w]×[h] (JPEG has no alpha; transparent pixels go white-ish via blend).
img.Image _resized(img.Image src, int w, int h) {
  var out = (w == src.width && h == src.height)
      ? img.Image.from(src)
      : img.copyResize(src, width: w, height: h, interpolation: img.Interpolation.average);
  if (out.numChannels == 4 || out.hasPalette || out.format != img.Format.uint8) {
    final rgb = img.Image(width: out.width, height: out.height);
    img.fill(rgb, color: img.ColorRgb8(255, 255, 255));
    img.compositeImage(rgb, out);
    out = rgb;
  }
  out.exif = img.ExifData();
  out.iccProfile = null;
  out.textData = null;
  return out;
}

/// Decodes with the platform's codecs at the target size (HEIC on Apple platforms and Android 9+,
/// whatever the browser decodes on the web), then encodes JPEGs with the `image` package.
Future<ProcessedPhoto> _processWithPlatformCodec(Uint8List bytes) async {
  final ui.ImmutableBuffer buffer;
  final ui.ImageDescriptor desc;
  try {
    buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    desc = await ui.ImageDescriptor.encoded(buffer);
  } catch (e) {
    throw UnsupportedImageException('$e');
  }
  try {
    if (desc.width * desc.height > maxSourcePixels) throw const UnsupportedImageException('image too large');
    final (w, h) = fitWithin(desc.width, desc.height, maxPhotoSide);
    final codec = await desc.instantiateCodec(targetWidth: w, targetHeight: h);
    final frame = await codec.getNextFrame();
    final data = await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final fw = frame.image.width, fh = frame.image.height;
    frame.image.dispose();
    codec.dispose();
    if (data == null) throw const UnsupportedImageException('no pixels');
    return await compute(_encodeRgba, (data.buffer.asUint8List(), fw, fh));
  } on UnsupportedImageException {
    rethrow;
  } catch (e) {
    throw UnsupportedImageException('$e');
  } finally {
    desc.dispose();
    buffer.dispose();
  }
}

ProcessedPhoto _encodeRgba((Uint8List, int, int) a) =>
    _encode(img.Image.fromBytes(width: a.$2, height: a.$3, bytes: a.$1.buffer, numChannels: 4, order: img.ChannelOrder.rgba));
