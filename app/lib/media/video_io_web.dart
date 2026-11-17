import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';
import 'package:video_player/video_player.dart';
import 'package:web/web.dart' as web;

import 'video.dart';

/// The browser reads the video itself: size and length from a <video> element, and a poster frame
/// drawn on a canvas. The file is sent as it is.
class PlatformVideoProcessor implements VideoProcessor {
  @override
  Future<ProcessedVideo> process(XFile file) async {
    if (!playsEverywhere(file)) throw const UnsupportedVideoException('only MP4 and MOV');
    final size = await file.length();
    if (size > maxVideoBytes) throw VideoTooLargeException(size);
    final bytes = await file.readAsBytes();
    final url = web.URL.createObjectURL(web.Blob([bytes.toJS].toJS, web.BlobPropertyBag(type: file.mimeType ?? 'video/mp4')));
    final video = web.HTMLVideoElement()
      ..muted = true
      ..preload = 'auto'
      ..src = url;
    try {
      await video.onLoadedMetadata.first.timeout(const Duration(seconds: 15));
      final width = video.videoWidth, height = video.videoHeight;
      final seconds = video.duration;
      if (width < 1 || height < 1 || !seconds.isFinite || seconds <= 0) throw const UnsupportedVideoException('unreadable');
      Uint8List? thumb;
      try {
        video.currentTime = seconds < 2 ? seconds / 4 : 0.5;
        await video.onSeeked.first.timeout(const Duration(seconds: 5));
        final scale = width > height ? maxPosterSide / width : maxPosterSide / height;
        final w = (width * (scale < 1 ? scale : 1)).round(), h = (height * (scale < 1 ? scale : 1)).round();
        final canvas = web.HTMLCanvasElement()
          ..width = w
          ..height = h;
        (canvas.getContext('2d')! as web.CanvasRenderingContext2D).drawImage(video, 0, 0, w.toDouble(), h.toDouble());
        final done = Completer<web.Blob?>();
        canvas.toBlob(((web.Blob? b) => done.complete(b)).toJS, 'image/jpeg', 0.75.toJS);
        final blob = await done.future.timeout(const Duration(seconds: 5));
        if (blob != null) thumb = (await blob.arrayBuffer().toDart).toDart.asUint8List();
      } catch (_) {
        thumb = null;
      }
      return ProcessedVideo(
        bytes: bytes,
        thumb: thumb,
        width: width,
        height: height,
        duration: Duration(milliseconds: (seconds * 1000).round()),
      );
    } finally {
      video.src = '';
      web.URL.revokeObjectURL(url);
    }
  }
}

/// A blob: URL the player can open holding [bytes].
Future<Uri> playableVideo(String id, Uint8List bytes) async =>
    Uri.parse(web.URL.createObjectURL(web.Blob([bytes.toJS].toJS, web.BlobPropertyBag(type: 'video/mp4'))));

Future<void> releaseVideo(Uri uri) async {
  if (uri.scheme == 'blob') web.URL.revokeObjectURL(uri.toString());
}

/// Nothing is written to disk on the web.
Future<void> sweepVideoFiles() async {}

/// A player for what [playableVideo] returned.
VideoPlayerController videoControllerFor(Uri uri) => VideoPlayerController.networkUrl(uri);
