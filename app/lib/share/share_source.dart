// The phone share sheet (receive_sharing_intent) on Android and iOS; nothing elsewhere.
import 'package:cross_file/cross_file.dart';
import 'package:flutter/foundation.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

import '../media/photo_picker.dart';
import '../media/send_media.dart';
import '../session/app_links.dart' show inviteFromLink;
import 'share.dart';

ShareSource platformShareSource() =>
    !kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS)
        ? const _PhoneShareSource()
        : const NoShareSource();

class _PhoneShareSource implements ShareSource {
  const _PhoneShareSource();

  @override
  Future<IncomingShare?> initial() async {
    try {
      final s = await sharedToIncoming(await ReceiveSharingIntent.instance.getInitialMedia());
      return s.isEmpty ? null : s;
    } catch (_) {
      return null; // no share extension (iOS) or the plugin is missing
    }
  }

  @override
  Stream<IncomingShare> get updates => ReceiveSharingIntent.instance
      .getMediaStream()
      .asyncMap(sharedToIncoming)
      .where((s) => !s.isEmpty)
      .handleError((Object _) {});

  @override
  Future<void> done() async {
    try {
      await ReceiveSharingIntent.instance.reset();
    } catch (_) {
      // nothing to reset
    }
  }
}

/// The plugin's files as photos, videos, other files and text (links come in as text).
Future<IncomingShare> sharedToIncoming(List<SharedMediaFile> files) async {
  final media = <PickedMedia>[];
  final others = <XFile>[];
  final texts = <String>[];
  for (final f in files) {
    switch (f.type) {
      // Android calls a shared text file (.txt, .csv) "text" too, with its path.
      case SharedMediaType.text when await _isFile(f.path):
        others.add(XFile(f.path, mimeType: f.mimeType));
      case SharedMediaType.text || SharedMediaType.url:
        final t = f.path.trim();
        // A tapped invite link reaches the app as a "view" too: the invite listener handles it.
        final uri = Uri.tryParse(t);
        if (t.isNotEmpty && (uri == null || inviteFromLink(uri) == null)) texts.add(t);
      case SharedMediaType.image:
        media.add(PickedPhoto(await XFile(f.path).readAsBytes()));
      case SharedMediaType.video:
        media.add(PickedVideo(XFile(f.path, mimeType: f.mimeType)));
      case SharedMediaType.file:
        final sorted = await pickedFromFiles([XFile(f.path, mimeType: f.mimeType)]);
        media.addAll(sorted.media);
        others.addAll(sorted.others);
    }
    final message = f.message;
    if (message != null && message.trim().isNotEmpty && !texts.contains(message.trim())) texts.add(message.trim());
  }
  return IncomingShare(
    media: media.take(maxPhotosPerPick).toList(),
    files: others.take(maxPhotosPerPick).toList(),
    text: texts.isEmpty ? null : texts.join('\n'),
  );
}

/// Whether [path] is a file the plugin copied in (an absolute path that reads), not shared text.
Future<bool> _isFile(String path) async {
  if (!path.startsWith('/') || path.contains('\n')) return false;
  try {
    await XFile(path).length();
    return true;
  } catch (_) {
    return false;
  }
}
