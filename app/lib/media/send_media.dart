// Sending picked, shared or dropped photos and videos: each its own message, the text typed with them
// as the last one's caption.
import 'package:cross_file/cross_file.dart';

import '../chat/plaintext.dart' show validMessageText;
import '../chat/ulid.dart';
import 'media_service.dart';
import 'photo.dart';
import 'photo_picker.dart';
import 'video.dart';

/// What couldn't be sent, by reason.
class SendReport {
  int badImages = 0, badVideos = 0, bigVideos = 0;

  /// The item meant to carry the caption couldn't be sent, so the caption went as a text.
  bool captionSentAsText = false;

  /// What to tell the person, or null when everything went.
  String? get problem {
    final mb = (maxVideoBytes / (1024 * 1024)).round();
    if (bigVideos > 0) {
      return bigVideos == 1
          ? 'That video is too large to send ($mb MB max).'
          : '$bigVideos videos are too large to send ($mb MB max).';
    }
    if (badVideos > 0) {
      return badVideos == 1
          ? "That video can't be sent. MP4 and MOV videos work."
          : "$badVideos videos can't be sent. MP4 and MOV videos work.";
    }
    if (badImages > 0) return badImages == 1 ? "That image can't be sent." : "$badImages images can't be sent.";
    return null;
  }
}

/// Sends each of [items] to [chatId] in order; [onStart]/[onEnd] bracket each one (progress UI).
///
/// [caption] (when not blank), [replyTo] and [mentions] go with the last item. When that one can't
/// be sent they go as a text instead, so what was typed is never lost. [at]: all of it is scheduled
/// for then instead.
Future<SendReport> sendMedia(
  MediaService media,
  VideoProcessor videos,
  String chatId,
  List<PickedMedia> items, {
  String? caption,
  String? replyTo,
  List<String> mentions = const [],
  void Function()? onStart,
  void Function()? onEnd,
  DateTime? at,
}) async {
  final report = SendReport();
  final text = caption == null ? null : validMessageText(caption);
  // Sent together: one album.
  final album = items.length > 1 ? newUlid() : null;
  for (final (i, item) in items.indexed) {
    final last = i == items.length - 1;
    final withCaption = last && text != null;
    // A reply with nothing typed still belongs on the last item.
    final reply = last ? replyTo : null;
    final mentioned = withCaption ? mentions : const <String>[];
    onStart?.call();
    var sent = false;
    try {
      switch (item) {
        case PickedPhoto(:final bytes):
          await media.sendPhoto(chatId, bytes,
              caption: withCaption ? text : null, replyTo: reply, mentions: mentioned, album: album, at: at);
        case PickedVideo(:final file):
          await media.sendVideo(chatId, await videos.process(file),
              caption: withCaption ? text : null, replyTo: reply, mentions: mentioned, album: album, at: at);
      }
      sent = true;
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
    if (withCaption && !sent) {
      await media.sync.sendText(chatId, text, replyTo: replyTo, mentions: mentions, at: at);
      report.captionSentAsText = true;
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

/// Dropped or shared files as photos and videos; anything else is in `others` (and counted in
/// `skipped`), to send as files.
Future<({List<PickedMedia> media, int skipped, List<XFile> others})> pickedFromFiles(List<XFile> files) async {
  final media = <PickedMedia>[];
  final others = <XFile>[];
  for (final f in files) {
    if (isVideoFile(f)) {
      media.add(PickedVideo(f));
    } else if (isImageFile(f)) {
      media.add(PickedPhoto(await f.readAsBytes()));
    } else {
      others.add(f);
    }
  }
  return (media: media, skipped: others.length, others: others);
}
