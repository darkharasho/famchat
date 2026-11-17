// Sending picked, shared or dropped photos and videos: each its own message.
import 'package:cross_file/cross_file.dart';

import 'media_service.dart';
import 'photo.dart';
import 'photo_picker.dart';
import 'video.dart';

/// What couldn't be sent, by reason.
class SendReport {
  int badImages = 0, badVideos = 0, bigVideos = 0;

  /// What to tell the person, or null when everything went.
  String? get problem {
    final mb = (maxVideoBytes / (1024 * 1024)).round();
    if (bigVideos > 0) {
      return bigVideos == 1
          ? 'That video is too large to send ($mb MB max).'
          : '$bigVideos videos are too large to send ($mb MB max).';
    }
    if (badVideos > 0) return badVideos == 1 ? "That video can't be sent." : "$badVideos videos can't be sent.";
    if (badImages > 0) return badImages == 1 ? "That image can't be sent." : "$badImages images can't be sent.";
    return null;
  }
}

/// Sends each of [items] to [chatId] in order; [onStart]/[onEnd] bracket each one (progress UI).
Future<SendReport> sendMedia(
  MediaService media,
  VideoProcessor videos,
  String chatId,
  List<PickedMedia> items, {
  void Function()? onStart,
  void Function()? onEnd,
}) async {
  final report = SendReport();
  for (final item in items) {
    onStart?.call();
    try {
      switch (item) {
        case PickedPhoto(:final bytes):
          await media.sendPhoto(chatId, bytes);
        case PickedVideo(:final file):
          await media.sendVideo(chatId, await videos.process(file));
      }
    } on VideoTooLargeException {
      report.bigVideos++;
    } on UnsupportedVideoException {
      report.badVideos++;
    } on UnsupportedImageException {
      report.badImages++;
    } catch (_) {
      item is PickedVideo ? report.badVideos++ : report.badImages++;
    } finally {
      onEnd?.call();
    }
  }
  return report;
}

/// File names treated as photos when there's no MIME type.
const imageExtensions = {'jpg', 'jpeg', 'png', 'gif', 'webp', 'heic', 'heif', 'bmp', 'tif', 'tiff'};

bool isImageFile(XFile f) {
  final mime = f.mimeType;
  if (mime != null && mime.isNotEmpty) return mime.startsWith('image/');
  final name = f.name.isNotEmpty ? f.name : f.path;
  final dot = name.lastIndexOf('.');
  return dot >= 0 && imageExtensions.contains(name.substring(dot + 1).toLowerCase());
}

/// Dropped or shared files as photos and videos; anything else is counted in `skipped`.
Future<({List<PickedMedia> media, int skipped})> pickedFromFiles(List<XFile> files) async {
  final media = <PickedMedia>[];
  var skipped = 0;
  for (final f in files) {
    if (isVideoFile(f)) {
      media.add(PickedVideo(f));
    } else if (isImageFile(f)) {
      media.add(PickedPhoto(await f.readAsBytes()));
    } else {
      skipped++;
    }
  }
  return (media: media, skipped: skipped);
}
